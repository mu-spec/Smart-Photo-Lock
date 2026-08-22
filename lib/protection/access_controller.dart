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
  ///
  /// Phase 5L: when a grace period is configured, this STARTS the grace
  /// clock instead of removing the session — re-entering within the
  /// grace is allowed without re-authentication.
  Future<Result<void>> revokeAccess(String packageName);

  /// Phase 5 mobile-QA fix #4A: revokes access for EVERY package except
  /// [keepPackage], applying the grace policy per package. Used when the
  /// lock trigger has no memory of the previous foreground (a blind
  /// start), so a session for a protected app the user just left can
  /// never survive the transition — the same immediate/grace re-lock
  /// policy as [revokeAccess], just for the whole session map at once.
  Future<Result<void>> revokeAllExcept(String keepPackage);

  /// Phase 5K: immediately ends EVERY unlock window — the screen
  /// turned off, so every protected app re-locks at once. The grace
  /// period NEVER applies here (screen-off is a hard security signal).
  Future<Result<void>> revokeAllAccess();

  /// Phase 5L: configures the re-lock grace period applied when the
  /// user leaves a protected app (zero = immediate re-lock).
  void setGracePeriod(Duration period);

  /// Phase 5 mobile-QA fix #4A: the re-lock grace currently configured
  /// (zero = immediate re-lock). The app layer reads it at startup so
  /// applying the persisted default never clobbers a grace that was
  /// already configured before the host started (e.g. an in-memory
  /// boot or a test seeding it directly).
  Duration get gracePeriod;
}
