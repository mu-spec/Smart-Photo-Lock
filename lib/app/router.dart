import 'package:flutter/material.dart';

import '../ui/screens/home/home_screen.dart';

/// Central route registry.
///
/// Only the home route is registered in Phase 1B. Later phases append their
/// screens here (see the reserved names below) so that all navigation lives
/// in exactly one place.
abstract final class RouteNames {
  static const String home = '/';

  // Reserved for later phases — uncomment as the screens land:
  // static const String onboarding  = '/onboarding';
  // static const String pinSetup    = '/pin/setup';
  // static const String pinVerify   = '/pin/verify';
  // static const String appList     = '/apps';
  // static const String profiles    = '/profiles';
  // static const String lockScreen  = '/lock'; // full-screen PIN challenge
}

/// Route name -> screen builder map consumed by `MaterialApp.routes`.
abstract final class AppRouter {
  static final Map<String, WidgetBuilder> routes = <String, WidgetBuilder>{
    RouteNames.home: (BuildContext context) => const HomeScreen(),
  };
}
