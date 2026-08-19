import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/data/models/security_settings.dart';
import 'package:smart_app_lock/data/repositories/impl/security_settings_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/security_settings_repository.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/credentials/biometric_options.dart';
import 'package:smart_app_lock/security/credentials/credential_manager.dart';
import 'package:smart_app_lock/security/credentials/credential_state.dart';
import 'package:smart_app_lock/security/credentials/credential_state_machine.dart';
import 'package:smart_app_lock/security/credentials/impl/default_credential_manager.dart';
import 'package:smart_app_lock/security/credentials/pattern_hasher.dart';
import 'package:smart_app_lock/security/pin_hasher.dart';
import 'package:smart_app_lock/security/pin_policy.dart';
import 'package:smart_app_lock/services/biometric_service.dart';
import 'package:smart_app_lock/utilities/result.dart';

void main() {
  // Fast hashers + a low lockout threshold so the suite stays quick.
  late SecuritySettingsRepository settings;
  late CredentialManager manager;

  setUp(() {
    settings = SecuritySettingsRepositoryImpl(InMemoryLocalDatabase());
    manager = DefaultCredentialManager(
      settings: settings,
      pinHasher: Pbkdf2PinHasher(iterations: 200),
      patternHasher: Pbkdf2PatternHasher(iterations: 200),
      stateMachine: const CredentialStateMachine(
        maxFailedAttempts: 3,
        lockoutDuration: Duration(seconds: 30),
      ),
    );
  });

  test('starts unset', () async {
    final CredentialState state = (await manager.status()).valueOrNull!;
    expect(state.status, CredentialStatus.unset);
    expect(state.hasAnyCredential, isFalse);
    expect(state.primary, isNull);
  });

  test('enrollPin validates, enrolls and becomes primary', () async {
    expect((await manager.enrollPin('12')).isFailure, isTrue); // too short
    expect((await manager.enrollPin('abcd')).isFailure, isTrue); // non-digits

    await manager.enrollPin('1234');
    final CredentialState state = (await manager.status()).valueOrNull!;
    expect(state.hasEnrolled(AuthType.pin), isTrue);
    expect(state.primary, AuthType.pin);
    expect(state.status, CredentialStatus.enrolled);
  });

  test('enrollPin records the PIN length for the unlock screen', () async {
    await manager.enrollPin('1234');
    expect((await manager.status()).valueOrNull!.pinLength, 4);

    await manager.enrollPin('246810');
    expect((await manager.status()).valueOrNull!.pinLength, 6);
  });

  test('PIN authentication succeeds with the right PIN', () async {
    await manager.enrollPin('1234');
    final result = (await manager.authenticatePin('1234')).valueOrNull!;
    expect(result, isA<AuthSuccess>());
  });

  test('PIN authentication fails with the wrong PIN and counts attempts',
      () async {
    await manager.enrollPin('1234');
    final AuthAttemptResult r1 =
        (await manager.authenticatePin('0000')).valueOrNull!;
    expect(r1, isA<AuthFailure>());
    expect((r1 as AuthFailure).reason, AuthFailureReason.wrongCredential);
    expect(r1.remainingAttempts, 2);
    expect((await manager.status()).valueOrNull!.failedAttempts, 1);
  });

  test('lockout triggers at the threshold and persists across instances',
      () async {
    await manager.enrollPin('1234');

    await manager.authenticatePin('0000');
    await manager.authenticatePin('0000');
    final AuthAttemptResult r3 =
        (await manager.authenticatePin('0000')).valueOrNull!;
    expect(r3, isA<AuthLockedOut>());

    // A fresh manager over the same store (simulates an app restart):
    // the lockout must survive — correct PINs stay blocked.
    final CredentialManager restarted = DefaultCredentialManager(
      settings: settings,
      pinHasher: Pbkdf2PinHasher(iterations: 200),
      patternHasher: Pbkdf2PatternHasher(iterations: 200),
    );
    final CredentialState state = (await restarted.status()).valueOrNull!;
    expect(state.status, CredentialStatus.lockedOut);
    expect(state.lockedOutUntil, isNotNull);

    final AuthAttemptResult blocked =
        (await restarted.authenticatePin('1234')).valueOrNull!;
    expect(blocked, isA<AuthLockedOut>());
  });

  test('pattern enrollment validates, is direction-independent and primary',
      () async {
    expect(
      (await manager.enrollPattern(const <int>[1, 2])).isFailure,
      isTrue, // too short
    );
    expect(
      (await manager.enrollPattern(const <int>[1, 1, 2, 3])).isFailure,
      isTrue, // duplicate
    );

    await manager.enrollPattern(const <int>[1, 2, 3, 6]);
    final CredentialState state = (await manager.status()).valueOrNull!;
    expect(state.hasEnrolled(AuthType.pattern), isTrue);
    expect(state.primary, AuthType.pattern);

    // Same shape, reversed drawing direction — must authenticate.
    final AuthAttemptResult result =
        (await manager.authenticatePattern(const <int>[6, 3, 2, 1]))
            .valueOrNull!;
    expect(result, isA<AuthSuccess>());

    // Different shape — must fail.
    final AuthAttemptResult wrong =
        (await manager.authenticatePattern(const <int>[1, 2, 3, 5]))
            .valueOrNull!;
    expect(wrong, isA<AuthFailure>());
  });

  test('both credentials can be enrolled; latest enrollment is primary',
      () async {
    await manager.enrollPin('1234');
    await manager.enrollPattern(const <int>[1, 4, 7, 8]);

    final CredentialState state = (await manager.status()).valueOrNull!;
    expect(state.hasEnrolled(AuthType.pin), isTrue);
    expect(state.hasEnrolled(AuthType.pattern), isTrue);
    expect(state.primary, AuthType.pattern);

    // PIN still works even when pattern is primary.
    final AuthAttemptResult pin = (await manager.authenticatePin('1234'))
        .valueOrNull!;
    expect(pin, isA<AuthSuccess>());
  });

  test('biometric enrollment records options and auth fails gracefully',
      () async {
    await manager.updateBiometricOptions(
      const BiometricOptions(allowDeviceCredential: false),
    );
    final CredentialState state = (await manager.status()).valueOrNull!;
    expect(state.hasEnrolled(AuthType.biometric), isTrue);

    // No platform service wired yet -> explicit failure, never a fake pass.
    final AuthAttemptResult result =
        (await manager.authenticateBiometric()).valueOrNull!;
    expect(result, isA<AuthFailure>());
    expect((result as AuthFailure).reason, AuthFailureReason.notAvailable);
  });

  test('authenticate with no enrolled credential fails with a clear reason',
      () async {
    final AuthAttemptResult result =
        (await manager.authenticatePin('1234')).valueOrNull!;
    expect(result, isA<AuthFailure>());
    expect((result as AuthFailure).reason,
        AuthFailureReason.noCredentialEnrolled);
  });

  test('clearAll removes every credential and resets counters', () async {
    await manager.enrollPin('1234');
    await manager.enrollPattern(const <int>[1, 4, 7, 8]);
    await manager.updateBiometricOptions(BiometricOptions.defaults);
    await manager.authenticatePin('0000');

    await manager.clearAll();

    final CredentialState state = (await manager.status()).valueOrNull!;
    expect(state.status, CredentialStatus.unset);
    expect(state.enrolled, isEmpty);
    expect(state.failedAttempts, 0);
    expect(state.lockedOutUntil, isNull);
  });

  test('successful authentication resets the failure counter', () async {
    await manager.enrollPin('1234');
    await manager.authenticatePin('0000');
    await manager.authenticatePin('0000');
    expect((await manager.status()).valueOrNull!.failedAttempts, 2);

    final AuthAttemptResult ok =
        (await manager.authenticatePin('1234')).valueOrNull!;
    expect(ok, isA<AuthSuccess>());
    expect((await manager.status()).valueOrNull!.failedAttempts, 0);
  });

  // -------------------------------------------------------------------
  // Phase 2F — failed-attempt tracking & escalating cooldown persistence
  // -------------------------------------------------------------------
  test('a lockout carries its streak and persists it', () async {
    await manager.enrollPin('1234');

    await manager.authenticatePin('0000');
    await manager.authenticatePin('0000');
    final AuthAttemptResult r3 =
        (await manager.authenticatePin('0000')).valueOrNull!;
    expect(r3, isA<AuthLockedOut>());
    expect((r3 as AuthLockedOut).lockoutStreak, 1);

    final CredentialState state = (await manager.status()).valueOrNull!;
    expect(state.lockoutStreak, 1);
  });

  test('the lockout streak survives a simulated app restart', () async {
    await manager.enrollPin('1234');
    await manager.authenticatePin('0000');
    await manager.authenticatePin('0000');
    await manager.authenticatePin('0000');

    final CredentialManager restarted = DefaultCredentialManager(
      settings: settings,
      pinHasher: Pbkdf2PinHasher(iterations: 200),
      patternHasher: Pbkdf2PatternHasher(iterations: 200),
    );
    final CredentialState state = (await restarted.status()).valueOrNull!;
    expect(state.lockoutStreak, 1);
    expect(state.status, CredentialStatus.lockedOut);
  });

  test('a successful authentication resets the persisted streak', () async {
    await manager.enrollPin('1234');
    await manager.authenticatePin('0000');
    await manager.authenticatePin('0000');
    await manager.authenticatePin('0000');
    expect((await manager.status()).valueOrNull!.lockoutStreak, 1);

    // Wait out the 30s lockout by clearing it through settings (the
    // manager has no clock seam), then succeed.
    final SecuritySettings cleared = (await settings.getSettings())
        .valueOrNull!
        .copyWith(clearLockout: true);
    await settings.saveSettings(cleared);

    final AuthAttemptResult ok =
        (await manager.authenticatePin('1234')).valueOrNull!;
    expect(ok, isA<AuthSuccess>());
    expect((await manager.status()).valueOrNull!.lockoutStreak, 0);
  });

  // -------------------------------------------------------------------
  // Phase 2J — biometric foundation (manager side)
  // -------------------------------------------------------------------
  test('biometric auth succeeds through the platform service', () async {
    await manager.enrollPin('1234');
    await manager.updateBiometricOptions(BiometricOptions.defaults);
    final CredentialManager bio = DefaultCredentialManager(
      settings: settings,
      pinHasher: Pbkdf2PinHasher(iterations: 200),
      patternHasher: Pbkdf2PatternHasher(iterations: 200),
      biometricService: const _FakeBiometricService(supported: true, passes: true),
    );

    final AuthAttemptResult result =
        (await bio.authenticateBiometric()).valueOrNull!;
    expect(result, isA<AuthSuccess>());
    expect((result as AuthSuccess).type, AuthType.biometric);
  });

  test('biometric success resets failure counters', () async {
    await manager.enrollPin('1234');
    await manager.updateBiometricOptions(BiometricOptions.defaults);
    final CredentialManager bio = DefaultCredentialManager(
      settings: settings,
      pinHasher: Pbkdf2PinHasher(iterations: 200),
      patternHasher: Pbkdf2PatternHasher(iterations: 200),
      biometricService: const _FakeBiometricService(supported: true, passes: true),
    );

    await bio.authenticatePin('0000');
    await bio.authenticatePin('0000');
    expect((await bio.status()).valueOrNull!.failedAttempts, 2);

    await bio.authenticateBiometric();
    expect((await bio.status()).valueOrNull!.failedAttempts, 0);
  });

  test('biometric failure counts as a failed attempt', () async {
    await manager.enrollPin('1234');
    await manager.updateBiometricOptions(BiometricOptions.defaults);
    final CredentialManager bio = DefaultCredentialManager(
      settings: settings,
      pinHasher: Pbkdf2PinHasher(iterations: 200),
      patternHasher: Pbkdf2PatternHasher(iterations: 200),
      stateMachine: const CredentialStateMachine(
        maxFailedAttempts: 3,
        lockoutDuration: Duration(seconds: 30),
      ),
      biometricService:
          const _FakeBiometricService(supported: true, passes: false),
    );

    final AuthAttemptResult r1 =
        (await bio.authenticateBiometric()).valueOrNull!;
    expect(r1, isA<AuthFailure>());
    expect((r1 as AuthFailure).reason, AuthFailureReason.wrongCredential);
    expect(r1.remainingAttempts, 2);
    expect((await bio.status()).valueOrNull!.failedAttempts, 1);
  });

  test('biometric requires opt-in: notConfigured without options', () async {
    await manager.enrollPin('1234');
    // No updateBiometricOptions call.
    final AuthAttemptResult result =
        (await manager.authenticateBiometric()).valueOrNull!;
    expect(result, isA<AuthFailure>());
    expect((result as AuthFailure).reason, AuthFailureReason.notConfigured);
  });

  test('biometric requires a primary credential', () async {
    // No PIN/pattern enrolled, but biometric options set.
    await manager.updateBiometricOptions(BiometricOptions.defaults);
    final AuthAttemptResult result =
        (await manager.authenticateBiometric()).valueOrNull!;
    expect(result, isA<AuthFailure>());
    expect((result as AuthFailure).reason, AuthFailureReason.notConfigured);
  });

  test('unsupported hardware reports notAvailable', () async {
    await manager.enrollPin('1234');
    await manager.updateBiometricOptions(BiometricOptions.defaults);
    final CredentialManager bio = DefaultCredentialManager(
      settings: settings,
      pinHasher: Pbkdf2PinHasher(iterations: 200),
      patternHasher: Pbkdf2PatternHasher(iterations: 200),
      biometricService:
          const _FakeBiometricService(supported: false, passes: true),
    );

    final AuthAttemptResult result =
        (await bio.authenticateBiometric()).valueOrNull!;
    expect(result, isA<AuthFailure>());
    expect((result as AuthFailure).reason, AuthFailureReason.notAvailable);
  });

  test('an active lockout blocks even the correct biometric', () async {
    await manager.enrollPin('1234');
    await manager.updateBiometricOptions(BiometricOptions.defaults);
    final CredentialManager bio = DefaultCredentialManager(
      settings: settings,
      pinHasher: Pbkdf2PinHasher(iterations: 200),
      patternHasher: Pbkdf2PatternHasher(iterations: 200),
      stateMachine: const CredentialStateMachine(
        maxFailedAttempts: 3,
        lockoutDuration: Duration(seconds: 30),
      ),
      biometricService: const _FakeBiometricService(supported: true, passes: true),
    );

    await bio.authenticatePin('0000');
    await bio.authenticatePin('0000');
    await bio.authenticatePin('0000');
    expect((await bio.status()).valueOrNull!.status, CredentialStatus.lockedOut);

    final AuthAttemptResult result =
        (await bio.authenticateBiometric()).valueOrNull!;
    expect(result, isA<AuthLockedOut>());
  });

  test('updateBiometricOptions(null) disables biometric enrollment',
      () async {
    await manager.updateBiometricOptions(BiometricOptions.defaults);
    expect(
      (await manager.status()).valueOrNull!.hasEnrolled(AuthType.biometric),
      isTrue,
    );

    await manager.updateBiometricOptions(null);
    expect(
      (await manager.status()).valueOrNull!.hasEnrolled(AuthType.biometric),
      isFalse,
    );
  });

  // -------------------------------------------------------------------
  // Phase 2K — pattern visibility setting
  // -------------------------------------------------------------------
  test('setPatternVisibilityEnabled persists through status and settings',
      () async {
    expect(
      (await manager.status()).valueOrNull!.patternVisibilityEnabled,
      isTrue,
    );

    await manager.setPatternVisibilityEnabled(false);
    expect(
      (await manager.status()).valueOrNull!.patternVisibilityEnabled,
      isFalse,
    );
    final settings = (await settings.getSettings()).valueOrNull!;
    expect(settings.patternVisibilityEnabled, isFalse);

    await manager.setPatternVisibilityEnabled(true);
    expect(
      (await manager.status()).valueOrNull!.patternVisibilityEnabled,
      isTrue,
    );
  });
}

/// Test double for the platform biometric bridge.
class _FakeBiometricService implements BiometricService {
  const _FakeBiometricService({required this.supported, required this.passes});

  final bool supported;
  final bool passes;

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
      Result.success(passes);
}
