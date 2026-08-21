import '../../utilities/result.dart';
import '../access_controller.dart';
import '../lock_session.dart';
import '../protected_app_matcher.dart';

/// Phase 5D implementation of [AccessController].
///
/// Decides how to handle an app becoming active:
///
///  * the package is not in the protected list            -> `allow`;
///  * an unlock [LockSession] for the package is active   -> `allow`
///    (the temporary post-challenge window);
///  * protected and no active session                     -> `challenge`
///    (the lock trigger must present authentication);
///  * the protected-list read failed                      -> `challenge`
///    (fail-closed: the decision is unknown, so Smart App Lock errs on
///    the side of protection).
///
/// [AccessDecision.deny] is reserved for the cooldown policy in a later
/// phase — 5D never returns it.
///
/// Sessions live in memory for this phase (a 2-minute window per
/// package, per [LockSession]); persistence lands with the lock-screen
/// phase.
class DefaultAccessController implements AccessController {
  DefaultAccessController({
    required ProtectedAppMatcher matcher,
    DateTime Function()? now,
  })  : _matcher = matcher,
        _now = now ?? DateTime.now;

  final ProtectedAppMatcher _matcher;
  final DateTime Function() _now;

  /// Active unlock windows keyed by package name.
  final Map<String, LockSession> _sessions = <String, LockSession>{};

  @override
  Future<AccessDecision> evaluate(String packageName) async {
    final ProtectedMatch match = await _matcher.match(packageName);
    if (match.decision == ProtectedMatchDecision.notProtected) {
      return AccessDecision.allow;
    }
    // protected OR unknown (fail-closed) — both require a session.
    final LockSession? session = _sessions[packageName];
    if (session != null && session.isActiveAt(_now())) {
      return AccessDecision.allow;
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

  /// Test/diagnostic view of the active unlock windows.
  Map<String, LockSession> get activeSessions =>
      Map<String, LockSession>.unmodifiable(_sessions);

  /// Clears every active unlock window (manual lock in a later phase).
  void clearSessions() => _sessions.clear();
}
