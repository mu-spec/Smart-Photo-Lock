import 'package:flutter/material.dart';

import 'router.dart';
import 'theme/app_theme.dart';

/// Root widget: owns global theme and navigation for Smart App Lock.
///
/// Follows the system light/dark setting via [ThemeMode.system]; both
/// foundations come from the design system.
class SmartAppLockApp extends StatelessWidget {
  const SmartAppLockApp({super.key});

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
