import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/ui/screens/diagnostics/detection_diagnostics_screen.dart';

/// Phase 5B: the developer diagnostics screen verifies foreground
/// detection — usage-stats transitions, accessibility events, the
/// transition log, counter readouts and the start/stop contract.
void main() {
  Future<AppContainer> pumpScreen(
    WidgetTester tester, {
    AppContainer? container,
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final AppContainer c = container ?? AppContainer.inMemory();
    await tester.pumpWidget(
      AppScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const DetectionDiagnosticsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets('usage-stats detections appear as the current package and '
      'log entries', (WidgetTester tester) async {
    final AppContainer container = await pumpScreen(tester);
    final StaticInstalledAppsService apps =
        container.installedAppsService as StaticInstalledAppsService;

    expect(find.text(DetectionDiagnosticsScreen.unknownPackage),
        findsOneWidget);

    apps.foregroundPackage = 'com.whatsapp';
    await container.foregroundMonitor.probe();
    await tester.pumpAndSettle();
    expect(find.text('com.whatsapp'), findsNWidgets(2)); // current + log

    apps.foregroundPackage = 'com.google.android.apps.maps';
    await container.foregroundMonitor.probe();
    await tester.pumpAndSettle();
    expect(find.text('com.google.android.apps.maps'), findsNWidgets(2));
  });

  testWidgets('accessibility events appear in the log with the a11y pill',
      (WidgetTester tester) async {
    final AppContainer container = await pumpScreen(tester);
    final StaticAccessibilityLockService accessibility =
        container.accessibility as StaticAccessibilityLockService;

    accessibility.emitForegroundPackage('com.android.chrome');
    await tester.pumpAndSettle();

    expect(find.text('com.android.chrome'), findsNWidgets(2));
    expect(find.text('a11y'), findsWidgets);
  });

  testWidgets('many apps accumulate newest-first and Clear empties the log',
      (WidgetTester tester) async {
    final AppContainer container = await pumpScreen(tester);
    final StaticInstalledAppsService apps =
        container.installedAppsService as StaticInstalledAppsService;

    for (final String package in <String>[
      'com.app.one',
      'com.app.two',
      'com.app.three',
    ]) {
      apps.foregroundPackage = package;
      await container.foregroundMonitor.probe();
      await tester.pumpAndSettle();
    }

    expect(find.text('Transition log (3)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('diag_clear')));
    await tester.pumpAndSettle();
    expect(find.text('No transitions yet — go open some apps.'),
        findsOneWidget);
    expect(find.text('com.app.one'), findsNothing);
  });

  testWidgets('Stop/Start toggles detection and the status pill',
      (WidgetTester tester) async {
    final AppContainer container = await pumpScreen(tester);
    expect(find.text(DetectionDiagnosticsScreen.runningLabel),
        findsOneWidget);

    await tester.tap(find.byKey(const Key('diag_toggle')));
    await tester.pumpAndSettle();
    expect(find.text(DetectionDiagnosticsScreen.stoppedLabel),
        findsOneWidget);
    expect(container.foregroundMonitor.isRunning, isFalse);

    await tester.tap(find.byKey(const Key('diag_toggle')));
    await tester.pumpAndSettle();
    expect(find.text(DetectionDiagnosticsScreen.runningLabel),
        findsOneWidget);
    expect(container.foregroundMonitor.isRunning, isTrue);
  });

  testWidgets('counter rows reflect the monitor diagnostics',
      (WidgetTester tester) async {
    final AppContainer container = await pumpScreen(tester);
    final StaticInstalledAppsService apps =
        container.installedAppsService as StaticInstalledAppsService;

    // The screen auto-started the monitor: one baseline probe, null
    // (no package set) -> one null probe.
    expect(container.foregroundMonitor.probeCount, 1);
    expect(container.foregroundMonitor.nullProbeCount, 1);

    apps.foregroundPackage = 'com.whatsapp';
    await container.foregroundMonitor.probe();
    await tester.pumpAndSettle();

    expect(find.text('Usage-stats probes'), findsOneWidget);
    expect(find.text('Null probes (no usage access?)'), findsOneWidget);
    expect(find.text('Accessibility events'), findsOneWidget);
    expect(find.text('Failures (fail-quiet)'), findsOneWidget);
    expect(container.foregroundMonitor.probeCount, 2);
    expect(container.foregroundMonitor.nullProbeCount, 1);
  });

  testWidgets('without a container the screen degrades gracefully',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const DetectionDiagnosticsScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(DetectionDiagnosticsScreen.noContainerMessage),
        findsOneWidget);
  });
}
