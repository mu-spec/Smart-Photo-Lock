import 'package:flutter/material.dart';

import 'router.dart';
import 'theme/app_theme.dart';

/// Root widget: owns global theme and navigation for Smart App Lock.
///
/// Every feature screen registers itself in [AppRouter]; this widget stays
/// intentionally thin and only wires theme + routing.
class SmartAppLockApp extends StatelessWidget {
  const SmartAppLockApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart App Lock',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      initialRoute: RouteNames.home,
      routes: AppRouter.routes,
    );
  }
}
