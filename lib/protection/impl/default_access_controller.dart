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

  /// Phase 5L: per-package grace deadlines — while the clock is before
  /// this moment, re-entering a left app is allowed without
  /// re-authentication.
  final Map<String, DateTime> _graceUntil = <String, DateTime>{};

  /// Phase 5L: the re-lock grace applied when the user LEAVES a
  /// protected app. Zero = immediate re-lock (the 5J default).
  Duration _gracePeriod = Duration.zero;

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
    final DateTime? graceUntil = _graceUntil[packageName];
    if (session != null) {
      if (graceUntil != null) {
        if (_now().isBefore(graceUntil)) {
          // Phase 5L: re-entry within the grace period — allowed
          // without re-authentication. The grace marker is consumed
          // and the session refreshed so the NEXT leave starts a fresh
          // grace clock.
          _graceUntil.remove(packageName);
          _sessions[packageName] = session.refresh(_now());
          return AccessDecision.allow;
        }
        // Grace expired: fall through to revocation + challenge.
        _graceUntil.remove(packageName);
        _sessions.remove(packageName);
        return AccessDecision.challenge;
      }
      if (session.isActiveAt(_now())) {
        // Phase 5H: an allowed re-entry REFRESHES the inactivity window —
        // active use of the protected app never re-prompts mid-session.
        _sessions[packageName] = session.refresh(_now());
        return AccessDecision.allow;
      }
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
    // Phase 5L: with a grace period configured, leaving starts the
    // grace clock instead of removing the session — re-entry within
    // the grace is allowed. Without grace (zero), the session ends
    // immediately (the 5J default).
    if (_gracePeriod > Duration.zero && _sessions.containsKey(packageName)) {
      _graceUntil[packageName] = _now().add(_gracePeriod);
      return Result.success(null);
    }
    _sessions.remove(packageName);
    _graceUntil.remove(packageName);
    return Result.success(null);
  }

  @override
  Future<Result<void>> revokeAllAccess() async {
    // Phase 5K/5L: screen-off re-locks EVERYTHING immediately — the
    // grace period never softens a screen-off.
    _sessions.clear();
    _graceUntil.clear();
    return Result.success(null);
  }

  @override
  void setGracePeriod(Duration period) {
    final Duration clamped = period.isNegative ? Duration.zero : period;
    _gracePeriod = clamped;
    if (clamped == Duration.zero) {
      // Immediate: every package currently AWAY (pending grace clock)
      // re-locks NOW — its session dies with its deadline instead of
      // lingering on the inactivity window.
      for (final String package in _graceUntil.keys) {
        _sessions.remove(package);
      }
      _graceUntil.clear();
      return;
    }
    // Audit fix: a SHRUNKEN grace invalidates the portion of any
    // pending deadline that now outlives it — clamp each deadline to
    // now + the new grace, so the new policy takes effect immediately.
    final DateTime cap = _now().add(clamped);
    for (final MapEntry<String, DateTime> entry in _graceUntil.entries) {
      if (entry.value.isAfter(cap)) {
        _graceUntil[entry.key] = cap;
      }
    }
  }

  /// Test/diagnostic view of the active unlock windows.
  Map<String, LockSession> get activeSessions =>
      Map<String, LockSession>.unmodifiable(_sessions);

  /// Clears every active unlock window AND grace deadline (manual lock
  /// in a later phase).
  void clearSessions() {
    _sessions.clear();
    _graceUntil.clear();
  }
}
