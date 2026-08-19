import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/credentials/credential_state.dart';

void main() {
  final DateTime lockoutEnd = DateTime(2026, 8, 19, 12, 1);

  CredentialState enrolledState() => CredentialState(
        enrolled: const <AuthType>{AuthType.pin, AuthType.pattern},
        primary: AuthType.pin,
      );

  test('empty state reports unset', () {
    const CredentialState empty = CredentialState(enrolled: <AuthType>{});
    expect(empty.statusAt(DateTime(2026, 8, 19)), CredentialStatus.unset);
    expect(empty.hasAnyCredential, isFalse);
  });

  test('enrolled state reports enrolled', () {
    expect(enrolledState().statusAt(DateTime(2026, 8, 19)),
        CredentialStatus.enrolled);
  });

  test('active lockout reports lockedOut', () {
    final CredentialState locked = enrolledState().copyWith(
      lockedOutUntil: lockoutEnd,
    );
    expect(
      locked.statusAt(DateTime(2026, 8, 19, 12, 0)),
      CredentialStatus.lockedOut,
    );
    // After the window, back to enrolled.
    expect(
      locked.statusAt(DateTime(2026, 8, 19, 12, 1, 1)),
      CredentialStatus.enrolled,
    );
  });

  test('copyWith can clear the lockout', () {
    final CredentialState locked = enrolledState().copyWith(
      lockedOutUntil: lockoutEnd,
    );
    expect(locked.lockedOutUntil, isNotNull);
    expect(locked.copyWith(clearLockout: true).lockedOutUntil, isNull);
  });

  test('hasEnrolled checks individual types', () {
    final CredentialState state = enrolledState();
    expect(state.hasEnrolled(AuthType.pin), isTrue);
    expect(state.hasEnrolled(AuthType.biometric), isFalse);
  });

  test('JSON round-trip preserves the full snapshot', () {
    final CredentialState state = CredentialState(
      enrolled: const <AuthType>{AuthType.pin, AuthType.biometric},
      primary: AuthType.pin,
      failedAttempts: 3,
      lockedOutUntil: lockoutEnd,
      pinLength: 6,
      lockoutStreak: 2,
    );
    final CredentialState restored = CredentialState.fromJson(state.toJson());
    expect(restored.enrolled, state.enrolled);
    expect(restored.primary, AuthType.pin);
    expect(restored.failedAttempts, 3);
    expect(restored.lockedOutUntil, lockoutEnd);
    expect(restored.pinLength, 6);
    expect(restored.lockoutStreak, 2);
  });

  test('lockoutStreak defaults to zero and survives copyWith', () {
    const CredentialState fresh =
        CredentialState(enrolled: <AuthType>{AuthType.pin});
    expect(fresh.lockoutStreak, 0);

    final CredentialState updated = fresh.copyWith(
      failedAttempts: 1,
      lockoutStreak: 3,
    );
    expect(updated.lockoutStreak, 3);
    expect(updated.copyWith(failedAttempts: 2).lockoutStreak, 3);
  });

  test('randomizedKeypadEnabled defaults off, round-trips and copies',
      () {
    const CredentialState fresh =
        CredentialState(enrolled: <AuthType>{AuthType.pin});
    expect(fresh.randomizedKeypadEnabled, isFalse);

    final CredentialState enabled =
        fresh.copyWith(randomizedKeypadEnabled: true);
    expect(enabled.randomizedKeypadEnabled, isTrue);
    expect(
      CredentialState.fromJson(enabled.toJson()).randomizedKeypadEnabled,
      isTrue,
    );
    // copyWith of unrelated fields preserves the flag.
    expect(enabled.copyWith(failedAttempts: 2).randomizedKeypadEnabled, isTrue);
  });

  test('copyWith preserves pinLength when updating counters', () {
    final CredentialState state = const CredentialState(
      enrolled: <AuthType>{AuthType.pin},
      pinLength: 4,
    );
    final CredentialState updated = state.copyWith(failedAttempts: 2);
    expect(updated.failedAttempts, 2);
    expect(updated.pinLength, 4);
  });

  test('JSON round-trip with no lockout and no primary', () {
    const CredentialState state = CredentialState(enrolled: <AuthType>{});
    final CredentialState restored = CredentialState.fromJson(state.toJson());
    expect(restored.enrolled, isEmpty);
    expect(restored.primary, isNull);
    expect(restored.lockedOutUntil, isNull);
  });
}
