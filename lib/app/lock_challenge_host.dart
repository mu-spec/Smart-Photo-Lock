import 'dart:async';

import 'package:flutter/material.dart';

import '../protection/access_controller.dart';
import '../protection/lock_trigger.dart';
import '../security/credentials/auth_type.dart';
import '../security/credentials/credential_state.dart';
import 'app_scope.dart';
import 'router.dart';

/// Phase 5D: presents the lock challenge when a protected application
/// becomes active.
///
/// Owns the production lifecycle of the lock trigger:
///  * starts the trigger (monitor + evaluation pipeline) on mount,
///    stops it on unmount;
///  * on a [LockRequired] event: brings Smart App Lock to the front
///    through the overlay bridge (`showLockChallenge`), then pushes the
///    unlock screen matching the user's enrolled credential (PIN
///    preferred, pattern as fallback);
///  * a correct unlock grants the package an unlock window
///    ([AccessController.grantAccess]) so it does not immediately
///    re-lock.
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

class _LockChallengeHostState extends State<LockChallengeHost> {
  LockTrigger? _trigger;
  StreamSubscription<LockRequired>? _subscription;

  /// True while an unlock challenge is on screen (blocks re-entrancy).
  bool _challenging = false;

  @override
  void initState() {
    super.initState();
    _trigger = AppScope.read(context)?.lockTrigger;
    _subscription = _trigger?.lockRequired.listen(_onLockRequired);
    _trigger?.start();
  }

  @override
  void dispose() {
    // Stop exactly what this host started: the subscription and the
    // trigger (which stops the monitor's polling timer).
    _subscription?.cancel();
    _trigger?.stop();
    super.dispose();
  }

  Future<void> _onLockRequired(LockRequired requirement) async {
    if (_challenging || !mounted) {
      return;
    }
    final container = AppScope.read(context);
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
    final shown = await container.overlay.showLockChallenge(
      requirement.packageName,
    );
    if (!mounted || shown.isFailure) {
      return;
    }

    _challenging = true;
    try {
      final String route = status.hasEnrolled(AuthType.pin)
          ? RouteNames.pinUnlock
          : RouteNames.patternUnlock;
      final bool? unlocked =
          await widget.navigatorKey.currentState?.pushNamed<bool>(route);
      if (unlocked == true) {
        await container.accessController.grantAccess(requirement.packageName);
        await container.overlay.hideLockChallenge();
      }
    } finally {
      _challenging = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
