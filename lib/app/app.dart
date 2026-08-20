import 'package:flutter/material.dart';

import 'app_container.dart';
import 'app_scope.dart';
import 'capability_watch_guard.dart';
import 'router.dart';
import 'theme/app_theme.dart';

/// Root widget: owns global theme, navigation, and the dependency container
/// for Smart App Lock.
///
/// Follows the system light/dark setting via [ThemeMode.system]; both
/// foundations come from the design system. When [container] is provided it
/// is published to the tree through [AppScope] so screens can resolve
/// repositories and the credential manager.
class SmartAppLockApp extends StatelessWidget {
  const SmartAppLockApp({super.key, this.container});

  /// Persistence wiring created in `main()` (null in pure widget tests).
  final AppContainer? container;

  @override
  Widget build(BuildContext context) {
    final Widget app = MaterialApp(
      title: 'Smart App Lock',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      initialRoute: RouteNames.home,
      onGenerateRoute: AppRouter.onGenerateRoute,
    );

    final AppContainer? container = this.container;
    final Widget wrapped = container == null
        ? app
        : AppScope(
            container: container,
            child: CapabilityWatchGuard(child: app),
          );
    return wrapped;
  }
}
