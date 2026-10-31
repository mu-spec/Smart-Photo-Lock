import 'package:flutter/material.dart';

import 'app_container.dart';
import 'app_scope.dart';
import 'capability_watch_guard.dart';
import 'lock_challenge_host.dart';
import 'router.dart';
import 'theme/app_theme.dart';

/// Root widget: owns global theme, navigation, and the dependency container
/// for Smart App Lock.
///
/// Follows the system light/dark setting via [ThemeMode.system]; both
/// foundations come from the design system. When [container] is provided it
/// is published to the tree through [AppScope] so screens can resolve
/// repositories and the credential manager, and the Phase 5D
/// [LockChallengeHost] presents the unlock challenge whenever a protected
/// app becomes active.
class SmartAppLockApp extends StatefulWidget {
  const SmartAppLockApp({super.key, this.container});

  /// Persistence wiring created in `main()` (null in pure widget tests).
  final AppContainer? container;

  @override
  State<SmartAppLockApp> createState() => _SmartAppLockAppState();
}

class _SmartAppLockAppState extends State<SmartAppLockApp> {
  /// The app navigator — the lock host pushes unlock routes through it.
  /// Held on the State so the key identity survives rebuilds.
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// Phase 6 / M1: consumes platform route pushes (see [ExternalRouteGuard]).
  final ExternalRouteGuard _externalRouteGuard = ExternalRouteGuard();

  @override
  void initState() {
    super.initState();
    // Registered here, before MaterialApp's WidgetsApp registers its own
    // observer (a parent's initState runs before its children mount), so
    // the guard sees every platform route push first.
    WidgetsBinding.instance.addObserver(_externalRouteGuard);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_externalRouteGuard);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget app = MaterialApp(
      title: 'Smart App Lock',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      initialRoute: RouteNames.home,
      onGenerateRoute: AppRouter.onGenerateRoute,
      // Phase 6 / M1: a platform-supplied initial route is ignored.
      onGenerateInitialRoutes: AppRouter.onGenerateInitialRoutes,
    );

    final AppContainer? container = widget.container;
    final Widget wrapped = container == null
        ? app
        : AppScope(
            container: container,
            child: CapabilityWatchGuard(
              child: LockChallengeHost(
                navigatorKey: _navigatorKey,
                child: app,
              ),
            ),
          );
    return wrapped;
  }
}

/// Phase 6 / Milestone 1 (Alternate Entry Paths) — defense in depth for
/// Smart App Lock's own exported launcher Activity.
///
/// Any app, launcher shortcut or `am start` can send `MainActivity` an
/// explicit intent with arbitrary data. With Flutter deep linking enabled
/// (the embedding default) the intent data arrives here as a
/// `pushRoute` / `pushRouteInformation` navigation message, and
/// `WidgetsApp` would `pushNamed` it — for example a setup or diagnostics
/// screen above an active lock challenge. `MainActivity` disables deep
/// linking natively; this observer is the Dart-side backstop.
///
/// Every platform route push is reported as handled and ignored. Nothing
/// in this app uses platform route pushes: lock challenges are presented
/// only by `LockChallengeHost` from the native pending ticket, and screens
/// navigate in-process with `Navigator`. Back (`popRoute`) is unaffected.
class ExternalRouteGuard with WidgetsBindingObserver {
  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) =>
      Future<bool>.value(true);
}
