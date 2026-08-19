import 'package:flutter_test/flutter_test.dart';

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
}
