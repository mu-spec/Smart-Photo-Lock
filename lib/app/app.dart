import 'package:flutter/material.dart';

import 'app_container.dart';
import 'router.dart';
import 'theme/app_theme.dart';

/// Root widget: owns global theme, navigation, and the dependency container
/// for Smart App Lock.
///
/// Follows the system light/dark setting via [ThemeMode.system]; both
/// foundations come from the design system. [container] is nullable so
/// widget tests can pump the app without booting platform plugins — feature
/// phases will consume repositories through it.
class SmartAppLockApp extends StatelessWidget {
  const SmartAppLockApp({super.key, this.container});

  /// Persistence wiring created in `main()` (null in pure widget tests).
  final AppContainer? container;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart App Lock',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      initialRoute: RouteNames.home,
      routes: AppRouter.routes,
    );
  }
}
