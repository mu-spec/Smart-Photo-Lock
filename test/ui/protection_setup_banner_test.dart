import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/ui/screens/health/health_presentation.dart';
import 'package:smart_app_lock/ui/screens/security/security_screen.dart';

/// Security tab status for first-install setup, revocation and a ready
/// state.
///
/// Phase 9 / M1 (intentionally updated): these scenarios were written for
/// the Phase 4 "Security status" banners ("Protection setup required",
/// "A permission was revoked", "Capability setup ready", "Protection engine
/// active", ...). Those banners classified health separately from the
/// Phase 7 Protection Health engine and were replaced by the Security
/// Center, so the same scenarios now assert the ONE Phase 7 status shown on
/// the tab, plus the unchanged App lock permissions rows. SIMULATED: static
/// services, no device evidence.
void main() {
  Future<AppContainer> pumpSecurity(
    WidgetTester tester, {
    required bool usage,
    required bool accessibility,
    required bool overlay,
    bool configured = false,
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final AppContainer container = AppContainer.inMemory(
      usageAccessGranted: usage,
      accessibilityEnabled: accessibility,
      overlayGranted: overlay,
    );
    if (configured) {
      await container.auth.enrollPin('1234');
      await container.protectedApps.add(
        ProtectedApp(
          packageName: 'com.example.protected',
          label: 'Protected',
          addedAt: DateTime(2026, 9, 6),
        ),
      );
      // A running simulated native engine (as the Phase 7 dashboard tests).
      (container.watcher as StaticWatcherService)
        ..protectionConfigured = true
        ..running = true
        ..accessibilityServiceConnected = accessibility
        ..shieldArmed = true
        ..challengePending = false
        ..backgroundRestricted = false
        ..powerSaveMode = false
        ..ignoringBatteryOptimizations = false
        ..sdkInt = 34;
    }
    await tester.pumpWidget(
      AppScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const SecurityScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> resumeFromSettings(WidgetTester tester) async {
    for (final AppLifecycleState s in const <AppLifecycleState>[
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pumpAndSettle();
  }

  Finder inHealth(String text) => find.descendant(
        of: find.byKey(const Key('sc_health_banner')),
        matching: find.text(text),
      );

  Finder status(String title, String status) => find.descendant(
        of: find.ancestor(
          of: find.text(title),
          matching: find.byType(SecurityStatusItem),
        ),
        matching: find.text(status),
      );

  const String setupMessage = 'Setup is not finished yet. Create an unlock '
      'PIN or pattern and choose apps to start protecting them.';
  // Exact approved wording (Phase 9 / M2 review), pinned as a literal.
  const String failureMessage = 'Protection is offline. App locking may '
      'not work until protection is restored.';

  void expectNoLegacyBanners() {
    for (final String legacy in const <String>[
      'Protection setup required',
      'A permission was revoked',
      'Capability setup ready',
      'Protection engine active',
      'Protection engine unavailable',
      'Protection limited by delayed detection',
      'Protection is not fully set up',
    ]) {
      expect(find.text(legacy), findsNothing, reason: legacy);
    }
  }

  testWidgets(
      'fresh install: setup worded as setup (not a failure), never SECURE; '
      'the rows show what is required', (WidgetTester tester) async {
    await pumpSecurity(
      tester,
      usage: false,
      accessibility: false,
      overlay: false,
    );

    expect(inHealth(HealthPresentation.offlineTitle), findsOneWidget);
    expect(inHealth(setupMessage), findsOneWidget);
    expect(inHealth(failureMessage), findsNothing);
    expect(inHealth(HealthPresentation.secureTitle), findsNothing);
    expect(status('Accessibility service', 'Required'), findsOneWidget);
    expect(status('Background lock shield', 'Required'), findsOneWidget);
    expect(status('Usage access', 'Recommended'), findsOneWidget);
    expectNoLegacyBanners();
  });

  testWidgets('one detector still requires the shield',
      (WidgetTester tester) async {
    await pumpSecurity(
      tester,
      usage: true,
      accessibility: false,
      overlay: false,
    );

    expect(inHealth(setupMessage), findsOneWidget);
    expect(status('Usage access', 'Enabled'), findsOneWidget);
    expect(status('Accessibility service', 'Required'), findsOneWidget);
    expect(status('Background lock shield', 'Required'), findsOneWidget);
    expectNoLegacyBanners();
  });

  testWidgets('both detectors still require the shield',
      (WidgetTester tester) async {
    await pumpSecurity(
      tester,
      usage: true,
      accessibility: true,
      overlay: false,
    );

    expect(inHealth(setupMessage), findsOneWidget);
    expect(status('Accessibility service', 'Enabled'), findsOneWidget);
    expect(status('Background lock shield', 'Required'), findsOneWidget);
    expectNoLegacyBanners();
  });

  testWidgets(
      'all granted but no credential or app: still setup, never SECURE, '
      'never a failure', (WidgetTester tester) async {
    await pumpSecurity(
      tester,
      usage: true,
      accessibility: true,
      overlay: true,
    );

    expect(inHealth(setupMessage), findsOneWidget);
    expect(inHealth(HealthPresentation.secureTitle), findsNothing);
    expect(inHealth(failureMessage), findsNothing);
    expectNoLegacyBanners();
  });

  testWidgets('active protection is SECURE and never also reports setup',
      (WidgetTester tester) async {
    await pumpSecurity(
      tester,
      usage: true,
      accessibility: true,
      overlay: true,
      configured: true,
    );

    expect(inHealth(HealthPresentation.secureTitle), findsOneWidget);
    expect(inHealth(setupMessage), findsNothing);
    expectNoLegacyBanners();
  });

  testWidgets(
      'configured usage-only protection (Accessibility off) needs attention, '
      'never SECURE', (WidgetTester tester) async {
    await pumpSecurity(
      tester,
      usage: true,
      accessibility: false,
      overlay: true,
      configured: true,
    );

    expect(inHealth(HealthPresentation.attentionTitle), findsOneWidget);
    expect(inHealth(HealthPresentation.secureTitle), findsNothing);
    expectNoLegacyBanners();
  });

  testWidgets('losing Usage recovery with Accessibility on needs attention',
      (WidgetTester tester) async {
    final AppContainer container = await pumpSecurity(
      tester,
      usage: true,
      accessibility: true,
      overlay: true,
      configured: true,
    );
    expect(inHealth(HealthPresentation.secureTitle), findsOneWidget);

    (container.installedAppsService as StaticInstalledAppsService)
        .usageAccessGranted = false;
    await resumeFromSettings(tester);

    expect(inHealth(HealthPresentation.attentionTitle), findsOneWidget);
    expect(find.text('Usage Access was turned off'), findsOneWidget);
    expect(status('Usage access', 'Recommended'), findsOneWidget);
    expectNoLegacyBanners();
  });

  testWidgets(
      'usage-only restoration stays limited until Accessibility returns',
      (WidgetTester tester) async {
    final AppContainer container = await pumpSecurity(
      tester,
      usage: true,
      accessibility: true,
      overlay: true,
      configured: true,
    );
    final StaticWatcherService watcher =
        container.watcher as StaticWatcherService;
    (container.installedAppsService as StaticInstalledAppsService)
        .usageAccessGranted = false;
    (container.accessibility as StaticAccessibilityLockService).enabled = false;
    watcher.accessibilityServiceConnected = false;
    await resumeFromSettings(tester);
    expect(inHealth(HealthPresentation.offlineTitle), findsOneWidget);
    expect(HealthPresentation.offlineMessage, failureMessage);
    expect(find.textContaining('can open without a lock'), findsNothing);
    expect(inHealth(failureMessage), findsOneWidget);

    (container.installedAppsService as StaticInstalledAppsService)
        .usageAccessGranted = true;
    await resumeFromSettings(tester);
    expect(inHealth(HealthPresentation.attentionTitle), findsOneWidget);
    expect(inHealth(HealthPresentation.secureTitle), findsNothing);

    (container.accessibility as StaticAccessibilityLockService).enabled = true;
    watcher.accessibilityServiceConnected = true;
    await resumeFromSettings(tester);
    expect(inHealth(HealthPresentation.secureTitle), findsOneWidget);
    expectNoLegacyBanners();
  });

  testWidgets(
      'a revoked required shield is PROTECTION OFFLINE worded as turned off, '
      'not as setup', (WidgetTester tester) async {
    final AppContainer container = await pumpSecurity(
      tester,
      usage: true,
      accessibility: true,
      overlay: true,
      configured: true,
    );
    (container.overlay as StaticOverlayLockService).overlayGranted = false;
    await resumeFromSettings(tester);

    expect(inHealth(HealthPresentation.offlineTitle), findsOneWidget);
    expect(
      find.textContaining('Display over other apps was turned off'),
      findsOneWidget,
    );
    expect(inHealth(setupMessage), findsNothing);
    expect(status('Background lock shield', 'Required'), findsOneWidget);
    expectNoLegacyBanners();
  });
}
