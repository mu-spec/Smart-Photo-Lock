import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/router.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/ui/screens/permissions/accessibility_setup_screen.dart';
import 'package:smart_app_lock/ui/screens/permissions/overlay_setup_screen.dart';
import 'package:smart_app_lock/ui/screens/permissions/permission_setup_screen.dart';
import 'package:smart_app_lock/ui/screens/permissions/usage_access_screen.dart';

/// Phase 4E: the centralized permission setup shows Enabled / Action
/// Required for every required capability and routes into each flow.
void main() {
  Future<void> pumpScreen(
    WidgetTester tester, {
    AppContainer? container,
  }) async {
    final AppContainer c = container ?? AppContainer.inMemory();
    await tester.pumpWidget(
      AppScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.dark,
          onGenerateRoute: (RouteSettings settings) {
            final WidgetBuilder? builder = <String, WidgetBuilder>{
              RouteNames.usageAccess: (_) => const UsageAccessScreen(),
              RouteNames.accessibilitySetup: (_) =>
                  const AccessibilitySetupScreen(),
              RouteNames.overlaySetup: (_) => const OverlaySetupScreen(),
            }[settings.name];
            if (builder == null) {
              return null;
            }
            return MaterialPageRoute<bool>(settings: settings, builder: builder);
          },
          home: const PermissionSetupScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder pillInRow(String rowKey, String label) => find.descendant(
        of: find.byKey(Key(rowKey)),
        matching: find.text(label),
      );

  testWidgets('all capabilities disabled: three Action Required + 0 of 3',
      (WidgetTester tester) async {
    await pumpScreen(
      tester,
      container: AppContainer.inMemory(
        usageAccessGranted: false,
        accessibilityEnabled: false,
        overlayGranted: false,
      ),
    );

    expect(find.text(PermissionSetupScreen.headerTitle), findsOneWidget);
    expect(find.text('Usage access'), findsOneWidget);
    expect(find.text('Accessibility service'), findsOneWidget);
    expect(find.text('Draw over apps'), findsOneWidget);

    expect(pillInRow('perm_row_usage', 'Action Required'), findsOneWidget);
    expect(
      pillInRow('perm_row_accessibility', 'Action Required'),
      findsOneWidget,
    );
    expect(pillInRow('perm_row_overlay', 'Action Required'), findsOneWidget);
    expect(find.text(PermissionSetupScreen.readyCount(0)), findsOneWidget);
  });

  testWidgets('all capabilities enabled: three Enabled + 3 of 3',
      (WidgetTester tester) async {
    await pumpScreen(
      tester,
      container: AppContainer.inMemory(
        usageAccessGranted: true,
        accessibilityEnabled: true,
        overlayGranted: true,
      ),
    );

    expect(pillInRow('perm_row_usage', 'Enabled'), findsOneWidget);
    expect(pillInRow('perm_row_accessibility', 'Enabled'), findsOneWidget);
    expect(pillInRow('perm_row_overlay', 'Enabled'), findsOneWidget);
    expect(find.text(PermissionSetupScreen.readyCount(3)), findsOneWidget);
    expect(find.text('Action Required'), findsNothing);
  });

  testWidgets('mixed state shows the exact ready count', (WidgetTester tester) async {
    await pumpScreen(
      tester,
      container: AppContainer.inMemory(
        usageAccessGranted: true,
        accessibilityEnabled: false,
        overlayGranted: false,
      ),
    );

    expect(find.text(PermissionSetupScreen.readyCount(1)), findsOneWidget);
    expect(pillInRow('perm_row_usage', 'Enabled'), findsOneWidget);
    expect(
      pillInRow('perm_row_accessibility', 'Action Required'),
      findsOneWidget,
    );
  });

  testWidgets('tapping the usage row opens the usage-access flow',
      (WidgetTester tester) async {
    await pumpScreen(
      tester,
      container: AppContainer.inMemory(usageAccessGranted: false),
    );

    await tester.tap(find.byKey(const Key('perm_row_usage')));
    await tester.pumpAndSettle();

    expect(find.text(UsageAccessScreen.notGrantedTitle), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the overlay row opens the overlay flow',
      (WidgetTester tester) async {
    await pumpScreen(
      tester,
      container: AppContainer.inMemory(overlayGranted: false),
    );

    await tester.tap(find.byKey(const Key('perm_row_overlay')));
    await tester.pumpAndSettle();

    expect(find.text(OverlaySetupScreen.notGrantedTitle), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a successful return from a flow re-checks the capability',
      (WidgetTester tester) async {
    final AppContainer granted = AppContainer.inMemory(
      usageAccessGranted: true,
      accessibilityEnabled: true,
      overlayGranted: true,
    );
    await pumpScreen(
      tester,
      container: AppContainer.inMemory(
        usageAccessGranted: false,
        accessibilityEnabled: false,
        overlayGranted: false,
      ),
    );
    expect(find.text(PermissionSetupScreen.readyCount(0)), findsOneWidget);

    // The user enabled everything (simulated by a fresh container with
    // granted flags) and returns to the screen — a resume re-checks.
    await tester.pumpWidget(
      AppScope(
        container: granted,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const PermissionSetupScreen(),
        ),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text(PermissionSetupScreen.readyCount(3)), findsOneWidget);
    expect(pillInRow('perm_row_overlay', 'Enabled'), findsOneWidget);
  });

  testWidgets('missing container degrades to Action Required without crashing',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const PermissionSetupScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(PermissionSetupScreen.readyCount(0)), findsOneWidget);
    expect(find.text('Action Required'), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });
}
