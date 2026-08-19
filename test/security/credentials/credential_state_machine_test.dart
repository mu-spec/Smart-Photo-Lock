import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/credentials/credential_state.dart';
import 'package:smart_app_lock/security/credentials/credential_state_machine.dart';

void main() {
  const CredentialStateMachine machine = CredentialStateMachine(
    maxFailedAttempts: 3,
    lockoutDuration: Duration(seconds: 30),
  );
  final DateTime start = DateTime(2026, 8, 19, 12, 0);
  const CredentialState state = CredentialState(
    enrolled: <AuthType>{AuthType.pin},
    primary: AuthType.pin,
  );

  (CredentialState, AuthAttemptResult) attempt({
    required bool matches,
    required DateTime now,
    CredentialState from = state,
  }) =>
      machine.evaluate(
        state: from,
        credentialMatches: matches,
        attemptType: AuthType.pin,
        now: now,
      );

  test('success resets counters and returns AuthSuccess', () {
    final (CredentialState next, AuthAttemptResult result) = attempt(
      matches: true,
      now: start,
      from: state.copyWith(failedAttempts: 2),
    );
    expect(result, isA<AuthSuccess>());
    expect((result as AuthSuccess).type, AuthType.pin);
    expect(next.failedAttempts, 0);
    expect(next.lockedOutUntil, isNull);
  });

  test('failures accumulate with decreasing remaining attempts', () {
    final (CredentialState s1, AuthAttemptResult r1) = attempt(
      matches: false,
      now: start,
    );
    expect(r1, isA<AuthFailure>());
    expect((r1 as AuthFailure).reason, AuthFailureReason.wrongCredential);
    expect(r1.remainingAttempts, 2);
    expect(s1.failedAttempts, 1);

    final (CredentialState s2, AuthAttemptResult r2) = attempt(
      matches: false,
      now: start,
      from: s1,
    );
    expect((r2 as AuthFailure).remainingAttempts, 1);
    expect(s2.failedAttempts, 2);
  });

  test('reaching the threshold locks out with a retry time', () {
    final CredentialState twoFails = state.copyWith(failedAttempts: 2);
    final (CredentialState next, AuthAttemptResult result) = attempt(
      matches: false,
      now: start,
      from: twoFails,
    );
    expect(result, isA<AuthLockedOut>());
    final AuthLockedOut lockout = result as AuthLockedOut;
    expect(lockout.retryAt, start.add(const Duration(seconds: 30)));
    expect(lockout.attemptsMade, 3);
    expect(next.lockedOutUntil, lockout.retryAt);
    expect(next.failedAttempts, 3);
  });

  test('an active lockout blocks even a correct credential', () {
    final CredentialState locked = state.copyWith(
      failedAttempts: 3,
      lockedOutUntil: start.add(const Duration(seconds: 30)),
    );
    final (CredentialState next, AuthAttemptResult result) = attempt(
      matches: true,
      now: start.add(const Duration(seconds: 5)),
      from: locked,
    );
    expect(result, isA<AuthLockedOut>());
    expect((result as AuthLockedOut).retryAt, locked.lockedOutUntil);
    expect(next, locked); // state untouched while locked out
  });

  test('after the retry time, a correct credential succeeds', () {
    final CredentialState locked = state.copyWith(
      failedAttempts: 3,
      lockedOutUntil: start.add(const Duration(seconds: 30)),
    );
    final (CredentialState next, AuthAttemptResult result) = attempt(
      matches: true,
      now: start.add(const Duration(seconds: 31)),
      from: locked,
    );
    expect(result, isA<AuthSuccess>());
    expect(next.failedAttempts, 0);
    expect(next.lockedOutUntil, isNull);
  });

  test('custom thresholds and durations are respected', () {
    const CredentialStateMachine custom = CredentialStateMachine(
      maxFailedAttempts: 2,
      lockoutDuration: Duration(minutes: 5),
    );
    final (CredentialState s1, AuthAttemptResult r1) = custom.evaluate(
      state: state,
      credentialMatches: false,
      attemptType: AuthType.pin,
      now: start,
    );
    expect((r1 as AuthFailure).remainingAttempts, 1);

    final (_, AuthAttemptResult r2) = custom.evaluate(
      state: s1,
      credentialMatches: false,
      attemptType: AuthType.pin,
      now: start,
    );
    expect((r2 as AuthLockedOut).retryAt,
        start.add(const Duration(minutes: 5)));
  });

  // -------------------------------------------------------------------
  // Phase 2F — escalating cooldowns
  // -------------------------------------------------------------------
  test('second consecutive lockout escalates the cooldown', () {
    // Simulate a prior lockout cycle: streak 1, attempts just reset.
    final CredentialState afterFirstCycle = state.copyWith(
      failedAttempts: 0,
      lockoutStreak: 1,
    );

    final (CredentialState s1, AuthAttemptResult _) = attempt(
      matches: false,
      now: start,
      from: afterFirstCycle,
    );
    final (CredentialState s2, AuthAttemptResult _) = attempt(
      matches: false,
      now: start,
      from: s1,
    );
    final (CredentialState s3, AuthAttemptResult r3) = attempt(
      matches: false,
      now: start,
      from: s2,
    );

    expect(r3, isA<AuthLockedOut>());
    final AuthLockedOut lockout = r3 as AuthLockedOut;
    // Streak 2 -> base 30s x 2 = 60s.
    expect(lockout.retryAt, start.add(const Duration(seconds: 60)));
    expect(lockout.lockoutStreak, 2);
    expect(s3.lockoutStreak, 2);
  });

  test('third consecutive lockout doubles again (2 minutes)', () {
    final CredentialState afterSecondCycle = state.copyWith(
      lockoutStreak: 2,
    );
    final (CredentialState s1, AuthAttemptResult _) = attempt(
      matches: false,
      now: start,
      from: afterSecondCycle,
    );
    final (CredentialState s2, AuthAttemptResult _) = attempt(
      matches: false,
      now: start,
      from: s1,
    );
    final (_, AuthAttemptResult r3) = attempt(
      matches: false,
      now: start,
      from: s2,
    );
    final AuthLockedOut lockout = r3 as AuthLockedOut;
    expect(lockout.retryAt, start.add(const Duration(minutes: 2)));
    expect(lockout.lockoutStreak, 3);
  });

  test('a successful authentication resets the lockout streak', () {
    final CredentialState afterTwoLockouts =
        state.copyWith(failedAttempts: 2, lockoutStreak: 2);
    final (CredentialState next, AuthAttemptResult result) = attempt(
      matches: true,
      now: start,
      from: afterTwoLockouts,
    );
    expect(result, isA<AuthSuccess>());
    expect(next.lockoutStreak, 0);
    expect(next.failedAttempts, 0);
  });

  test('ordinary failures (no lockout) leave the streak untouched', () {
    final CredentialState withStreak =
        state.copyWith(lockoutStreak: 1);
    final (CredentialState next, AuthAttemptResult result) = attempt(
      matches: false,
      now: start,
      from: withStreak,
    );
    expect(result, isA<AuthFailure>());
    expect(next.lockoutStreak, 1);
  });

  test('expired lockout restarts the attempt counter but keeps the streak',
      () {
    final CredentialState expired = state.copyWith(
      failedAttempts: 3,
      lockedOutUntil: start.subtract(const Duration(seconds: 1)),
      lockoutStreak: 1,
    );
    final (CredentialState next, AuthAttemptResult result) = attempt(
      matches: false,
      now: start,
      from: expired,
    );
    expect(result, isA<AuthFailure>());
    // Fresh cycle: 1 of 3 used -> 2 remaining; no immediate re-lockout.
    expect((result as AuthFailure).remainingAttempts, 2);
    expect(next.failedAttempts, 1);
    expect(next.lockedOutUntil, isNull); // expired lockout cleared
    expect(next.lockoutStreak, 1); // streak persists until a success
  });
}
