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
