import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/capability_watch_guard.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
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

  testWidgets('guard disposal stops the periodic monitor timer',
      (WidgetTester tester) async {
    useTallViewport(tester);
    final AppContainer container = AppContainer.inMemory();

    await tester.pumpWidget(
      AppScope(
        container: container,
        child: const CapabilityWatchGuard(child: SizedBox()),
      ),
    );
    await tester.pump();

    // Removing the guard must stop the periodic monitor timer it
    // started — the framework's pending-timer check at teardown
    // verifies that no timer survives the widget disposal.
    await tester.pumpWidget(const SizedBox());
  });

  /// The user returns from the Android settings screen: the resume
  /// observer on the Security tab re-checks the LIVE capability state.
  Future<void> resumeFromSettings(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  }

  testWidgets(
      'restoring ALL revoked capabilities clears the warning without a '
      'restart', (WidgetTester tester) async {
    useTallViewport(tester);
    final AppContainer container = AppContainer.inMemory(
      usageAccessGranted: true,
      accessibilityEnabled: true,
      overlayGranted: true,
    );
    await tester.pumpWidget(SmartAppLockApp(container: container));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav_security')));
    await tester.pumpAndSettle();
    expect(find.text(SecurityScreen.revokedTitle), findsNothing);

    // All three revoked in the system settings.
    (container.installedAppsService as StaticInstalledAppsService)
        .usageAccessGranted = false;
    (container.accessibility as StaticAccessibilityLockService).enabled =
        false;
    (container.overlay as StaticOverlayLockService).overlayGranted = false;
    await container.capabilityMonitor.probe();
    await tester.pumpAndSettle();
    expect(find.text(SecurityScreen.revokedTitle), findsOneWidget);

    // The user restores ALL three and returns to the app.
    (container.installedAppsService as StaticInstalledAppsService)
        .usageAccessGranted = true;
    (container.accessibility as StaticAccessibilityLockService).enabled =
        true;
    (container.overlay as StaticOverlayLockService).overlayGranted = true;
    await resumeFromSettings(tester);

    expect(find.text(SecurityScreen.revokedTitle), findsNothing);

    // And a NEW revocation after recovery is detected again.
    (container.installedAppsService as StaticInstalledAppsService)
        .usageAccessGranted = false;
    await container.capabilityMonitor.probe();
    await tester.pumpAndSettle();
    expect(find.text(SecurityScreen.revokedTitle), findsOneWidget);

    await container.capabilityMonitor.dispose();
  });

  testWidgets(
      'restoring only ONE revoked capability keeps the warning until all '
      'are healthy', (WidgetTester tester) async {
    useTallViewport(tester);
    final AppContainer container = AppContainer.inMemory(
      usageAccessGranted: true,
      accessibilityEnabled: true,
      overlayGranted: true,
    );
    await tester.pumpWidget(SmartAppLockApp(container: container));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav_security')));
    await tester.pumpAndSettle();

    // Revoke usage access AND overlay.
    (container.installedAppsService as StaticInstalledAppsService)
        .usageAccessGranted = false;
    (container.overlay as StaticOverlayLockService).overlayGranted = false;
    await container.capabilityMonitor.probe();
    await tester.pumpAndSettle();
    expect(find.text(SecurityScreen.revokedTitle), findsOneWidget);

    // Restore ONLY usage access: the warning MUST remain.
    (container.installedAppsService as StaticInstalledAppsService)
        .usageAccessGranted = true;
    await resumeFromSettings(tester);
    expect(find.text(SecurityScreen.revokedTitle), findsOneWidget);

    // Restore overlay too: now everything is healthy -> clears.
    (container.overlay as StaticOverlayLockService).overlayGranted = true;
    await resumeFromSettings(tester);
    expect(find.text(SecurityScreen.revokedTitle), findsNothing);

    await container.capabilityMonitor.dispose();
  });
}
