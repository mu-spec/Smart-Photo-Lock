import 'dart:async';

import 'package:flutter/material.dart';

import '../protection/access_controller.dart';
import '../protection/lock_trigger.dart';
import '../security/credentials/auth_type.dart';
import '../security/credentials/credential_state.dart';
import 'app_container.dart';
import 'app_scope.dart';
import 'router.dart';

/// Phase 5D/5E/5F/5K: presents the lock challenge when a protected
/// application becomes active — the user's PRIMARY credential (PIN or
/// pattern) gates access.
///
/// Owns the production lifecycle of the lock trigger:
///  * starts the trigger (monitor + evaluation pipeline) on mount,
///    stops it on unmount;
///  * on a [LockRequired] event: brings Smart App Lock to the front
///    through the overlay bridge (`showLockChallenge`), then pushes the
///    unlock screen for the PRIMARY enrolled credential — pattern
///    unlock for pattern-primary users, PIN unlock for PIN-primary
///    users (5F: both credentials are first-class gates);
///  * a correct credential grants the package an unlock window
///    ([AccessController.grantAccess]) and then LAUNCHES the protected
///    app (Phase 5E);
///  * a wrong credential, a cancelled challenge or an active lockout
///    leaves the protected app blocked.
///
/// Phase 5K (screen-off re-lock): when the app resumes after a screen
/// turn-off, the host re-evaluates the current foreground — a protected
/// app whose session was revoked by the screen-off is challenged again
/// immediately.
///
/// Fail-safe: when NO credential is enrolled there is nothing to
/// challenge with — the trigger requirement is ignored (setup lives on
/// the Security tab). Re-entrant requirements while a challenge is
/// already showing are ignored.
class LockChallengeHost extends StatefulWidget {
  const LockChallengeHost({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  /// The app's navigator (the host wraps the MaterialApp, so routes are
  /// pushed through this key).
  final GlobalKey<NavigatorState> navigatorKey;

  final Widget child;

  @override
  State<LockChallengeHost> createState() => _LockChallengeHostState();
}

class _LockChallengeHostState extends State<LockChallengeHost>
    with WidgetsBindingObserver {
  LockTrigger? _trigger;
  StreamSubscription<LockRequired>? _subscription;

  /// True while an unlock challenge is on screen (blocks re-entrancy).
  bool _challenging = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _trigger = AppScope.read(context)?.lockTrigger;
    _subscription = _trigger?.lockRequired.listen(_onLockRequired);
    _trigger?.start();
  }

  @override
  void dispose() {
    // Stop exactly what this host started: the subscription and the
    // trigger (which stops the monitor's polling timer).
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    _trigger?.stop();
    super.dispose();
  }

  /// Phase 5K: when the app resumes after a screen turn-off, enforce
  /// the re-lock — re-evaluate the current foreground and challenge a
  /// protected app whose session the screen-off revoked.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _onResumed();
    }
  }

  Future<void> _onResumed() async {
    final LockTrigger? trigger = _trigger;
    final AppContainer? container = AppScope.read(context);
    if (trigger == null || container == null || !mounted) {
      return;
    }
    // Only screen-off re-lock enforcement — a plain resume (e.g. the
    // user simply returning to Smart App Lock) must not re-challenge a
    // still-valid session.
    if (!trigger.takeScreenOffPending()) {
      return;
    }
    // Refresh detection, then evaluate the last known foreground.
    await container.foregroundMonitor.probe();
    if (!mounted) {
      return;
    }
    final String? current = container.foregroundMonitor.currentPackage;
    if (current == null) {
      return;
    }
    final AccessDecision decision =
        await container.accessController.evaluate(current);
    if (!mounted) {
      return;
    }
    if (decision == AccessDecision.challenge ||
        decision == AccessDecision.deny) {
      await _presentChallenge(current);
    }
  }

  Future<void> _onLockRequired(LockRequired requirement) =>
      _presentChallenge(requirement.packageName);

  Future<void> _presentChallenge(String packageName) async {
    if (_challenging || !mounted) {
      return;
    }
    final AppContainer? container = AppScope.read(context);
    if (container == null) {
      return;
    }

    // Fail-safe: without an enrolled credential there is no challenge
    // to present — never lock the user out of their own phone.
    final CredentialState? status =
        (await container.auth.status()).valueOrNull;
    if (status == null || !status.hasAnyCredential) {
      return;
    }

    // Bring Smart App Lock to the front (basic challenge presentation;
    // the overlay window lands in the lock-screen phase).
    final shown = await container.overlay.showLockChallenge(packageName);
    if (!mounted || shown.isFailure) {
      return;
    }

    _challenging = true;
    try {
      // Phase 5F: route by the user's PRIMARY credential (the one they
      // enrolled last), not a hardcoded PIN preference. Both PIN and
      // pattern are first-class gates in the protected-app flow.
      final AuthType? primary = status.primary;
      final String route;
      if (primary == AuthType.pattern &&
          status.hasEnrolled(AuthType.pattern)) {
        route = RouteNames.patternUnlock;
      } else if (primary == AuthType.pin &&
          status.hasEnrolled(AuthType.pin)) {
        route = RouteNames.pinUnlock;
      } else if (status.hasEnrolled(AuthType.pin)) {
        route = RouteNames.pinUnlock; // legacy/absent primary: PIN first
      } else {
        route = RouteNames.patternUnlock; // pattern-only user
      }
      final bool? unlocked =
          await widget.navigatorKey.currentState?.pushNamed<bool>(route);
      // Phase 5I: the unlock session is granted ONLY on an explicit
      // authentication success. The unlock screens pop `true` exclusively
      // from their `AuthSuccess` branches (wrong credential, lockout,
      // cancellation and service failures all resolve false/null) — and
      // the host re-checks `mounted` after the await so a torn-down tree
      // can never grant.
      if (unlocked == true) {
        if (!mounted) {
          return;
        }
        // Phase 5E/5F: the credential passed — open the session,
        // dismiss the challenge, then LAUNCH the protected app so the
        // user proceeds straight into it.
        await container.accessController.grantAccess(packageName);
        await container.overlay.hideLockChallenge();
        await container.installedAppsService.launchApp(packageName);
      }
    } finally {
      _challenging = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
