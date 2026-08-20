import 'package:flutter/material.dart';

import '../ui/screens/pattern/pattern_change_screen.dart';
import '../ui/screens/pattern/pattern_setup_screen.dart';
import '../ui/screens/pattern/pattern_unlock_screen.dart';
import '../ui/screens/permissions/accessibility_setup_screen.dart';
import '../ui/screens/permissions/overlay_setup_screen.dart';
import '../ui/screens/permissions/usage_access_screen.dart';
import '../ui/screens/pin/pin_change_screen.dart';
import '../ui/screens/pin/pin_setup_screen.dart';
import '../ui/screens/pin/pin_unlock_screen.dart';
import '../ui/shell/main_shell.dart';

/// Central route registry.
///
/// The root route hosts the [MainShell] with its five top-level tabs.
/// Full-screen flows (PIN/pattern setup, unlock and change) are pushed as
/// named routes on top of the shell so all navigation lives in exactly one
/// place.
abstract final class RouteNames {
  static const String home = '/';

  /// Initial PIN setup (Phase 2B) — also reused by the change-PIN flow.
  static const String pinSetup = '/pin/setup';

  /// Full-screen PIN authentication (Phase 2E). Pops `true` on success.
  static const String pinUnlock = '/pin/unlock';

  /// Pattern creation + confirmation (Phase 2H).
  static const String patternSetup = '/pattern/setup';

  /// Full-screen pattern authentication (Phase 2I). Pops `true` on success.
  static const String patternUnlock = '/pattern/unlock';

  /// Change PIN (Phase 2K): verify current → set new.
  static const String pinChange = '/pin/change';

  /// Change pattern (Phase 2K): verify current → set new.
  static const String patternChange = '/pattern/change';

  /// Usage-access setup (Phase 4B): detect → explain → settings → recheck.
  static const String usageAccess = '/permissions/usage-access';

  /// Accessibility setup (Phase 4C): detect → disclose → settings → recheck.
  static const String accessibilitySetup = '/permissions/accessibility';

  /// Overlay setup (Phase 4D): detect → disclose → settings → recheck.
  static const String overlaySetup = '/permissions/overlay';
}

/// Typed route generator consumed by `MaterialApp.onGenerateRoute`.
///
/// IMPORTANT (real-device fix): [SecurityScreen] pushes the change and
/// unlock flows with `pushNamed<bool>(...)`, which requires the produced
/// route to be a `Route<bool>`. The default `routes:` map always builds
/// `MaterialPageRoute<dynamic>`, which crashes the runtime cast — so every
/// bool-typed route is generated here explicitly.
abstract final class AppRouter {
  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    final String? name = settings.name;
    switch (name) {
      case RouteNames.home:
        return MaterialPageRoute<dynamic>(
          settings: settings,
          builder: (BuildContext context) => const MainShell(),
        );
      case RouteNames.pinSetup:
        return MaterialPageRoute<dynamic>(
          settings: settings,
          builder: (BuildContext context) => const PinSetupScreen(),
        );
      case RouteNames.pinUnlock:
        return MaterialPageRoute<bool>(
          settings: settings,
          builder: (BuildContext context) => const PinUnlockScreen(),
        );
      case RouteNames.patternSetup:
        return MaterialPageRoute<dynamic>(
          settings: settings,
          builder: (BuildContext context) => const PatternSetupScreen(),
        );
      case RouteNames.patternUnlock:
        return MaterialPageRoute<bool>(
          settings: settings,
          builder: (BuildContext context) => const PatternUnlockScreen(),
        );
      case RouteNames.pinChange:
        return MaterialPageRoute<bool>(
          settings: settings,
          builder: (BuildContext context) => const PinChangeScreen(),
        );
      case RouteNames.patternChange:
        return MaterialPageRoute<bool>(
          settings: settings,
          builder: (BuildContext context) => const PatternChangeScreen(),
        );
      case RouteNames.usageAccess:
        return MaterialPageRoute<bool>(
          settings: settings,
          builder: (BuildContext context) => const UsageAccessScreen(),
        );
      case RouteNames.accessibilitySetup:
        return MaterialPageRoute<bool>(
          settings: settings,
          builder: (BuildContext context) =>
              const AccessibilitySetupScreen(),
        );
      case RouteNames.overlaySetup:
        return MaterialPageRoute<bool>(
          settings: settings,
          builder: (BuildContext context) => const OverlaySetupScreen(),
        );
      default:
        return null;
    }
  }
}
