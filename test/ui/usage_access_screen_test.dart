import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/ui/screens/permissions/usage_access_screen.dart';

/// Phase 4B: the usage-access setup flow — detect status, explain
/// purpose, send the user to the system settings, and detect the
/// successful return.
void main() {
  Future<StaticInstalledAppsService> pumpScreen(
    WidgetTester tester, {
    bool usageAccessGranted = false,
  }) async {
    final StaticInstalledAppsService service = StaticInstalledAppsService(
      const <AppEntry>[],
      usageAccessGranted: usageAccessGranted,
    );
    final AppContainer container =
        AppContainer.inMemory(usageAccessGranted: usageAccessGranted);
    await tester.pumpWidget(
      AppScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: UsageAccessScreen(service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return service;
  }

  testWidgets('not granted: explains the purpose and offers settings',
      (WidgetTester tester) async {
    await pumpScreen(tester, usageAccessGranted: false);

    expect(find.text(UsageAccessScreen.notGrantedTitle), findsOneWidget);
    expect(find.text(UsageAccessScreen.notGrantedMessage), findsOneWidget);
    expect(find.text(UsageAccessScreen.openSettingsLabel), findsOneWidget);
    expect(find.text(UsageAccessScreen.settingsNote), findsOneWidget);
  });

  testWidgets('Open Settings fires the system-settings request',
      (WidgetTester tester) async {
    final StaticInstalledAppsService service =
        await pumpScreen(tester, usageAccessGranted: false);

    await tester.tap(find.byKey(const Key('usage_access_open_settings')));
    await tester.pumpAndSettle();

    expect(service.requestUsageAccessCalls, 1);
    // Still not granted -> the explanation view remains (the system
    // screen is open externally).
    expect(find.text(UsageAccessScreen.notGrantedTitle), findsOneWidget);
  });

  testWidgets('a successful return is detected: resume re-checks and shows granted',
      (WidgetTester tester) async {
    final StaticInstalledAppsService service =
        await pumpScreen(tester, usageAccessGranted: false);

    // The user enabled it in the system settings (simulated), then
    // returned to the app.
    service.usageAccessGranted = true;
    tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text(UsageAccessScreen.grantedTitle), findsOneWidget);
    expect(find.text(UsageAccessScreen.grantedMessage), findsOneWidget);
    expect(find.text(UsageAccessScreen.doneLabel), findsOneWidget);
  });

  testWidgets('already granted shows the granted state immediately',
      (WidgetTester tester) async {
    await pumpScreen(tester, usageAccessGranted: true);

    expect(find.text(UsageAccessScreen.grantedTitle), findsOneWidget);
    expect(find.text(UsageAccessScreen.notGrantedTitle), findsNothing);
  });

  testWidgets('Done pops true', (WidgetTester tester) async {
    final List<Object?> results = <Object?>[];
    final StaticInstalledAppsService service = StaticInstalledAppsService(
      const <AppEntry>[],
      usageAccessGranted: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const Key('open_usage_access'),
                onPressed: () async {
                  final Object? res = await Navigator.of(context)
                      .push<Object?>(MaterialPageRoute<Object?>(
                    builder: (_) => UsageAccessScreen(service: service),
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
    await tester.tap(find.byKey(const Key('open_usage_access')));
    await tester.pumpAndSettle();

    await tester.tap(find.text(UsageAccessScreen.doneLabel));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('open_usage_access')), findsOneWidget);
    expect(results.last, true);
  });

  testWidgets('capability probe failures show the retry state',
      (WidgetTester tester) async {
    // No container in scope -> the service resolution fails and the
    // screen reports unavailable instead of crashing.
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const UsageAccessScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(UsageAccessScreen.unavailableTitle), findsOneWidget);
    expect(find.text(UsageAccessScreen.retryLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
