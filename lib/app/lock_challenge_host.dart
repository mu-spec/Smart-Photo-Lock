import 'dart:async';

import 'package:flutter/material.dart';

import '../protection/access_controller.dart';
import '../protection/lock_trigger.dart';
import '../security/credentials/auth_type.dart';
import '../security/credentials/credential_state.dart';
import '../utilities/result.dart';
import 'app_container.dart';
import 'app_scope.dart';
import 'router.dart';

/// Phase 5D/5E/5F/5K/5M/5N: presents the lock challenge when a protected
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
/// Phase 5M (Home-button hardening): leaving the foreground with a
/// challenge up dismisses it safely, and requirements are re-queued —
/// never dropped.
///
/// Phase 5N (Back-navigation hardening): dismissing a challenge with
/// Back while the app is foreground RE-PRESENTS it immediately — Back
/// can never walk past the challenge into the app's own UI.
///
/// Fail-safe: when NO credential is enrolled there is nothing to
/// challenge with — the trigger requirement is ignored (setup lives on
/// the Security tab). Re-entrant requirements while a challenge is
/// already showing are re-queued, never dropped.
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

  /// Phase 5Q: claims the presentation slot SYNCHRONOUSLY, before any
  /// await. Without this, two rapid requirements would both pass the
  /// `_challenging` check (it is only set after several awaits) and
  /// stack two challenge screens on top of each other.
  bool _presenting = false;

  /// Phase 5M: a lock requirement that arrived while a challenge was
  /// already showing — re-presented once the current challenge closes
  /// (never silently dropped).
  String? _pendingPackage;

  /// Phase 5M: true when the user left the app (Home button / recents)
  /// while a challenge was up — the on-screen challenge is dismissed
  /// and the resume path re-evaluates the foreground.
  bool _interruptedChallenge = false;

  /// Phase 5N: the package the current (or most recent) challenge was
  /// presented for — used to re-present it when Back tries to dismiss
  /// the challenge in the foreground.
  String? _lastPresentedPackage;

  /// Phase 5M: whether the app is currently in the foreground (drives
  /// the pending re-presentation; tracked explicitly so tests and
  /// platform lifecycle quirks behave deterministically).
  bool _appForeground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _trigger = AppScope.read(context)?.lockTrigger;
    _subscription = _trigger?.lockRequired.listen(_onLockRequired);
    _trigger?.start();
    _applyPersistedGracePeriod();
  }

  /// Phase 5L: applies the persisted re-lock grace on startup, so the
  /// configured policy is live without visiting any settings screen.
  Future<void> _applyPersistedGracePeriod() async {
    final AppContainer? container = AppScope.read(context);
    if (container == null) {
      return;
    }
    final Result<Duration> result = await container.lockSettings.getGracePeriod();
    if (!mounted || result.isFailure) {
      return;
    }
    container.accessController.setGracePeriod(result.valueOrNull ?? Duration.zero);
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

  /// Phase 5K/5M/5P lifecycle:
  ///  * `inactive` is TRANSIENT on modern Android — the home-swipe
  ///    gesture, the notification shade, permission dialogs and the
  ///    predictive-back peek all fire it WITHOUT the app actually
  ///    leaving. Dismissing the challenge here would flicker it away
  ///    on every cancelled gesture, so `inactive` only flips the
  ///    foreground flag (queued re-presentations wait);
  ///  * `paused`/`hidden` is a REAL leave (Home press completed, task
  ///    covered by another) — the challenge is dismissed here, exactly
  ///    once (idempotent), and re-challenged on resume (5M);
  ///  * `resumed` re-evaluates the foreground after a screen-off (5K)
  ///    or an interrupted challenge (5M) — a cancelled gesture returns
  ///    to `resumed` with the challenge untouched.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _appForeground = true;
      _onResumed();
      return;
    }
    if (state == AppLifecycleState.inactive) {
      // Transient: cancelled gestures, shade pulls, dialogs, split
      // screen — the challenge stays exactly where it is.
      _appForeground = false;
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _appForeground = false;
      _onLeftForeground();
    }
  }

  /// Phase 5M/5N/5P: Home-press handling — dismiss the on-screen
  /// challenge. Only called on a REAL leave (`paused`/`hidden`); the
  /// transient `inactive` never reaches here, so a cancelled
  /// home-swipe or a shade pull never dismisses anything.
  void _onLeftForeground() {
    // Idempotent: a second lifecycle event must not double-pop (the
    // second pop would remove the SHELL route beneath the challenge).
    if (!_challenging || _interruptedChallenge) {
      return;
    }
    _interruptedChallenge = true;
    // Pop the challenge route: its awaited future completes with null
    // (Phase 5I: null never grants a session), which clears
    // `_challenging` through the finally block below. canPop guards
    // the shell from being popped when nothing sits above it.
    final NavigatorState? navigator = widget.navigatorKey.currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
    }
  }

  Future<void> _onResumed() async {
    final LockTrigger? trigger = _trigger;
    if (trigger == null || !mounted) {
      return;
    }
    final bool screenOff = trigger.takeScreenOffPending();
    if (_challenging) {
      // Phase 5T (process/activity recreation): window flags do NOT
      // survive an activity recreation — re-arm FLAG_SECURE whenever a
      // challenge is on screen, so the recents snapshot is protected
      // again even when the platform rebuilt the window under us.
      final AppContainer? container = AppScope.read(context);
      if (container != null) {
        await container.overlay.setSecureWindow(true);
      }
      return;
    }
    // Re-lock enforcement only after a screen-off (5K) or an
    // interrupted challenge (5M) — a plain resume must not re-challenge
    // a still-valid session.
    if (!screenOff && !_interruptedChallenge) {
      return;
    }
    _interruptedChallenge = false;
    await _reevaluateAndChallenge();
  }

  Future<void> _onLockRequired(LockRequired requirement) =>
      _presentChallenge(requirement.packageName);

  Future<void> _presentChallenge(String packageName) async {
    if (_presenting || _challenging || !mounted) {
      // Phase 5M/5Q: never silently drop a requirement — remember the
      // latest one and re-present it when the current challenge closes.
      if (mounted) {
        _pendingPackage = packageName;
      }
      return;
    }
    // Phase 5Q: claim the slot NOW — everything below may await, and
    // concurrent requirements must re-queue instead of double-stacking
    // challenge screens.
    _presenting = true;
    try {
      // A fresh presentation supersedes any stale pending requirement
      // (this call IS the newest requirement, or the re-presentation of
      // the pending one — either way the pending slot must not linger).
      _pendingPackage = null;
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

      // Phase 5O (recents hardening): FLAG_SECURE keeps the recents
      // snapshot blank while the challenge is on screen — the PIN dots,
      // pattern trail or protected-app state never leak through task
      // switching. Failures are tolerated (hardening, not enforcement).
      await container.overlay.setSecureWindow(true);

      _challenging = true;
      // A fresh challenge supersedes the interrupted state (Home-press
      // dismissal) — nothing is pending to re-evaluate anymore.
      _interruptedChallenge = false;
      // Phase 5N: remember what this challenge guards, so a Back-press
      // dismissal can be re-presented instead of exposing the app UI.
      _lastPresentedPackage = packageName;
      bool passed = false;
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
        passed = unlocked == true;
        if (passed) {
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
        _afterChallengeClosed(passed);
      }
    } finally {
      _presenting = false;
    }
  }

  /// Phase 5M/5N/5O: runs whenever a challenge closes (completed,
  /// cancelled, dismissed by a Home press, or popped by Back).
  ///
  ///  * passed            -> a queued requirement for another app
  ///                         re-presents (5M); otherwise the secure
  ///                         window clears;
  ///  * interrupted       -> the Home-press dismissal just completed;
  ///                         foreground re-evaluates, background defers
  ///                         to the resume path (5M);
  ///  * NOT passed, NOT interrupted, foreground:
  ///    **Back-press dismissal** — the challenge RE-PRESENTS
  ///    immediately: Back can never bypass the lock into the app UI.
  void _afterChallengeClosed(bool passed) {
    _challenging = false;
    if (passed) {
      // The lock loop truly ends only when nothing is queued — the
      // queued re-presentation keeps the secure window armed (no
      // flicker window for a recents snapshot to exploit).
      if (_pendingPackage == null) {
        _clearSecure();
      }
      _maybePresentPending();
      return;
    }
    if (_interruptedChallenge && _appForeground && mounted) {
      _interruptedChallenge = false;
      _reevaluateAndChallenge();
      return;
    }
    if (!_appForeground || !mounted) {
      // Home/Recents dismissal (backgrounded): no challenge is visible
      // anymore — the snapshot may show normal content again; the
      // resume path re-arms the secure window with the re-challenge.
      _clearSecure();
      _maybePresentPending();
      return;
    }
    // Phase 5N: Back-press dismissal while foreground — re-present.
    // The secure window STAYS armed: the challenge reappears next
    // frame (no flicker window for a recents snapshot to exploit).
    _scheduleReChallenge();
  }

  /// Phase 5O: clears FLAG_SECURE (the lock loop ended). Failures are
  /// tolerated — hardening, not enforcement.
  Future<void> _clearSecure() async {
    final AppContainer? container = AppScope.read(context);
    if (container == null) {
      return;
    }
    await container.overlay.setSecureWindow(false);
  }

  /// Phase 5N: re-presents the dismissed challenge on the next frame
  /// (the latest requirement wins over the interrupted package).
  void _scheduleReChallenge() {
    final String? target = _pendingPackage ?? _lastPresentedPackage;
    if (target == null) {
      return;
    }
    _pendingPackage = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_presenting && !_challenging && _pendingPackage == null) {
        _presentIfRequired(target);
      }
    });
  }

  /// Phase 5Q: re-evaluates [packageName] before presenting — rapid
  /// switching can make a queued requirement stale (a grant that landed
  /// between the requirement and its re-presentation must NOT produce a
  /// double challenge). Presents only when the decision still demands
  /// it; the fresh evaluation is a real re-entry decision.
  Future<void> _presentIfRequired(String packageName) async {
    final AppContainer? container = AppScope.read(context);
    if (container == null || !mounted) {
      return;
    }
    final AccessDecision decision =
        await container.accessController.evaluate(packageName);
    if (!mounted) {
      return;
    }
    if (decision == AccessDecision.challenge ||
        decision == AccessDecision.deny) {
      await _presentChallenge(packageName);
      return;
    }
    // The lock loop truly ended (a grant landed while the requirement
    // was queued) — make sure the secure window does not linger armed.
    _clearSecure();
  }

  /// Phase 5M: re-probes detection and challenges the current
  /// foreground when the access decision demands it (shared by the
  /// resume path and the interrupted-challenge path).
  Future<void> _reevaluateAndChallenge() async {
    final LockTrigger? trigger = _trigger;
    final AppContainer? container = AppScope.read(context);
    if (trigger == null || container == null || !mounted) {
      return;
    }
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

  /// Phase 5M: after a challenge closes, re-present a requirement that
  /// arrived while it was showing — but only when the app is actually
  /// in the foreground (a Home-press during the challenge leaves the
  /// re-presentation to the resume path instead of fighting the user's
  /// Home press).
  void _maybePresentPending() {
    final String? pending = _pendingPackage;
    if (pending == null || !mounted || !_appForeground) {
      return;
    }
    _pendingPackage = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Skip when a NEWER requirement already took over (it either
      // presents directly or fills the pending slot for its own cycle).
      if (mounted && !_presenting && !_challenging && _pendingPackage == null) {
        // Phase 5Q: re-evaluate first — a grant that landed since the
        // requirement queued must not double-challenge.
        _presentIfRequired(pending);
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
