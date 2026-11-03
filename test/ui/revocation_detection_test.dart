import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/capability_watch_guard.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/ui/screens/health/health_presentation.dart';
import 'package:smart_app_lock/ui/screens/security/security_center_section.dart';

/// Phase 4F: a revoked capability is detected and surfaced on the
/// Security tab.
///
/// Phase 9 / M1 (intentionally updated): the Phase 4 "A permission was
/// revoked" banner was replaced by the Security Center, which shows the
/// Phase 7 Protection Health status (one source of truth). The same
/// detection scenarios now assert that status, the unchanged permissions
/// badge and the revocation re-check. SIMULATED: static services.
void main() {
  /// The Security tab is a lazy ListView: at the default 800x600 test
  /// viewport the App lock permissions section (with its DsDotBadge) is
  /// never mounted. Tests that assert on those rows need a tall surface.
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// A configured, simulated-healthy device (PIN, one protected app,
  /// running native engine), as in the Phase 7 dashboard tests.
  Future<AppContainer> configuredContainer() async {
    final AppContainer container = AppContainer.inMemory(
      usageAccessGranted: true,
      accessibilityEnabled: true,
      overlayGranted: true,
    );
    await container.auth.enrollPin('1234');
    await container.protectedApps.add(
      ProtectedApp(
        packageName: 'com.example.protected',
        label: 'Protected',
        addedAt: DateTime(2026, 9, 6),
      ),
    );
    (container.watcher as StaticWatcherService)
      ..protectionConfigured = true
      ..running = true
      ..accessibilityServiceConnected = true
      ..shieldArmed = true
      ..challengePending = false
      ..backgroundRestricted = false
      ..powerSaveMode = false
      ..ignoringBatteryOptimizations = false
      ..sdkInt = 34;
    return container;
  }

  Finder inHealth(String text) => find.descendant(
        of: find.byKey(const Key('sc_health_banner')),
        matching: find.text(text),
      );

  /// Phase 9 / M3: an issue is named once in the Protection Health card and
  /// once, as a recommendation, in Recommended improvements (exactly twice).
  void expectIssueNamed(String text) {
    expect(
      find.descendant(
        of: find.byKey(const Key('security_center_health')),
        matching: find.textContaining(text),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('security_center_recommendations')),
        matching: find.textContaining(text),
      ),
      findsOneWidget,
    );
    expect(find.textContaining(text), findsNWidgets(2));
  }

  Finder permissionsBadge() => find.byWidgetPredicate(
        (Widget w) => w is DsDotBadge && w.show,
      );

  const String overlayTurnedOff = 'Display over other apps was turned off';

  /// The user returns from the Android settings screen.
  Future<void> resumeFromSettings(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  }

  Future<void> openSecurity(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('nav_security')));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'revoking a granted capability is re-checked at once: PROTECTION '
      'OFFLINE, Fix protection and the permissions badge',
      (WidgetTester tester) async {
    useTallViewport(tester);
    final AppContainer container = await configuredContainer();
    await tester.pumpWidget(SmartAppLockApp(container: container));
    await tester.pumpAndSettle();
    await openSecurity(tester);
    expect(inHealth(HealthPresentation.secureTitle), findsOneWidget);
    expect(permissionsBadge(), findsNothing);

    // Overlay is required: the capability monitor's revocation event alone
    // (no resume) refreshes the status.
    (container.overlay as StaticOverlayLockService).overlayGranted = false;
    await container.capabilityMonitor.probe();
    await tester.pumpAndSettle();

    expect(inHealth(HealthPresentation.offlineTitle), findsOneWidget);
    expectIssueNamed(overlayTurnedOff);
    expect(
      find.descendant(
        of: find.byKey(const Key('security_center_health')),
        matching: find.text(SecurityCenterSection.fixProtectionLabel),
      ),
      findsOneWidget,
    );
    expect(permissionsBadge(), findsOneWidget);

    await container.capabilityMonitor.dispose();
  });

  testWidgets(
      'before setup, a revocation marks the permissions badge while health '
      'stays worded as setup (never a failure, never SECURE)',
      (WidgetTester tester) async {
    useTallViewport(tester);
    final AppContainer container = AppContainer.inMemory(
      usageAccessGranted: true,
      accessibilityEnabled: true,
      overlayGranted: true,
    );
    await tester.pumpWidget(SmartAppLockApp(container: container));
    await tester.pumpAndSettle();
    await openSecurity(tester);

    (container.overlay as StaticOverlayLockService).overlayGranted = false;
    await container.capabilityMonitor.probe();
    await tester.pumpAndSettle();

    expect(permissionsBadge(), findsOneWidget);
    expect(inHealth(HealthPresentation.secureTitle), findsNothing);
    expect(
      find.textContaining('Setup is not finished yet.'),
      findsOneWidget,
    );

    await container.capabilityMonitor.dispose();
  });

  testWidgets(
      'the guard probes on resume; opening the Security tab re-checks '
      'health', (WidgetTester tester) async {
    useTallViewport(tester);
    final AppContainer container = await configuredContainer();
    await tester.pumpWidget(SmartAppLockApp(container: container));
    await tester.pumpAndSettle();

    // Revoke overlay; the resume probe must detect it.
    (container.overlay as StaticOverlayLockService).overlayGranted = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    await openSecurity(tester);
    expect(inHealth(HealthPresentation.offlineTitle), findsOneWidget);
    expectIssueNamed(overlayTurnedOff);
    expect(permissionsBadge(), findsOneWidget);

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

  testWidgets(
      'restoring ALL revoked capabilities returns to SECURE without a '
      'restart', (WidgetTester tester) async {
    useTallViewport(tester);
    final AppContainer container = await configuredContainer();
    final StaticWatcherService watcher =
        container.watcher as StaticWatcherService;
    await tester.pumpWidget(SmartAppLockApp(container: container));
    await tester.pumpAndSettle();
    await openSecurity(tester);
    expect(inHealth(HealthPresentation.secureTitle), findsOneWidget);

    // All three revoked in the system settings.
    (container.installedAppsService as StaticInstalledAppsService)
        .usageAccessGranted = false;
    (container.accessibility as StaticAccessibilityLockService).enabled = false;
    watcher.accessibilityServiceConnected = false;
    (container.overlay as StaticOverlayLockService).overlayGranted = false;
    await container.capabilityMonitor.probe();
    await tester.pumpAndSettle();
    expect(inHealth(HealthPresentation.offlineTitle), findsOneWidget);

    // The user restores ALL three and returns to the app.
    (container.installedAppsService as StaticInstalledAppsService)
        .usageAccessGranted = true;
    (container.accessibility as StaticAccessibilityLockService).enabled = true;
    watcher.accessibilityServiceConnected = true;
    (container.overlay as StaticOverlayLockService).overlayGranted = true;
    await resumeFromSettings(tester);

    expect(inHealth(HealthPresentation.secureTitle), findsOneWidget);
    expect(permissionsBadge(), findsNothing);

    // And a NEW required-capability revocation after recovery is detected.
    (container.overlay as StaticOverlayLockService).overlayGranted = false;
    await container.capabilityMonitor.probe();
    await tester.pumpAndSettle();
    expect(inHealth(HealthPresentation.offlineTitle), findsOneWidget);

    await container.capabilityMonitor.dispose();
  });

  testWidgets(
      'restoring only the shield is not SECURE until the early detector '
      'returns', (WidgetTester tester) async {
    useTallViewport(tester);
    final AppContainer container = await configuredContainer();
    final StaticWatcherService watcher =
        container.watcher as StaticWatcherService;
    await tester.pumpWidget(SmartAppLockApp(container: container));
    await tester.pumpAndSettle();
    await openSecurity(tester);

    // Revoke both detectors AND the required overlay.
    (container.installedAppsService as StaticInstalledAppsService)
        .usageAccessGranted = false;
    (container.accessibility as StaticAccessibilityLockService).enabled = false;
    watcher.accessibilityServiceConnected = false;
    (container.overlay as StaticOverlayLockService).overlayGranted = false;
    await container.capabilityMonitor.probe();
    await tester.pumpAndSettle();
    expect(inHealth(HealthPresentation.offlineTitle), findsOneWidget);

    // Restore ONLY overlay: detection is still offline.
    (container.overlay as StaticOverlayLockService).overlayGranted = true;
    await resumeFromSettings(tester);
    expect(inHealth(HealthPresentation.offlineTitle), findsOneWidget);

    // Usage Access alone is delayed detection: attention, never SECURE.
    (container.installedAppsService as StaticInstalledAppsService)
        .usageAccessGranted = true;
    await resumeFromSettings(tester);
    expect(inHealth(HealthPresentation.attentionTitle), findsOneWidget);
    expect(inHealth(HealthPresentation.secureTitle), findsNothing);

    (container.accessibility as StaticAccessibilityLockService).enabled = true;
    watcher.accessibilityServiceConnected = true;
    await resumeFromSettings(tester);
    expect(inHealth(HealthPresentation.secureTitle), findsOneWidget);

    await container.capabilityMonitor.dispose();
  });
}
