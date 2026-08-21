import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/ui/screens/permissions/accessibility_setup_screen.dart';

/// Phase 4C: the accessibility setup flow — prominent disclosure, exact
/// purpose, system settings routing, and successful-return detection.
void main() {
  Future<StaticAccessibilityLockService> pumpScreen(
    WidgetTester tester, {
    bool enabled = false,
  }) async {
    final StaticAccessibilityLockService service =
        StaticAccessibilityLockService(enabled: enabled);
    final AppContainer container =
        AppContainer.inMemory(accessibilityEnabled: enabled);
    await tester.pumpWidget(
      AppScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: AccessibilitySetupScreen(service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return service;
  }

  testWidgets('not enabled: shows the prominent disclosure with exact purpose',
      (WidgetTester tester) async {
    await pumpScreen(tester, enabled: false);

    expect(find.text(AccessibilitySetupScreen.notEnabledTitle), findsOneWidget);
    expect(find.text(AccessibilitySetupScreen.disclosureTitle), findsOneWidget);
    expect(find.text(AccessibilitySetupScreen.disclosureBody), findsOneWidget);
    expect(find.text(AccessibilitySetupScreen.disclosureNever), findsOneWidget);
    // The prominent "not used for anything else" line.
    expect(find.text(AccessibilitySetupScreen.notUsedElsewhere), findsOneWidget);
  });

  testWidgets('Open Settings fires the system-settings request',
      (WidgetTester tester) async {
    final StaticAccessibilityLockService service =
        await pumpScreen(tester, enabled: false);

    await tester.tap(find.byKey(const Key('accessibility_open_settings')));
    await tester.pumpAndSettle();

    expect(service.requestServiceEnableCalls, 1);
    expect(find.text(AccessibilitySetupScreen.notEnabledTitle), findsOneWidget);
  });

  testWidgets('a successful return is detected: resume re-checks and shows enabled',
      (WidgetTester tester) async {
    final StaticAccessibilityLockService service =
        await pumpScreen(tester, enabled: false);

    service.enabled = true; // enabled in the system settings
    tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text(AccessibilitySetupScreen.enabledTitle), findsOneWidget);
    expect(find.text(AccessibilitySetupScreen.enabledMessage), findsOneWidget);
    expect(find.text(AccessibilitySetupScreen.doneLabel), findsOneWidget);
  });

  testWidgets('already enabled shows the enabled state immediately',
      (WidgetTester tester) async {
    await pumpScreen(tester, enabled: true);

    expect(find.text(AccessibilitySetupScreen.enabledTitle), findsOneWidget);
    expect(find.text(AccessibilitySetupScreen.notEnabledTitle), findsNothing);
    expect(
        find.text(AccessibilitySetupScreen.manageSettingsLabel), findsOneWidget);
  });

  testWidgets('enabled state Manage Settings opens the system settings',
      (WidgetTester tester) async {
    final StaticAccessibilityLockService service =
        await pumpScreen(tester, enabled: true);

    await tester.tap(find.byKey(const Key('accessibility_manage_settings')));
    await tester.pumpAndSettle();

    expect(service.requestServiceEnableCalls, 1);
    // Still enabled afterwards — the action manages, it never disables.
    expect(find.text(AccessibilitySetupScreen.enabledTitle), findsOneWidget);
  });

  testWidgets('Done pops true', (WidgetTester tester) async {
    final List<Object?> results = <Object?>[];
    final StaticAccessibilityLockService service =
        StaticAccessibilityLockService(enabled: true);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const Key('open_accessibility'),
                onPressed: () async {
                  final Object? res = await Navigator.of(context)
                      .push<Object?>(MaterialPageRoute<Object?>(
                    builder: (_) => AccessibilitySetupScreen(service: service),
                  ));
                  results.add(res);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open_accessibility')));
    await tester.pumpAndSettle();

    await tester.tap(find.text(AccessibilitySetupScreen.doneLabel));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('open_accessibility')), findsOneWidget);
    expect(results.last, true);
  });

  testWidgets('capability probe failures show the retry state',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const AccessibilitySetupScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(AccessibilitySetupScreen.unavailableTitle), findsOneWidget);
    expect(find.text(AccessibilitySetupScreen.retryLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
