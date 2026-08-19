import 'auth_type.dart';

/// Why an authentication attempt did not succeed.
enum AuthFailureReason {
  /// No credential of the requested type has been enrolled.
  noCredentialEnrolled,

  /// The credential itself was entered incorrectly.
  wrongCredential,

  /// The attempt was cancelled by the user (biometric prompt).
  cancelled,

  /// The mechanism exists but cannot be used right now (e.g. no biometric
  /// service wired, no hardware, no enrolled device biometrics).
  notAvailable,

  /// The mechanism is supported but has not been configured in settings.
  notConfigured,

  /// The input failed local validation (e.g. PIN contains letters).
  invalidInput,
}

/// Outcome of a single authentication attempt.
sealed class AuthAttemptResult {
  const AuthAttemptResult();
}

/// The credential matched — access is granted.
final class AuthSuccess extends AuthAttemptResult {
  const AuthSuccess({required this.type});

  final AuthType type;
}

/// The credential did not match; more attempts may remain.
final class AuthFailure extends AuthAttemptResult {
  const AuthFailure({required this.reason, required this.remainingAttempts});

  final AuthFailureReason reason;
  final int remainingAttempts;
}

/// Authentication is blocked until [retryAt] (lockout cooldown).
final class AuthLockedOut extends AuthAttemptResult {
  const AuthLockedOut({
    required this.retryAt,
    this.attemptsMade,
    this.lockoutStreak = 0,
  });

  final DateTime retryAt;

  /// How many failed attempts triggered this lockout (null when the
  /// lockout was already active before the attempt).
  final int? attemptsMade;

  /// Consecutive lockout count (1 = first). Drives the escalating cooldown
  /// schedule (Phase 2F).
  final int lockoutStreak;
}
