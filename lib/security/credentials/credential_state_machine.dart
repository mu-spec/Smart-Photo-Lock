import 'auth_result.dart';
import 'auth_type.dart';
import 'cooldown_policy.dart';
import 'credential_state.dart';

/// Pure attempt/lockout state machine with escalating cooldowns.
///
/// Rules (Phase 2F):
///  * Failures accumulate toward [maxFailedAttempts].
///  * Reaching the threshold triggers a lockout whose cooldown grows with
///    each consecutive lockout (see [EscalatingCooldownPolicy]).
///  * A successful authentication resets both the attempt counter and the
///    lockout streak.
///  * When a lockout expires, the attempt counter restarts fresh — but the
///    streak persists until a success, so the next lockout is longer.
///
/// Pure Dart: no storage, no clocks of its own (callers pass [DateTime]).
class CredentialStateMachine {
  const CredentialStateMachine({
    this.maxFailedAttempts = 5,
    this.lockoutDuration = const Duration(seconds: 30),
    EscalatingCooldownPolicy? cooldownPolicy,
  }) : _policy = cooldownPolicy ??
            EscalatingCooldownPolicy(
              baseCooldown: lockoutDuration,
              maxCooldown: const Duration(minutes: 10),
            );

  /// Wrong attempts before a cooldown lockout triggers.
  final int maxFailedAttempts;

  /// Base cooldown for the first lockout (kept as a constructor value for
  /// backwards compatibility; the schedule is managed by the policy).
  final Duration lockoutDuration;

  final EscalatingCooldownPolicy _policy;

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
      return (
        state,
        AuthLockedOut(retryAt: lockout, lockoutStreak: state.lockoutStreak),
      );
    }
    final bool lockoutExpired = lockout != null;

    if (credentialMatches) {
      final CredentialState reset = state.copyWith(
        failedAttempts: 0,
        lockoutStreak: 0,
        clearLockout: true,
      );
      return (reset, AuthSuccess(type: attemptType));
    }

    // After an expired lockout the attempt counter restarts fresh, while
    // the streak (and therefore the escalating cooldown) persists.
    final int baseAttempts = lockoutExpired ? 0 : state.failedAttempts;
    final int attempts = baseAttempts + 1;
    if (attempts >= maxFailedAttempts) {
      final int newStreak = state.lockoutStreak + 1;
      final Duration cooldown = _policy.cooldownForStreak(newStreak);
      final DateTime retryAt = now.add(cooldown);
      final CredentialState locked = state.copyWith(
        failedAttempts: attempts,
        lockedOutUntil: retryAt,
        lockoutStreak: newStreak,
      );
      return (
        locked,
        AuthLockedOut(
          retryAt: retryAt,
          attemptsMade: attempts,
          lockoutStreak: newStreak,
        ),
      );
    }

    final CredentialState failed = state.copyWith(
      failedAttempts: attempts,
      clearLockout: lockoutExpired,
    );
    return (
      failed,
      AuthFailure(
        reason: AuthFailureReason.wrongCredential,
        remainingAttempts: maxFailedAttempts - attempts,
      ),
    );
  }
}
