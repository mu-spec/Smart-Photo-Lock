import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/ui/screens/permissions/overlay_setup_screen.dart';

/// Phase 4D: the overlay setup flow — prominent disclosure, exact
/// purpose, system settings routing, and successful-return detection.
void main() {
  Future<StaticOverlayLockService> pumpScreen(
    WidgetTester tester, {
    bool granted = false,
  }) async {
    final StaticOverlayLockService service =
        StaticOverlayLockService(overlayGranted: granted);
    final AppContainer container =
        AppContainer.inMemory(overlayGranted: granted);
    await tester.pumpWidget(
      AppScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: OverlaySetupScreen(service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return service;
  }

  testWidgets('not granted: shows the prominent disclosure with exact purpose',
      (WidgetTester tester) async {
    await pumpScreen(tester, granted: false);

    expect(find.text(OverlaySetupScreen.notGrantedTitle), findsOneWidget);
    expect(find.text(OverlaySetupScreen.disclosureTitle), findsOneWidget);
    expect(find.text(OverlaySetupScreen.disclosureBody), findsOneWidget);
    expect(find.text(OverlaySetupScreen.disclosureNever), findsOneWidget);
    expect(find.text(OverlaySetupScreen.notUsedElsewhere), findsOneWidget);
  });

  testWidgets('Open Settings fires the system-settings request',
      (WidgetTester tester) async {
    final StaticOverlayLockService service =
        await pumpScreen(tester, granted: false);

    await tester.tap(find.byKey(const Key('overlay_open_settings')));
    await tester.pumpAndSettle();

    expect(service.requestCalls, 1);
    expect(find.text(OverlaySetupScreen.notGrantedTitle), findsOneWidget);
  });

  testWidgets('a successful return is detected: resume re-checks and shows granted',
      (WidgetTester tester) async {
    final StaticOverlayLockService service =
        await pumpScreen(tester, granted: false);

    service.overlayGranted = true; // granted in the system settings
    tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text(OverlaySetupScreen.grantedTitle), findsOneWidget);
    expect(find.text(OverlaySetupScreen.grantedMessage), findsOneWidget);
    expect(find.text(OverlaySetupScreen.doneLabel), findsOneWidget);
  });

  testWidgets('already granted shows the granted state immediately',
      (WidgetTester tester) async {
    await pumpScreen(tester, granted: true);

    expect(find.text(OverlaySetupScreen.grantedTitle), findsOneWidget);
    expect(find.text(OverlaySetupScreen.notGrantedTitle), findsNothing);
  });

  testWidgets('Done pops true', (WidgetTester tester) async {
    final List<Object?> results = <Object?>[];
    final StaticOverlayLockService service =
        StaticOverlayLockService(overlayGranted: true);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const Key('open_overlay'),
                onPressed: () async {
                  final Object? res = await Navigator.of(context)
                      .push<Object?>(MaterialPageRoute<Object?>(
                    builder: (_) => OverlaySetupScreen(service: service),
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
    await tester.tap(find.byKey(const Key('open_overlay')));
    await tester.pumpAndSettle();

    await tester.tap(find.text(OverlaySetupScreen.doneLabel));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('open_overlay')), findsOneWidget);
    expect(results.last, true);
  });

  testWidgets('capability probe failures show the retry state',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const OverlaySetupScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(OverlaySetupScreen.unavailableTitle), findsOneWidget);
    expect(find.text(OverlaySetupScreen.retryLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
