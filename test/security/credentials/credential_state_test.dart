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
    );
    final CredentialState restored = CredentialState.fromJson(state.toJson());
    expect(restored.enrolled, state.enrolled);
    expect(restored.primary, AuthType.pin);
    expect(restored.failedAttempts, 3);
    expect(restored.lockedOutUntil, lockoutEnd);
  });

  test('JSON round-trip with no lockout and no primary', () {
    const CredentialState state = CredentialState(enrolled: <AuthType>{});
    final CredentialState restored = CredentialState.fromJson(state.toJson());
    expect(restored.enrolled, isEmpty);
    expect(restored.primary, isNull);
    expect(restored.lockedOutUntil, isNull);
  });
}
