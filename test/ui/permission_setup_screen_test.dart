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

  testWidgets('disabled capabilities show alternatives and required shield',
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
    expect(find.text('Background lock shield'), findsOneWidget);
    expect(find.text('Protection notification'), findsOneWidget);

    expect(pillInRow('perm_row_usage', 'Alternative'), findsOneWidget);
    expect(
      pillInRow('perm_row_accessibility', 'Alternative'),
      findsOneWidget,
    );
    expect(pillInRow('perm_row_overlay', 'Required'), findsOneWidget);
    expect(find.text(PermissionSetupScreen.coreMissingLabel), findsOneWidget);
  });

  testWidgets('all capabilities enabled satisfies core requirements',
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
    expect(pillInRow('perm_row_notification', 'Enabled'), findsOneWidget);
    expect(find.text(PermissionSetupScreen.coreReadyLabel), findsOneWidget);
  });

  testWidgets('one detector without the shield is still incomplete',
      (WidgetTester tester) async {
    await pumpScreen(
      tester,
      container: AppContainer.inMemory(
        usageAccessGranted: true,
        accessibilityEnabled: false,
        overlayGranted: false,
      ),
    );

    expect(find.text(PermissionSetupScreen.coreMissingLabel), findsOneWidget);
    expect(pillInRow('perm_row_usage', 'Enabled'), findsOneWidget);
    expect(
      pillInRow('perm_row_accessibility', 'Alternative'),
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
    expect(find.text(PermissionSetupScreen.coreMissingLabel), findsOneWidget);

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

    expect(find.text(PermissionSetupScreen.coreReadyLabel), findsOneWidget);
    expect(pillInRow('perm_row_overlay', 'Enabled'), findsOneWidget);
  });

  testWidgets('missing container shows unavailable core setup without crashing',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const PermissionSetupScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(PermissionSetupScreen.coreMissingLabel), findsOneWidget);
    expect(find.text('Alternative'), findsNWidgets(2));
    expect(find.text('Required'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
