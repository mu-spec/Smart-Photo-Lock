// Phase 12 / Milestone 1 — Intruder Defense foundation.
//
// The narrow, observe-only contract between the credential manager (the
// single authority for PIN / pattern / biometric verdicts) and anything that
// wants to *learn about* completed verifications (the intruder monitor).
//
// Nothing here can influence a verdict: the observer returns void, is never
// awaited, and its exceptions are swallowed by the manager.
import 'dart:async';

import 'auth_result.dart';
import 'auth_type.dart';

/// Where a verification was started from. Attribution only — never authority.
enum AuthAttemptSurface {
  /// A protected-app lock challenge (HB-1 recorder route).
  protectedAppChallenge,

  /// Smart App Lock itself (app unlock, CR-3 verification, unprotect gate) —
  /// any verification without a challenge context.
  smartAppLock,
}

/// Immutable attribution for a verification, carried in a [Zone] from the
/// caller that started it (the challenge recorder) to the manager, which
/// captures it when the call STARTS. A verification that completes after its
/// route closed is therefore still attributed to its own challenge.
///
/// Holds no secret and grants nothing.
final class AuthAttemptContext {
  const AuthAttemptContext.protectedAppChallenge({
    required String this.packageName,
    required int this.generation,
    required int this.challengeSerial,
  }) : surface = AuthAttemptSurface.protectedAppChallenge;

  const AuthAttemptContext._smartAppLock()
      : surface = AuthAttemptSurface.smartAppLock,
        packageName = null,
        generation = null,
        challengeSerial = null;

  /// The context of a verification started outside any challenge.
  static const AuthAttemptContext smartAppLock =
      AuthAttemptContext._smartAppLock();

  final AuthAttemptSurface surface;

  /// Protected package the challenge was shown for (challenge only).
  final String? packageName;

  /// Native challenge ticket generation (challenge only).
  final int? generation;

  /// The host's challenge serial at presentation (challenge only).
  final int? challengeSerial;

  static final Object _zoneKey = Object();

  /// The context of the current call chain, or [smartAppLock] when none.
  static AuthAttemptContext get current =>
      Zone.current[_zoneKey] as AuthAttemptContext? ?? smartAppLock;

  /// Runs [body] with this context attached to its call chain.
  R run<R>(R Function() body) =>
      runZoned<R>(body, zoneValues: <Object, Object>{_zoneKey: this});

  @override
  String toString() => surface == AuthAttemptSurface.protectedAppChallenge
      ? 'AuthAttemptContext(challenge, pkg=<redacted>, gen=$generation, '
          'serial=$challengeSerial)'
      : 'AuthAttemptContext(app)';
}

/// One completed, counted verification, reported AFTER the manager computed
/// its verdict and attempted to persist the counters.
///
/// Carries no credential material: no PIN, no pattern, no length, no hash.
final class VerifiedAttempt {
  const VerifiedAttempt({
    required this.verificationId,
    required this.type,
    required this.matched,
    required this.result,
    required this.counterPersisted,
    required this.lockoutStreak,
    required this.context,
    required this.at,
  });

  /// Unique per verification (`instanceNonce:sequence`); dedup key.
  final String verificationId;

  final AuthType type;

  /// Whether the presented credential matched.
  final bool matched;

  /// The state machine's verdict for this verification.
  final AuthAttemptResult result;

  /// Whether the attempt counters for this verdict were written.
  final bool counterPersisted;

  /// The lockout streak the state machine produced for this verdict.
  final int lockoutStreak;

  final AuthAttemptContext context;

  /// Wall clock at the verdict — display only, never identity or order.
  final DateTime at;
}

/// Observe-only sink for [VerifiedAttempt]s.
///
/// Implementations MUST return quickly and never block: the manager calls
/// this synchronously, does not await anything, and ignores exceptions.
abstract interface class VerifiedAttemptObserver {
  void onVerifiedAttempt(VerifiedAttempt attempt);
}
