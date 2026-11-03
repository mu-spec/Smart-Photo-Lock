import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/ui/screens/health/health_presentation.dart';
import 'package:smart_app_lock/ui/screens/permissions/accessibility_setup_screen.dart';
import 'package:smart_app_lock/ui/screens/permissions/overlay_setup_screen.dart';
import 'package:smart_app_lock/ui/screens/permissions/permission_setup_screen.dart';
import 'package:smart_app_lock/ui/screens/permissions/usage_access_screen.dart';

/// Phase 4G regression: the full permission lifecycle — grant, deny and
/// revoke — exercised end-to-end through the production app wiring
/// (router + AppScope + capability monitor + real screens).
///
/// The system settings screen is simulated through the mutable static
/// services: flipping a flag is the moment the user toggles the
/// capability in Android settings; an `inactive → resumed` lifecycle
/// transition is the moment they come back to the app.
///
/// Phase 9 / M1 (intentionally updated): the Phase 4 "A permission was
/// revoked" banner was replaced by the Security Center's Phase 7 Protection
/// Health status. Deny/grant paths (no credential yet) now assert that no
/// revocation alert appears; revoke paths run on a configured, simulated-
/// healthy device and assert the Phase 7 status (Usage or Accessibility
/// turned off: ATTENTION REQUIRED; the required shield turned off:
/// PROTECTION OFFLINE). Rows, badge and setup screens are unchanged.
void main() {
  Future<AppContainer> pumpApp(
    WidgetTester tester, {
    bool usageAccessGranted = false,
    bool accessibilityEnabled = false,
    bool overlayGranted = false,
    bool configured = false,
  }) async {
    // Phase 9 / M2: the Security Score card adds height above the rows;
    // the tab is a lazy ListView, so the viewport is taller (intentional).
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final AppContainer container = AppContainer.inMemory(
      usageAccessGranted: usageAccessGranted,
      accessibilityEnabled: accessibilityEnabled,
      overlayGranted: overlayGranted,
    );
    if (configured) {
      // PIN + one protected app + a running simulated native engine.
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
    }
    await tester.pumpWidget(SmartAppLockApp(container: container));
    await tester.pumpAndSettle();
    return container;
  }

  /// The user leaves for the system settings and returns to the app.
  Future<void> resume(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  }

  Future<void> openSecurity(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('nav_security')));
    await tester.pumpAndSettle();
  }

  /// Security tab → "Set up" action on the App lock permissions section.
  Future<void> openPermissionSetup(WidgetTester tester) async {
    await openSecurity(tester);
    // Scope to the section title row (other cards carry actions too).
    final Finder setUp = find.descendant(
      of: find.byType(DsSectionTitle),
      matching: find.text('Set up'),
    );
    await tester.ensureVisible(setUp);
    await tester.tap(setUp);
    await tester.pumpAndSettle();
  }

  /// The Security-tab status row for [title] (a [SecurityStatusItem]).
  Finder securityRow(String title) =>
      find.widgetWithText(SecurityStatusItem, title);

  /// Asserts the status label ([label]) shown inside the row for [title].
  void expectSecurityLabel(WidgetTester tester, String title, String label) {
    expect(
      find.descendant(
        of: securityRow(title),
        matching: find.text(label),
      ),
      findsOneWidget,
    );
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

  Finder shownBadge() => find.byWidgetPredicate(
        (Widget w) => w is DsDotBadge && w.show,
      );

  /// No revocation is reported: no failure wording, nothing "turned off",
  /// no attention dot on the permissions section.
  void expectNoRevocationAlert() {
    expect(
      find.textContaining('App locking may not work until protection'),
      findsNothing,
    );
    expect(find.textContaining('was turned off'), findsNothing);
    expect(shownBadge(), findsNothing);
  }

  void expectPermRowLabel(WidgetTester tester, String rowKey, String label) {
    expect(
      find.descendant(
        of: find.byKey(Key(rowKey)),
        matching: find.text(label),
      ),
      findsOneWidget,
    );
  }

  group('deny paths', () {
    testWidgets(
        'all three denied: Security rows show Needed and no alert banner',
        (WidgetTester tester) async {
      final AppContainer container = await pumpApp(tester);
      await openSecurity(tester);

      expectSecurityLabel(tester, 'Usage access', 'Recommended');
      expectSecurityLabel(tester, 'Accessibility service', 'Required');
      expectSecurityLabel(tester, 'Background lock shield', 'Required');
      expectNoRevocationAlert();

      await container.capabilityMonitor.dispose();
    });

    testWidgets(
        'all three denied: permission setup shows 0 of 3 ready and three '
        'Action Required rows', (WidgetTester tester) async {
      final AppContainer container = await pumpApp(tester);
      await openPermissionSetup(tester);

      expect(
        find.text(PermissionSetupScreen.coreMissingLabel),
        findsOneWidget,
      );
      expectPermRowLabel(tester, 'perm_row_usage', 'Recommended');
      expectPermRowLabel(tester, 'perm_row_accessibility', 'Required');
      expectPermRowLabel(tester, 'perm_row_overlay', 'Required');

      await container.capabilityMonitor.dispose();
    });

    testWidgets(
        'denied usage access: explains, opens settings, and does not flip '
        'without a grant', (WidgetTester tester) async {
      final AppContainer container = await pumpApp(tester);
      await openPermissionSetup(tester);

      await tester.tap(find.byKey(const Key('perm_row_usage')));
      await tester.pumpAndSettle();
      expect(find.text(UsageAccessScreen.notGrantedTitle), findsOneWidget);
      expect(find.text(UsageAccessScreen.notGrantedMessage), findsOneWidget);

      await tester.tap(find.byKey(const Key('usage_access_open_settings')));
      await tester.pumpAndSettle();
      final StaticInstalledAppsService apps =
          container.installedAppsService as StaticInstalledAppsService;
      expect(apps.requestUsageAccessCalls, 1);

      // Returns from the settings screen without granting anything.
      await resume(tester);
      expect(find.text(UsageAccessScreen.notGrantedTitle), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expectPermRowLabel(tester, 'perm_row_usage', 'Recommended');
      expect(
        find.text(PermissionSetupScreen.coreMissingLabel),
        findsOneWidget,
      );

      await container.capabilityMonitor.dispose();
    });

    testWidgets(
        'denied accessibility: shows the prominent disclosure and opens '
        'settings', (WidgetTester tester) async {
      final AppContainer container = await pumpApp(tester);
      await openPermissionSetup(tester);

      await tester.tap(find.byKey(const Key('perm_row_accessibility')));
      await tester.pumpAndSettle();
      expect(
        find.text(AccessibilitySetupScreen.notEnabledTitle),
        findsOneWidget,
      );
      expect(
        find.text(AccessibilitySetupScreen.disclosureTitle),
        findsOneWidget,
      );
      expect(
        find.text(AccessibilitySetupScreen.notUsedElsewhere),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('accessibility_open_settings')));
      await tester.pumpAndSettle();
      final StaticAccessibilityLockService service =
          container.accessibility as StaticAccessibilityLockService;
      expect(service.requestServiceEnableCalls, 1);

      // Still disabled after returning: the row must stay Action Required.
      await resume(tester);
      expect(
        find.text(AccessibilitySetupScreen.notEnabledTitle),
        findsOneWidget,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expectPermRowLabel(tester, 'perm_row_accessibility', 'Required');

      await container.capabilityMonitor.dispose();
    });

    testWidgets(
        'denied overlay: shows the single-use disclosure and opens settings',
        (WidgetTester tester) async {
      final AppContainer container = await pumpApp(tester);
      await openPermissionSetup(tester);

      await tester.tap(find.byKey(const Key('perm_row_overlay')));
      await tester.pumpAndSettle();
      expect(find.text(OverlaySetupScreen.notGrantedTitle), findsOneWidget);
      expect(find.text(OverlaySetupScreen.disclosureTitle), findsOneWidget);
      expect(
        find.text(OverlaySetupScreen.notUsedElsewhere),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('overlay_open_settings')));
      await tester.pumpAndSettle();
      final StaticOverlayLockService service =
          container.overlay as StaticOverlayLockService;
      expect(service.requestCalls, 1);

      await resume(tester);
      expect(find.text(OverlaySetupScreen.notGrantedTitle), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expectPermRowLabel(tester, 'perm_row_overlay', 'Required');

      await container.capabilityMonitor.dispose();
    });
  });

  group('grant paths', () {
    testWidgets(
        'granting all three in system settings then returning shows 3 of 3 '
        'ready and Granted/Enabled everywhere', (WidgetTester tester) async {
      final AppContainer container = await pumpApp(tester);
      await openSecurity(tester);
      expectSecurityLabel(tester, 'Usage access', 'Recommended');
      expectSecurityLabel(tester, 'Accessibility service', 'Required');
      expectSecurityLabel(tester, 'Background lock shield', 'Required');

      // The user enables every capability in Android settings.
      (container.installedAppsService as StaticInstalledAppsService)
          .usageAccessGranted = true;
      (container.accessibility as StaticAccessibilityLockService).enabled =
          true;
      (container.overlay as StaticOverlayLockService).overlayGranted = true;

      // Round-trip through the setup screen: the Security rows refresh
      // when the setup flow returns.
      final Finder setUp = find.descendant(
        of: find.byType(DsSectionTitle),
        matching: find.text('Set up'),
      );
      await tester.ensureVisible(setUp);
      await tester.tap(setUp);
      await tester.pumpAndSettle();
      expect(
        find.text(PermissionSetupScreen.coreReadyLabel),
        findsOneWidget,
      );
      expectPermRowLabel(tester, 'perm_row_usage', 'Enabled');
      expectPermRowLabel(tester, 'perm_row_accessibility', 'Enabled');
      expectPermRowLabel(tester, 'perm_row_overlay', 'Enabled');

      await tester.pageBack();
      await tester.pumpAndSettle();
      expectSecurityLabel(tester, 'Usage access', 'Enabled');
      expectSecurityLabel(tester, 'Accessibility service', 'Enabled');
      expectSecurityLabel(tester, 'Background lock shield', 'Enabled');
      expectNoRevocationAlert();

      await container.capabilityMonitor.dispose();
    });

    testWidgets(
        'granting while backgrounded refreshes the Security rows on return',
        (WidgetTester tester) async {
      final AppContainer container = await pumpApp(tester);
      await openSecurity(tester);
      expectSecurityLabel(tester, 'Usage access', 'Recommended');
      expectSecurityLabel(tester, 'Accessibility service', 'Required');
      expectSecurityLabel(tester, 'Background lock shield', 'Required');

      // The user grants every capability in Android settings while the
      // app is backgrounded, then returns — no navigation involved.
      (container.installedAppsService as StaticInstalledAppsService)
          .usageAccessGranted = true;
      (container.accessibility as StaticAccessibilityLockService).enabled =
          true;
      (container.overlay as StaticOverlayLockService).overlayGranted = true;
      await resume(tester);

      expectSecurityLabel(tester, 'Usage access', 'Enabled');
      expectSecurityLabel(tester, 'Accessibility service', 'Enabled');
      expectSecurityLabel(tester, 'Background lock shield', 'Enabled');
      expectNoRevocationAlert();

      await container.capabilityMonitor.dispose();
    });

    testWidgets(
        'granting usage access inside its flow flips the row to Enabled',
        (WidgetTester tester) async {
      final AppContainer container = await pumpApp(tester);
      await openPermissionSetup(tester);

      await tester.tap(find.byKey(const Key('perm_row_usage')));
      await tester.pumpAndSettle();
      expect(find.text(UsageAccessScreen.notGrantedTitle), findsOneWidget);

      // Grant happens in the system settings screen.
      (container.installedAppsService as StaticInstalledAppsService)
          .usageAccessGranted = true;
      await resume(tester);
      expect(find.text(UsageAccessScreen.grantedTitle), findsOneWidget);

      await tester.tap(find.text(UsageAccessScreen.doneLabel));
      await tester.pumpAndSettle();
      expectPermRowLabel(tester, 'perm_row_usage', 'Enabled');
      expect(
        find.text(PermissionSetupScreen.coreMissingLabel),
        findsOneWidget,
      );

      await container.capabilityMonitor.dispose();
    });

    testWidgets(
        'granting accessibility inside its flow flips the row to Enabled',
        (WidgetTester tester) async {
      final AppContainer container = await pumpApp(tester);
      await openPermissionSetup(tester);

      await tester.tap(find.byKey(const Key('perm_row_accessibility')));
      await tester.pumpAndSettle();
      expect(
        find.text(AccessibilitySetupScreen.notEnabledTitle),
        findsOneWidget,
      );

      (container.accessibility as StaticAccessibilityLockService).enabled =
          true;
      await resume(tester);
      expect(
        find.text(AccessibilitySetupScreen.enabledTitle),
        findsOneWidget,
      );

      await tester.tap(find.text(AccessibilitySetupScreen.doneLabel));
      await tester.pumpAndSettle();
      expectPermRowLabel(tester, 'perm_row_accessibility', 'Enabled');
      expect(
        find.text(PermissionSetupScreen.coreMissingLabel),
        findsOneWidget,
      );

      await container.capabilityMonitor.dispose();
    });

    testWidgets('granting overlay inside its flow flips the row to Enabled',
        (WidgetTester tester) async {
      final AppContainer container = await pumpApp(tester);
      await openPermissionSetup(tester);

      await tester.tap(find.byKey(const Key('perm_row_overlay')));
      await tester.pumpAndSettle();
      expect(find.text(OverlaySetupScreen.notGrantedTitle), findsOneWidget);

      (container.overlay as StaticOverlayLockService).overlayGranted = true;
      await resume(tester);
      expect(find.text(OverlaySetupScreen.grantedTitle), findsOneWidget);

      await tester.tap(find.text(OverlaySetupScreen.doneLabel));
      await tester.pumpAndSettle();
      expectPermRowLabel(tester, 'perm_row_overlay', 'Enabled');
      expect(
        find.text(PermissionSetupScreen.coreMissingLabel),
        findsOneWidget,
      );

      await container.capabilityMonitor.dispose();
    });
  });

  group('revoke paths', () {
    testWidgets(
        'revoking usage access keeps the Accessibility early path active',
        (WidgetTester tester) async {
      final AppContainer container = await pumpApp(
        tester,
        usageAccessGranted: true,
        accessibilityEnabled: true,
        overlayGranted: true,
        configured: true,
      );
      await openSecurity(tester);
      expectSecurityLabel(tester, 'Usage access', 'Enabled');
      expect(inHealth(HealthPresentation.secureTitle), findsOneWidget);

      (container.installedAppsService as StaticInstalledAppsService)
          .usageAccessGranted = false;
      await container.capabilityMonitor.probe();
      await tester.pumpAndSettle();

      // Delayed recovery lost, early path kept: attention, not offline.
      expect(inHealth(HealthPresentation.attentionTitle), findsOneWidget);
      expectIssueNamed('Usage Access was turned off');
      // Usage Access is recommended, not required: no attention dot
      // (Phase 4F badge rule, unchanged).
      expect(shownBadge(), findsNothing);
      expectSecurityLabel(tester, 'Usage access', 'Recommended');
      expectSecurityLabel(tester, 'Accessibility service', 'Enabled');
      expectSecurityLabel(tester, 'Background lock shield', 'Enabled');

      await container.capabilityMonitor.dispose();
    });

    testWidgets('revoking accessibility is detected and flagged',
        (WidgetTester tester) async {
      final AppContainer container = await pumpApp(
        tester,
        usageAccessGranted: true,
        accessibilityEnabled: true,
        overlayGranted: true,
        configured: true,
      );
      await openSecurity(tester);

      (container.accessibility as StaticAccessibilityLockService).enabled =
          false;
      await container.capabilityMonitor.probe();
      await tester.pumpAndSettle();

      expect(inHealth(HealthPresentation.attentionTitle), findsOneWidget);
      expectIssueNamed('Accessibility service was turned off');
      expect(shownBadge(), findsOneWidget);
      expectSecurityLabel(tester, 'Accessibility service', 'Required');
      expectSecurityLabel(tester, 'Usage access', 'Enabled');

      await container.capabilityMonitor.dispose();
    });

    testWidgets('revoking overlay is detected and flagged',
        (WidgetTester tester) async {
      final AppContainer container = await pumpApp(
        tester,
        usageAccessGranted: true,
        accessibilityEnabled: true,
        overlayGranted: true,
        configured: true,
      );
      await openSecurity(tester);

      (container.overlay as StaticOverlayLockService).overlayGranted = false;
      await container.capabilityMonitor.probe();
      await tester.pumpAndSettle();

      expect(inHealth(HealthPresentation.offlineTitle), findsOneWidget);
      expectIssueNamed('Display over other apps was turned off');
      expect(shownBadge(), findsOneWidget);
      expectSecurityLabel(tester, 'Background lock shield', 'Required');
      expectSecurityLabel(tester, 'Accessibility service', 'Enabled');

      await container.capabilityMonitor.dispose();
    });

    testWidgets(
        'Accessibility revocation leaves early protection incomplete in setup '
        'screen', (WidgetTester tester) async {
      final AppContainer container = await pumpApp(
        tester,
        usageAccessGranted: true,
        accessibilityEnabled: true,
        overlayGranted: true,
        configured: true,
      );
      await openSecurity(tester);

      (container.accessibility as StaticAccessibilityLockService).enabled =
          false;
      await container.capabilityMonitor.probe();
      await tester.pumpAndSettle();

      final Finder setUp = find.descendant(
        of: find.byType(DsSectionTitle),
        matching: find.text('Set up'),
      );
      await tester.ensureVisible(setUp);
      await tester.tap(setUp);
      await tester.pumpAndSettle();
      expect(
        find.text(PermissionSetupScreen.coreMissingLabel),
        findsOneWidget,
      );
      expectPermRowLabel(tester, 'perm_row_usage', 'Enabled');
      expectPermRowLabel(tester, 'perm_row_accessibility', 'Required');
      expectPermRowLabel(tester, 'perm_row_overlay', 'Enabled');

      await container.capabilityMonitor.dispose();
    });

    testWidgets(
        're-granting recovers to fully ready and the alert does not '
        'duplicate', (WidgetTester tester) async {
      final AppContainer container = await pumpApp(
        tester,
        usageAccessGranted: true,
        accessibilityEnabled: true,
        overlayGranted: true,
        configured: true,
      );
      await openSecurity(tester);

      (container.accessibility as StaticAccessibilityLockService).enabled =
          false;
      await container.capabilityMonitor.probe();
      await tester.pumpAndSettle();
      expect(inHealth(HealthPresentation.attentionTitle), findsOneWidget);

      // The user re-enables the required service and returns from Settings.
      (container.accessibility as StaticAccessibilityLockService).enabled =
          true;
      await resume(tester);
      expect(inHealth(HealthPresentation.secureTitle), findsOneWidget);
      expect(inHealth(HealthPresentation.attentionTitle), findsNothing);
      expect(shownBadge(), findsNothing);

      // The setup screen proves the recovered state.
      final Finder setUp = find.descendant(
        of: find.byType(DsSectionTitle),
        matching: find.text('Set up'),
      );
      await tester.ensureVisible(setUp);
      await tester.tap(setUp);
      await tester.pumpAndSettle();
      expect(
        find.text(PermissionSetupScreen.coreReadyLabel),
        findsOneWidget,
      );
      expectPermRowLabel(tester, 'perm_row_accessibility', 'Enabled');

      await container.capabilityMonitor.dispose();
    });

    testWidgets('a revocation made while backgrounded is detected on return',
        (WidgetTester tester) async {
      final AppContainer container = await pumpApp(
        tester,
        usageAccessGranted: true,
        accessibilityEnabled: true,
        overlayGranted: true,
        configured: true,
      );
      await openSecurity(tester);
      expect(inHealth(HealthPresentation.secureTitle), findsOneWidget);

      // The user revokes overlay in system settings while the app is
      // backgrounded; the guard's resume probe must catch it.
      (container.overlay as StaticOverlayLockService).overlayGranted = false;
      await resume(tester);

      expect(inHealth(HealthPresentation.offlineTitle), findsOneWidget);
      expectIssueNamed('Display over other apps was turned off');
      expectSecurityLabel(tester, 'Background lock shield', 'Required');

      await container.capabilityMonitor.dispose();
    });
  });
}
