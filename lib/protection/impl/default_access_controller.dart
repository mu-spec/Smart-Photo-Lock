import '../../security/credentials/credential_manager.dart';
import '../../security/credentials/credential_state.dart';
import '../../utilities/result.dart';
import '../access_controller.dart';
import '../lock_session.dart';
import '../protected_app_matcher.dart';

/// Phase 5D/5E implementation of [AccessController].
///
/// Decides how to handle an app becoming active:
///
///  * the package is not in the protected list            -> `allow`;
///  * an unlock [LockSession] for the package is active   -> `allow`
///    (the temporary post-challenge window);
///  * the PIN/pattern authentication is in an active
///    lockout (Phase 2F cooldown)                         -> `deny`
///    (the challenge surface blocks with its countdown);
///  * protected and no active session                     -> `challenge`
///    (the lock trigger must present the PIN);
///  * the protected-list read failed                      -> `challenge`
///    (fail-closed: the decision is unknown, so Smart App Lock errs on
///    the side of protection).
///
/// Phase 5E integration: the controller consults the [CredentialManager]
/// so a lockout state is part of the decision itself — access is never
/// granted while authentication is blocked.
///
/// Sessions live in memory for this phase (a 2-minute window per
/// package, per [LockSession]); persistence lands with the lock-screen
/// phase.
class DefaultAccessController implements AccessController {
  DefaultAccessController({
    required ProtectedAppMatcher matcher,
    required CredentialManager auth,
    DateTime Function()? now,
  })  : _matcher = matcher,
        _auth = auth,
        _now = now ?? DateTime.now;

  final ProtectedAppMatcher _matcher;
  final CredentialManager _auth;
  final DateTime Function() _now;

  /// Active unlock windows keyed by package name.
  final Map<String, LockSession> _sessions = <String, LockSession>{};

  @override
  Future<AccessDecision> evaluate(String packageName) async {
    final ProtectedMatch match = await _matcher.match(packageName);
    if (match.decision == ProtectedMatchDecision.notProtected) {
      return AccessDecision.allow;
    }
    // protected OR unknown (fail-closed) — both require authentication.
    final CredentialState? state = (await _auth.status()).valueOrNull;
    if (state != null && state.statusAt(_now()) == CredentialStatus.lockedOut) {
      return AccessDecision.deny;
    }
    final LockSession? session = _sessions[packageName];
    if (session != null && session.isActiveAt(_now())) {
      // Phase 5H: an allowed re-entry REFRESHES the inactivity window —
      // active use of the protected app never re-prompts mid-session.
      _sessions[packageName] = session.refresh(_now());
      return AccessDecision.allow;
    }
    if (session != null) {
      // Expired — prune it so the map only ever holds live sessions.
      _sessions.remove(packageName);
    }
    return AccessDecision.challenge;
  }

  @override
  Future<Result<LockSession>> grantAccess(String packageName) async {
    final LockSession session = LockSession(
      packageName: packageName,
      grantedAt: _now(),
    );
    _sessions[packageName] = session;
    return Result.success(session);
  }

  /// Phase 5H: the session currently open for [packageName], or null
  /// (diagnostics and tests).
  LockSession? sessionFor(String packageName) => _sessions[packageName];

  @override
  Future<Result<void>> revokeAccess(String packageName) async {
    _sessions.remove(packageName);
    return Result.success(null);
  }

  @override
  Future<Result<void>> revokeAllAccess() async {
    _sessions.clear();
    return Result.success(null);
  }

  /// Test/diagnostic view of the active unlock windows.
  Map<String, LockSession> get activeSessions =>
      Map<String, LockSession>.unmodifiable(_sessions);

  /// Clears every active unlock window (manual lock in a later phase).
  void clearSessions() => _sessions.clear();
}
