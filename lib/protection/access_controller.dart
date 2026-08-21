import '../utilities/result.dart';
import 'lock_session.dart';

/// Outcome of an access decision for a protected app.
enum AccessDecision {
  /// App opens normally (not locked, or an unlock session is active).
  allow,

  /// User must pass the PIN challenge before the app opens.
  challenge,

  /// App stays blocked (e.g. cooldown after repeated failed attempts).
  deny,
}

/// Central access policy for Smart App Lock.
///
/// Combines inputs from the rules module (what should be locked), the
/// security module (has the user authenticated?), and active [LockSession]s.
/// Implemented when the lock phases land; the decision pipeline is
/// documented in docs/architecture.md.
abstract interface class AccessController {
  /// Decides how to handle a launch attempt of [packageName].
  Future<AccessDecision> evaluate(String packageName);

  /// Called after a successful PIN challenge: opens a temporary unlock
  /// window for [packageName].
  Future<Result<LockSession>> grantAccess(String packageName);

  /// Phase 5J: immediately ends the unlock window for [packageName] —
  /// the protected app re-locks the moment the user leaves it.
  Future<Result<void>> revokeAccess(String packageName);

  /// Phase 5K: immediately ends EVERY unlock window — the screen
  /// turned off, so every protected app re-locks at once.
  Future<Result<void>> revokeAllAccess();
}
