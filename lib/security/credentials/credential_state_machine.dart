import 'auth_result.dart';
import 'auth_type.dart';
import 'credential_state.dart';

/// Pure attempt/lockout state machine.
///
/// One place decides what happens on success, failure, and lockout — so
/// every authentication flow (PIN, pattern, biometric) behaves identically.
/// Pure Dart: no storage, no clocks of its own (callers pass [DateTime]).
class CredentialStateMachine {
  const CredentialStateMachine({
    this.maxFailedAttempts = 5,
    this.lockoutDuration = const Duration(seconds: 30),
  });

  /// Wrong attempts before a cooldown lockout triggers.
  final int maxFailedAttempts;

  /// Cooldown window applied when the threshold is reached.
  final Duration lockoutDuration;

  /// Evaluates one attempt and returns the next state together with the
  /// result. [credentialMatches] must be pre-computed by the caller
  /// (hashing/verification happens outside this machine).
  (CredentialState, AuthAttemptResult) evaluate({
    required CredentialState state,
    required bool credentialMatches,
    required AuthType attemptType,
    required DateTime now,
  }) {
    // An active lockout blocks everything, even a correct credential.
    final DateTime? lockout = state.lockedOutUntil;
    if (lockout != null && now.isBefore(lockout)) {
      return (state, AuthLockedOut(retryAt: lockout));
    }

    if (credentialMatches) {
      final CredentialState reset = state.copyWith(
        failedAttempts: 0,
        clearLockout: true,
      );
      return (reset, AuthSuccess(type: attemptType));
    }

    final int attempts = state.failedAttempts + 1;
    if (attempts >= maxFailedAttempts) {
      final DateTime retryAt = now.add(lockoutDuration);
      final CredentialState locked = state.copyWith(
        failedAttempts: attempts,
        lockedOutUntil: retryAt,
      );
      return (locked, AuthLockedOut(retryAt: retryAt, attemptsMade: attempts));
    }

    final CredentialState failed = state.copyWith(failedAttempts: attempts);
    return (
      failed,
      AuthFailure(
        reason: AuthFailureReason.wrongCredential,
        remainingAttempts: maxFailedAttempts - attempts,
      ),
    );
  }
}
