import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/ui/screens/security/security_screen.dart';

/// Phase 4F: a revoked capability is detected and surfaced on the
/// Security tab.
void main() {
  /// The Security tab is a lazy ListView: at the default 800x600 test
  /// viewport the App lock permissions section (with its DsDotBadge) is
  /// never mounted. Tests that assert on those rows need the tall
  /// surface used across the security suites.
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets(
      'revoking a granted capability shows the alert banner and badge',
      (WidgetTester tester) async {
    useTallViewport(tester);
    final AppContainer container = AppContainer.inMemory(
      usageAccessGranted: true,
      accessibilityEnabled: true,
      overlayGranted: true,
    );
    await tester.pumpWidget(SmartAppLockApp(container: container));
    await tester.pumpAndSettle();

    // Navigate to the Security tab for the alert assertions.
    await tester.tap(find.byKey(const Key('nav_security')));
    await tester.pumpAndSettle();
    expect(find.text(SecurityScreen.revokedTitle), findsNothing);

    // The user revokes usage access in the system settings; the shared
    // services report it on the next probe.
    final StaticInstalledAppsService appsService = container
        .installedAppsService as StaticInstalledAppsService;
    appsService.usageAccessGranted = false;
    await container.capabilityMonitor.probe();
    await tester.pumpAndSettle();

    expect(find.text(SecurityScreen.revokedTitle), findsOneWidget);
    expect(find.text(SecurityScreen.revokedMessage), findsOneWidget);
    expect(find.text('Review permissions'), findsOneWidget);

    // The permissions section header shows the attention dot.
    expect(find.byType(DsDotBadge), findsWidgets);

    // Tear down the monitor so the timer does not leak.
    await container.capabilityMonitor.dispose();
  });

  testWidgets('the guard starts the monitor and probes on resume',
      (WidgetTester tester) async {
    useTallViewport(tester);
    final AppContainer container = AppContainer.inMemory(
      usageAccessGranted: true,
      accessibilityEnabled: true,
      overlayGranted: true,
    );
    await tester.pumpWidget(SmartAppLockApp(container: container));
    await tester.pumpAndSettle();

    // Revoke overlay; the resume probe must detect it.
    final StaticOverlayLockService overlay =
        container.overlay as StaticOverlayLockService;
    overlay.overlayGranted = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('nav_security')));
    await tester.pumpAndSettle();
    expect(find.text(SecurityScreen.revokedTitle), findsOneWidget);

    await container.capabilityMonitor.dispose();
  });
}
