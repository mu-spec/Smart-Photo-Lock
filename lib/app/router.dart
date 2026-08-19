import 'package:flutter/material.dart';

import '../ui/shell/main_shell.dart';

/// Central route registry.
///
/// The root route hosts the [MainShell] with its five top-level tabs.
/// Later phases append full-screen routes here (see the reserved names below)
/// so that all navigation lives in exactly one place.
abstract final class RouteNames {
  static const String home = '/';

  // Reserved for later phases — uncomment as the screens land:
  // static const String onboarding  = '/onboarding';
  // static const String pinSetup    = '/pin/setup';
  // static const String pinVerify   = '/pin/verify';
  // static const String lockScreen  = '/lock'; // full-screen PIN challenge
}

/// Route name -> screen builder map consumed by `MaterialApp.routes`.
abstract final class AppRouter {
  static final Map<String, WidgetBuilder> routes = <String, WidgetBuilder>{
    RouteNames.home: (BuildContext context) => const MainShell(),
  };
}
