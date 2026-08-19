import 'package:flutter/material.dart';

import '../ui/screens/pattern/pattern_setup_screen.dart';
import '../ui/screens/pin/pin_setup_screen.dart';
import '../ui/screens/pin/pin_unlock_screen.dart';
import '../ui/shell/main_shell.dart';

/// Central route registry.
///
/// The root route hosts the [MainShell] with its five top-level tabs.
/// Full-screen flows (PIN setup now, more later) are pushed as named routes
/// on top of the shell so all navigation lives in exactly one place.
abstract final class RouteNames {
  static const String home = '/';

  /// Initial PIN setup (Phase 2B) — also reused by the change-PIN flow.
  static const String pinSetup = '/pin/setup';

  /// Full-screen PIN authentication (Phase 2E). Pops `true` on success.
  static const String pinUnlock = '/pin/unlock';

  /// Pattern creation + confirmation (Phase 2H).
  static const String patternSetup = '/pattern/setup';

  // Reserved for later phases — uncomment as the screens land:
  // static const String onboarding  = '/onboarding';
  // static const String lockScreen  = '/lock'; // overlay PIN challenge
}

/// Route name -> screen builder map consumed by `MaterialApp.routes`.
abstract final class AppRouter {
  static final Map<String, WidgetBuilder> routes = <String, WidgetBuilder>{
    RouteNames.home: (BuildContext context) => const MainShell(),
    RouteNames.pinSetup: (BuildContext context) => const PinSetupScreen(),
    RouteNames.pinUnlock: (BuildContext context) => const PinUnlockScreen(),
    RouteNames.patternSetup: (BuildContext context) =>
        const PatternSetupScreen(),
  };
}
