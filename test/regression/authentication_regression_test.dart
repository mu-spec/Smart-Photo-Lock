import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/data/repositories/impl/security_settings_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/security_settings_repository.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/credentials/biometric_options.dart';
import 'package:smart_app_lock/security/credentials/credential_hash.dart';
import 'package:smart_app_lock/security/credentials/credential_state.dart';
import 'package:smart_app_lock/security/credentials/credential_state_machine.dart';
import 'package:smart_app_lock/security/credentials/impl/default_credential_manager.dart';
import 'package:smart_app_lock/security/encryption/settings_cipher_impl.dart';
import 'package:smart_app_lock/security/credentials/pattern_hasher.dart';
import 'package:smart_app_lock/security/pin_hasher.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/services/biometric_service.dart';
import 'package:smart_app_lock/utilities/result.dart';

/// Phase 2L — Authentication regression.
///
/// Verifies the complete Phase 2 credential system end-to-end:
///   1. correct PIN           2. incorrect PIN        3. cooldown
///   4. correct pattern       5. incorrect pattern
///   6. biometric success     7. biometric failure    8. biometric cancel
///   9. process recreation (app restart survival)
///
/// The harness shares one encrypted settings repository across manager
/// instances, so "restarting the app" is simulated by simply constructing a
/// fresh manager over the same persisted store.
void main() {
  late Harness harness;

  setUp(() {
    harness = Harness();
  });

  // -------------------------------------------------------------------
  // 1. Correct PIN
  // -------------------------------------------------------------------
  group('correct PIN', () {
    test('authenticates and returns AuthSuccess with the PIN type',
        () async {
      await harness.manager.enrollPin('1234');
      final AuthAttemptResult result =
          (await harness.manager.authenticatePin('1234')).valueOrNull!;
      expect(result, isA<AuthSuccess>());
      expect((result as AuthSuccess).type, AuthType.pin);
    });

    test('6-digit PINs work too', () async {
      await harness.manager.enrollPin('246810');
      final AuthAttemptResult result =
          (await harness.manager.authenticatePin('246810')).valueOrNull!;
      expect(result, isA<AuthSuccess>());
    });

    test('success resets the failure counter', () async {
      await harness.manager.enrollPin('1234');
      await harness.manager.authenticatePin('0000');
      await harness.manager.authenticatePin('0000');
      expect(
        (await harness.manager.status()).valueOrNull!.failedAttempts,
        2,
      );
      await harness.manager.authenticatePin('1234');
      expect(
        (await harness.manager.status()).valueOrNull!.failedAttempts,
        0,
      );
    });
  });

  // -------------------------------------------------------------------
  // 2. Incorrect PIN
  // -------------------------------------------------------------------
  group('incorrect PIN', () {
    test('returns AuthFailure with decreasing remaining attempts', () async {
      await harness.manager.enrollPin('1234');

      final AuthAttemptResult r1 =
          (await harness.manager.authenticatePin('0000')).valueOrNull!;
      expect(r1, isA<AuthFailure>());
      expect((r1 as AuthFailure).reason, AuthFailureReason.wrongCredential);
      expect(r1.remainingAttempts, 2);

      final AuthAttemptResult r2 =
          (await harness.manager.authenticatePin('9999')).valueOrNull!;
      expect((r2 as AuthFailure).remainingAttempts, 1);

      expect(
        (await harness.manager.status()).valueOrNull!.failedAttempts,
        2,
      );
    });

    test('wrong-length PINs are rejected too', () async {
      await harness.manager.enrollPin('1234');
      expect(
        (await harness.manager.authenticatePin('12345')).valueOrNull,
        isA<AuthFailure>(),
      );
    });

    test('no enrolled PIN reports noCredentialEnrolled', () async {
      final AuthAttemptResult result =
          (await harness.manager.authenticatePin('1234')).valueOrNull!;
      expect(result, isA<AuthFailure>());
      expect(
        (result as AuthFailure).reason,
        AuthFailureReason.noCredentialEnrolled,
      );
    });
  });

  // -------------------------------------------------------------------
  // 3. Cooldown
  // -------------------------------------------------------------------
  group('cooldown', () {
    test('threshold triggers AuthLockedOut with a retry time', () async {
      await harness.manager.enrollPin('1234');
      await harness.manager.authenticatePin('0000');
      await harness.manager.authenticatePin('0000');
      final AuthAttemptResult r3 =
          (await harness.manager.authenticatePin('0000')).valueOrNull!;

      expect(r3, isA<AuthLockedOut>());
      final AuthLockedOut lockout = r3 as AuthLockedOut;
      expect(lockout.attemptsMade, 3);
      expect(lockout.lockoutStreak, 1);
      expect(lockout.retryAt.isAfter(DateTime.now()), isTrue);
      // ~30s base cooldown (threshold 3, base 30s in this harness).
      final int seconds = lockout.retryAt.difference(DateTime.now()).inSeconds;
      expect(seconds, inInclusiveRange(25, 30));
    });

    test('the correct PIN stays blocked during the cooldown', () async {
      await harness.manager.enrollPin('1234');
      await harness.manager.authenticatePin('0000');
      await harness.manager.authenticatePin('0000');
      await harness.manager.authenticatePin('0000');

      final AuthAttemptResult blocked =
          (await harness.manager.authenticatePin('1234')).valueOrNull!;
      expect(blocked, isA<AuthLockedOut>());
    });

    test('repeated lockouts escalate the cooldown (30s -> 60s)', () async {
      await harness.manager.enrollPin('1234');

      // First lockout cycle.
      await harness.manager.authenticatePin('0000');
      await harness.manager.authenticatePin('0000');
      final AuthLockedOut first = (await harness.manager.authenticatePin('0000'))
          .valueOrNull! as AuthLockedOut;
      expect(first.lockoutStreak, 1);
      final int c1 = first.retryAt.difference(DateTime.now()).inSeconds;
      expect(c1, inInclusiveRange(25, 30));

      // Expire the lockout manually (no clock seam on the manager).
      await harness.expireLockout();

      // Second lockout cycle: doubled cooldown.
      await harness.manager.authenticatePin('0000');
      await harness.manager.authenticatePin('0000');
      final AuthLockedOut second =
          (await harness.manager.authenticatePin('0000')).valueOrNull!
              as AuthLockedOut;
      expect(second.lockoutStreak, 2);
      final int c2 = second.retryAt.difference(DateTime.now()).inSeconds;
      expect(c2, inInclusiveRange(50, 60));
    });

    test('a success after the cooldown resets attempts and streak', () async {
      await harness.manager.enrollPin('1234');
      await harness.manager.authenticatePin('0000');
      await harness.manager.authenticatePin('0000');
      await harness.manager.authenticatePin('0000');
      expect((await harness.manager.status()).valueOrNull!.lockoutStreak, 1);

      await harness.expireLockout();
      await harness.manager.authenticatePin('1234');

      final CredentialState state =
          (await harness.manager.status()).valueOrNull!;
      expect(state.failedAttempts, 0);
      expect(state.lockoutStreak, 0);
      expect(state.lockedOutUntil, isNull);
    });
  });

  // -------------------------------------------------------------------
  // 4. Correct pattern
  // -------------------------------------------------------------------
  group('correct pattern', () {
    test('authenticates and returns AuthSuccess with the pattern type',
        () async {
      await harness.manager.enrollPattern(const <int>[1, 2, 3, 6]);
      final AuthAttemptResult result = (await harness.manager
              .authenticatePattern(const <int>[1, 2, 3, 6]))
          .valueOrNull!;
      expect(result, isA<AuthSuccess>());
      expect((result as AuthSuccess).type, AuthType.pattern);
    });

    test('REVERSE direction fails (direction-sensitive)', () async {
      await harness.manager.enrollPattern(const <int>[1, 2, 3, 6]);
      final AuthAttemptResult result = (await harness.manager
              .authenticatePattern(const <int>[6, 3, 2, 1]))
          .valueOrNull!;
      expect(result, isA<AuthFailure>());
      expect(
        (result as AuthFailure).reason,
        AuthFailureReason.wrongCredential,
      );
    });

    test('DIFFERENT ordering fails (order-sensitive)', () async {
      await harness.manager.enrollPattern(const <int>[1, 2, 3, 6]);
      final AuthAttemptResult result = (await harness.manager
              .authenticatePattern(const <int>[1, 3, 2, 6]))
          .valueOrNull!;
      expect(result, isA<AuthFailure>());
    });

    test('a legacy (unversioned) pattern record requires re-enrollment',
        () async {
      await harness.manager.enrollPattern(const <int>[1, 2, 3, 6]);
      // Strip the scheme version from the persisted record — simulating a
      // pre-fix direction-insensitive credential.
      final settings = (await harness.settings.getSettings()).valueOrNull!;
      final CredentialHash legacy = CredentialHash(
        salt: settings.patternHash!.salt,
        digest: settings.patternHash!.digest,
        iterations: settings.patternHash!.iterations,
        keyLength: settings.patternHash!.keyLength,
      );
      await harness.settings
          .saveSettings(settings.copyWith(patternHash: legacy));

      final restarted = harness.newManager();

      // Not enrolled anymore: flows will require setting the pattern again.
      expect(
        (await restarted.status()).valueOrNull!.hasEnrolled(AuthType.pattern),
        isFalse,
      );
      // Verification fails closed for both orientations — never ambiguous.
      final r1 = (await restarted.authenticatePattern(const <int>[1, 2, 3, 6]))
          .valueOrNull!;
      expect(r1, isA<AuthFailure>());
      expect(
        (r1 as AuthFailure).reason,
        AuthFailureReason.noCredentialEnrolled,
      );
      final r2 = (await restarted.authenticatePattern(const <int>[6, 3, 2, 1]))
          .valueOrNull!;
      expect(
        (r2 as AuthFailure).reason,
        AuthFailureReason.noCredentialEnrolled,
      );
    });
  });

  // -------------------------------------------------------------------
  // 5. Incorrect pattern
  // -------------------------------------------------------------------
  group('incorrect pattern', () {
    test('returns AuthFailure and counts toward the lockout', () async {
      await harness.manager.enrollPattern(const <int>[1, 2, 3, 6]);
      final AuthAttemptResult result = (await harness.manager
              .authenticatePattern(const <int>[1, 2, 3, 5]))
          .valueOrNull!;
      expect(result, isA<AuthFailure>());
      expect((result as AuthFailure).reason, AuthFailureReason.wrongCredential);
      expect(
        (await harness.manager.status()).valueOrNull!.failedAttempts,
        1,
      );
    });

    test('no enrolled pattern reports noCredentialEnrolled', () async {
      final AuthAttemptResult result = (await harness.manager
              .authenticatePattern(const <int>[1, 2, 3, 6]))
          .valueOrNull!;
      expect(result, isA<AuthFailure>());
      expect(
        (result as AuthFailure).reason,
        AuthFailureReason.noCredentialEnrolled,
      );
    });

    test('pattern failures share the PIN lockout (same counters)', () async {
      await harness.manager.enrollPin('1234');
      await harness.manager.enrollPattern(const <int>[1, 2, 3, 6]);
      await harness.manager.authenticatePattern(const <int>[1, 2, 3, 5]);
      await harness.manager.authenticatePattern(const <int>[1, 2, 3, 5]);
      final AuthAttemptResult r3 = (await harness.manager
              .authenticatePattern(const <int>[1, 2, 3, 5]))
          .valueOrNull!;
      expect(r3, isA<AuthLockedOut>());
      // The PIN is blocked too — one shared lockout state.
      expect(
        (await harness.manager.authenticatePin('1234')).valueOrNull,
        isA<AuthLockedOut>(),
      );
    });
  });

  // -------------------------------------------------------------------
  // 6-8. Biometric success / failure / cancellation
  // -------------------------------------------------------------------
  group('biometric', () {
    Future<DefaultCredentialManager> bioManager({
      required bool supported,
      required bool promptResult,
    }) async {
      final DefaultCredentialManager m = harness.newManager(
        biometricService: _FakeBiometricService(
          supported: supported,
          promptResult: promptResult,
        ),
      );
      await m.enrollPin('1234');
      await m.updateBiometricOptions(BiometricOptions.defaults);
      return m;
    }

    test('success returns AuthSuccess and resets counters', () async {
      final DefaultCredentialManager m =
          await bioManager(supported: true, promptResult: true);
      await m.authenticatePin('0000');
      await m.authenticatePin('0000');

      final AuthAttemptResult result =
          (await m.authenticateBiometric()).valueOrNull!;
      expect(result, isA<AuthSuccess>());
      expect((result as AuthSuccess).type, AuthType.biometric);
      expect((await m.status()).valueOrNull!.failedAttempts, 0);
    });

    test('failure returns AuthFailure and counts as an attempt', () async {
      final DefaultCredentialManager m =
          await bioManager(supported: true, promptResult: false);

      final AuthAttemptResult result =
          (await m.authenticateBiometric()).valueOrNull!;
      expect(result, isA<AuthFailure>());
      expect((result as AuthFailure).remainingAttempts, 2);
      expect((await m.status()).valueOrNull!.failedAttempts, 1);
    });

    test('three failures trigger the shared lockout', () async {
      final DefaultCredentialManager m =
          await bioManager(supported: true, promptResult: false);

      await m.authenticateBiometric();
      await m.authenticateBiometric();
      final AuthAttemptResult r3 =
          (await m.authenticateBiometric()).valueOrNull!;
      expect(r3, isA<AuthLockedOut>());
    });

    test(
        'cancellation fails closed and counts (prevents cancel-loop bypass)',
        () async {
      // local_auth semantics: a user cancel makes the prompt return
      // false — indistinguishable from a rejection. The manager treats it
      // as a failed attempt so rapid cancelling cannot skip lockouts.
      final DefaultCredentialManager m =
          await bioManager(supported: true, promptResult: false);

      final AuthAttemptResult c1 =
          (await m.authenticateBiometric()).valueOrNull!;
      expect(c1, isA<AuthFailure>());
      expect((c1 as AuthFailure).remainingAttempts, 2);

      // Cancel repeatedly -> lockout.
      await m.authenticateBiometric();
      final AuthAttemptResult c3 =
          (await m.authenticateBiometric()).valueOrNull!;
      expect(c3, isA<AuthLockedOut>());
    });

    test('unsupported hardware reports notAvailable without counting',
        () async {
      final DefaultCredentialManager m =
          await bioManager(supported: false, promptResult: true);

      final AuthAttemptResult result =
          (await m.authenticateBiometric()).valueOrNull!;
      expect(result, isA<AuthFailure>());
      expect((result as AuthFailure).reason, AuthFailureReason.notAvailable);
      // Capability checks are not authentication attempts.
      expect((await m.status()).valueOrNull!.failedAttempts, 0);
    });

    test('requires opt-in: notConfigured before enabling', () async {
      final DefaultCredentialManager m = harness.newManager(
        biometricService: const _FakeBiometricService(
          supported: true,
          promptResult: true,
        ),
      );
      await m.enrollPin('1234');
      // No updateBiometricOptions call.
      final AuthAttemptResult result =
          (await m.authenticateBiometric()).valueOrNull!;
      expect(result, isA<AuthFailure>());
      expect((result as AuthFailure).reason, AuthFailureReason.notConfigured);
    });
  });

  // -------------------------------------------------------------------
  // 9. Process recreation
  // -------------------------------------------------------------------
  group('process recreation', () {
    test('credentials survive a restart and still verify', () async {
      final DefaultCredentialManager firstRun = harness.newManager();
      await firstRun.enrollPin('1234');
      await firstRun.enrollPattern(const <int>[1, 2, 3, 6]);

      // "Restart": fresh manager over the same persisted store.
      final DefaultCredentialManager restarted = harness.newManager();

      final CredentialState state = (await restarted.status()).valueOrNull!;
      expect(state.hasEnrolled(AuthType.pin), isTrue);
      expect(state.hasEnrolled(AuthType.pattern), isTrue);
      expect(state.primary, AuthType.pattern);
      expect(state.pinLength, 4);

      expect(
        (await restarted.authenticatePin('1234')).valueOrNull,
        isA<AuthSuccess>(),
      );
      // The exact ordered sequence survives the restart.
      expect(
        (await restarted.authenticatePattern(const <int>[1, 2, 3, 6]))
            .valueOrNull,
        isA<AuthSuccess>(),
      );
    });

    test('attempt counters and lockouts survive a restart', () async {
      final DefaultCredentialManager firstRun = harness.newManager();
      await firstRun.enrollPin('1234');
      await firstRun.authenticatePin('0000');
      await firstRun.authenticatePin('0000');
      await firstRun.authenticatePin('0000'); // lockout, streak 1

      final DefaultCredentialManager restarted = harness.newManager();
      final CredentialState state = (await restarted.status()).valueOrNull!;
      expect(state.status, CredentialStatus.lockedOut);
      expect(state.lockoutStreak, 1);
      expect(state.lockedOutUntil, isNotNull);

      // Correct PIN still blocked on the restarted instance.
      expect(
        (await restarted.authenticatePin('1234')).valueOrNull,
        isA<AuthLockedOut>(),
      );

      // And the escalation survives too: expire, fail again -> streak 2.
      await harness.expireLockout();
      await restarted.authenticatePin('0000');
      await restarted.authenticatePin('0000');
      final AuthLockedOut escalated =
          (await restarted.authenticatePin('0000')).valueOrNull!
              as AuthLockedOut;
      expect(escalated.lockoutStreak, 2);
    });

    test('all authentication settings survive a restart', () async {
      final DefaultCredentialManager firstRun = harness.newManager();
      await firstRun.enrollPin('1234');
      await firstRun.setRandomizedKeypadEnabled(true);
      await firstRun.setPatternVisibilityEnabled(false);
      await firstRun.updateBiometricOptions(
        const BiometricOptions(requireConfirmation: false),
      );

      final DefaultCredentialManager restarted = harness.newManager();
      final CredentialState state = (await restarted.status()).valueOrNull!;
      expect(state.randomizedKeypadEnabled, isTrue);
      expect(state.patternVisibilityEnabled, isFalse);
      expect(state.hasEnrolled(AuthType.biometric), isTrue);

      final settings = (await harness.settings.getSettings()).valueOrNull!;
      expect(settings.randomizedKeypadEnabled, isTrue);
      expect(settings.patternVisibilityEnabled, isFalse);
      expect(settings.biometricOptions?.requireConfirmation, isFalse);
    });

    test('the raw PIN never appears in the persisted store (across restart)',
        () async {
      final DefaultCredentialManager firstRun = harness.newManager();
      await firstRun.enrollPin('1234');
      await harness.expireLockout();

      final DefaultCredentialManager restarted = harness.newManager();
      expect(
        (await restarted.authenticatePin('1234')).valueOrNull,
        isA<AuthSuccess>(),
      );

      // The persisted document is encrypted and contains no raw PIN bytes.
      final String? raw = await harness.database.getSetting('security_settings');
      expect(raw, startsWith('enc:v1:'));
      expect(raw, isNot(contains('1234')));
    });
  });
}

/// Shared-store harness: every manager is built over the SAME encrypted
/// settings repository, exactly like successive app processes share one
/// on-device database + Keystore vault.
class Harness {
  Harness()
      : database = InMemoryLocalDatabase(),
        secretStore = InMemorySecretStore() {
    final AesGcmSettingsCipher cipher = AesGcmSettingsCipher(secretStore);
    settings = SecuritySettingsRepositoryImpl(database, cipher: cipher);
  }

  final InMemoryLocalDatabase database;
  final InMemorySecretStore secretStore;
  late final SecuritySettingsRepository settings;

  DefaultCredentialManager get manager => newManager();

  /// A fresh manager over the shared store — the "new process".
  DefaultCredentialManager newManager({BiometricService? biometricService}) {
    return DefaultCredentialManager(
      settings: settings,
      pinHasher: Pbkdf2PinHasher(iterations: 200),
      patternHasher: Pbkdf2PatternHasher(iterations: 200),
      stateMachine: CredentialStateMachine(
        maxFailedAttempts: 3,
        lockoutDuration: Duration(seconds: 30),
      ),
      biometricService: biometricService,
    );
  }

  /// Clears an active lockout directly in the persisted store (stands in
  /// for waiting out the cooldown in real time).
  Future<void> expireLockout() async {
    final current = (await settings.getSettings()).valueOrNull!;
    await settings.saveSettings(current.copyWith(clearLockout: true));
  }
}

/// Test double for the platform biometric bridge.
class _FakeBiometricService implements BiometricService {
  const _FakeBiometricService({
    required this.supported,
    required this.promptResult,
  });

  final bool supported;

  /// What the prompt resolves to. `false` covers both rejections and user
  /// cancellations — exactly like the real local_auth implementation.
  final bool promptResult;

  @override
  Future<Result<bool>> isSupported() async => Result.success(supported);

  @override
  Future<Result<Set<BiometricKind>>> availableKinds() async =>
      Result.success(const <BiometricKind>{
        BiometricKind.strong,
        BiometricKind.deviceCredential,
      });

  @override
  Future<Result<bool>> authenticate({
    required String reason,
    BiometricOptions? options,
  }) async =>
      Result.success(promptResult);
}
