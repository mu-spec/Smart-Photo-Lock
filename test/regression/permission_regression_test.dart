import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/ui/screens/permissions/accessibility_setup_screen.dart';
import 'package:smart_app_lock/ui/screens/permissions/overlay_setup_screen.dart';
import 'package:smart_app_lock/ui/screens/permissions/permission_setup_screen.dart';
import 'package:smart_app_lock/ui/screens/permissions/usage_access_screen.dart';
import 'package:smart_app_lock/ui/screens/security/security_screen.dart';

/// Phase 4G regression: the full permission lifecycle — grant, deny and
/// revoke — exercised end-to-end through the production app wiring
/// (router + AppScope + capability monitor + real screens).
///
/// The system settings screen is simulated through the mutable static
/// services: flipping a flag is the moment the user toggles the
/// capability in Android settings; an `inactive → resumed` lifecycle
/// transition is the moment they come back to the app.
void main() {
  Future<AppContainer> pumpApp(
    WidgetTester tester, {
    bool usageAccessGranted = false,
    bool accessibilityEnabled = false,
    bool overlayGranted = false,
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final AppContainer container = AppContainer.inMemory(
      usageAccessGranted: usageAccessGranted,
      accessibilityEnabled: accessibilityEnabled,
      overlayGranted: overlayGranted,
    );
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
    await tester.ensureVisible(find.text('Set up'));
    await tester.tap(find.text('Set up'));
    await tester.pumpAndSettle();
  }

  Finder securityRow(String title) =>
      find.widgetWithText(SecurityStatusItem, title);

  void expectSecurityLabel(WidgetTester tester, String title, String label) {
    expect(
      find.descendant(
        of: find.widgetWithText(SecurityStatusItem, title),
        matching: find.text(label),
      ),
      findsOneWidget,
    );
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

      expectSecurityLabel(tester, 'Usage access', 'Needed');
      expectSecurityLabel(tester, 'Accessibility service', 'Needed');
      expectSecurityLabel(tester, 'Draw over apps', 'Needed');
      expect(find.text(SecurityScreen.revokedTitle), findsNothing);

      await container.capabilityMonitor.dispose();
    });

    testWidgets(
        'all three denied: permission setup shows 0 of 3 ready and three '
        'Action Required rows', (WidgetTester tester) async {
      final AppContainer container = await pumpApp(tester);
      await openPermissionSetup(tester);

      expect(
        find.text(PermissionSetupScreen.readyCount(0)),
        findsOneWidget,
      );
      expectPermRowLabel(tester, 'perm_row_usage', 'Action Required');
      expectPermRowLabel(
          tester, 'perm_row_accessibility', 'Action Required');
      expectPermRowLabel(tester, 'perm_row_overlay', 'Action Required');
      expect(find.text(PermissionSetupScreen.enabledLabel), findsNothing);

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
      expectPermRowLabel(tester, 'perm_row_usage', 'Action Required');
      expect(
        find.text(PermissionSetupScreen.readyCount(0)),
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

      await tester
          .tap(find.byKey(const Key('accessibility_open_settings')));
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
      expectPermRowLabel(
          tester, 'perm_row_accessibility', 'Action Required');

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
      expectPermRowLabel(tester, 'perm_row_overlay', 'Action Required');

      await container.capabilityMonitor.dispose();
    });
  });

  group('grant paths', () {
    testWidgets(
        'granting all three in system settings then returning shows 3 of 3 '
        'ready and Granted/Enabled everywhere', (WidgetTester tester) async {
      final AppContainer container = await pumpApp(tester);
      await openSecurity(tester);
      expectSecurityLabel(tester, 'Usage access', 'Needed');
      expectSecurityLabel(tester, 'Accessibility service', 'Needed');
      expectSecurityLabel(tester, 'Draw over apps', 'Needed');

      // The user enables every capability in Android settings.
      (container.installedAppsService as StaticInstalledAppsService)
          .usageAccessGranted = true;
      (container.accessibility as StaticAccessibilityLockService).enabled =
          true;
      (container.overlay as StaticOverlayLockService).overlayGranted = true;

      // Round-trip through the setup screen: the Security rows refresh
      // when the setup flow returns.
      await tester.ensureVisible(find.text('Set up'));
      await tester.tap(find.text('Set up'));
      await tester.pumpAndSettle();
      expect(
        find.text(PermissionSetupScreen.readyCount(3)),
        findsOneWidget,
      );
      expectPermRowLabel(tester, 'perm_row_usage', 'Enabled');
      expectPermRowLabel(tester, 'perm_row_accessibility', 'Enabled');
      expectPermRowLabel(tester, 'perm_row_overlay', 'Enabled');

      await tester.pageBack();
      await tester.pumpAndSettle();
      expectSecurityLabel(tester, 'Usage access', 'Granted');
      expectSecurityLabel(tester, 'Accessibility service', 'Enabled');
      expectSecurityLabel(tester, 'Draw over apps', 'Enabled');
      expect(find.text(SecurityScreen.revokedTitle), findsNothing);

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
        find.text(PermissionSetupScreen.readyCount(1)),
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
        find.text(PermissionSetupScreen.readyCount(1)),
        findsOneWidget,
      );

      await container.capabilityMonitor.dispose();
    });

    testWidgets(
        'granting overlay inside its flow flips the row to Enabled',
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
        find.text(PermissionSetupScreen.readyCount(1)),
        findsOneWidget,
      );

      await container.capabilityMonitor.dispose();
    });
  });

  group('revoke paths', () {
    testWidgets(
        'revoking usage access surfaces the alert and flips the row to '
        'Needed', (WidgetTester tester) async {
      final AppContainer container = await pumpApp(
        tester,
        usageAccessGranted: true,
        accessibilityEnabled: true,
        overlayGranted: true,
      );
      await openSecurity(tester);
      expectSecurityLabel(tester, 'Usage access', 'Granted');
      expect(find.text(SecurityScreen.revokedTitle), findsNothing);

      (container.installedAppsService as StaticInstalledAppsService)
          .usageAccessGranted = false;
      await container.capabilityMonitor.probe();
      await tester.pumpAndSettle();

      expect(find.text(SecurityScreen.revokedTitle), findsOneWidget);
      expect(find.text(SecurityScreen.revokedMessage), findsOneWidget);
      expect(find.byType(DsDotBadge), findsWidgets);
      expectSecurityLabel(tester, 'Usage access', 'Needed');
      expectSecurityLabel(tester, 'Accessibility service', 'Enabled');
      expectSecurityLabel(tester, 'Draw over apps', 'Enabled');

      await container.capabilityMonitor.dispose();
    });

    testWidgets('revoking accessibility is detected and flagged',
        (WidgetTester tester) async {
      final AppContainer container = await pumpApp(
        tester,
        usageAccessGranted: true,
        accessibilityEnabled: true,
        overlayGranted: true,
      );
      await openSecurity(tester);

      (container.accessibility as StaticAccessibilityLockService).enabled =
          false;
      await container.capabilityMonitor.probe();
      await tester.pumpAndSettle();

      expect(find.text(SecurityScreen.revokedTitle), findsOneWidget);
      expectSecurityLabel(tester, 'Accessibility service', 'Needed');
      expectSecurityLabel(tester, 'Usage access', 'Granted');

      await container.capabilityMonitor.dispose();
    });

    testWidgets('revoking overlay is detected and flagged',
        (WidgetTester tester) async {
      final AppContainer container = await pumpApp(
        tester,
        usageAccessGranted: true,
        accessibilityEnabled: true,
        overlayGranted: true,
      );
      await openSecurity(tester);

      (container.overlay as StaticOverlayLockService).overlayGranted = false;
      await container.capabilityMonitor.probe();
      await tester.pumpAndSettle();

      expect(find.text(SecurityScreen.revokedTitle), findsOneWidget);
      expectSecurityLabel(tester, 'Draw over apps', 'Needed');
      expectSecurityLabel(tester, 'Accessibility service', 'Enabled');

      await container.capabilityMonitor.dispose();
    });

    testWidgets(
        'one revocation leaves the other two ready (2 of 3) in the setup '
        'screen', (WidgetTester tester) async {
      final AppContainer container = await pumpApp(
        tester,
        usageAccessGranted: true,
        accessibilityEnabled: true,
        overlayGranted: true,
      );
      await openSecurity(tester);

      (container.accessibility as StaticAccessibilityLockService).enabled =
          false;
      await container.capabilityMonitor.probe();
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Set up'));
      await tester.tap(find.text('Set up'));
      await tester.pumpAndSettle();
      expect(
        find.text(PermissionSetupScreen.readyCount(2)),
        findsOneWidget,
      );
      expectPermRowLabel(tester, 'perm_row_usage', 'Enabled');
      expectPermRowLabel(
          tester, 'perm_row_accessibility', 'Action Required');
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
      );
      await openSecurity(tester);

      (container.accessibility as StaticAccessibilityLockService).enabled =
          false;
      await container.capabilityMonitor.probe();
      await tester.pumpAndSettle();
      expect(find.text(SecurityScreen.revokedTitle), findsOneWidget);

      // The user re-enables the service; the next probes emit nothing new.
      (container.accessibility as StaticAccessibilityLockService).enabled =
          true;
      await container.capabilityMonitor.probe();
      await tester.pumpAndSettle();
      expect(find.text(SecurityScreen.revokedTitle), findsOneWidget);

      // The setup screen proves the recovered state.
      await tester.ensureVisible(find.text('Set up'));
      await tester.tap(find.text('Set up'));
      await tester.pumpAndSettle();
      expect(
        find.text(PermissionSetupScreen.readyCount(3)),
        findsOneWidget,
      );
      expectPermRowLabel(tester, 'perm_row_accessibility', 'Enabled');

      await container.capabilityMonitor.dispose();
    });

    testWidgets(
        'a revocation made while backgrounded is detected on return',
        (WidgetTester tester) async {
      final AppContainer container = await pumpApp(
        tester,
        usageAccessGranted: true,
        accessibilityEnabled: true,
        overlayGranted: true,
      );
      await openSecurity(tester);
      expect(find.text(SecurityScreen.revokedTitle), findsNothing);

      // The user revokes overlay in system settings while the app is
      // backgrounded; the guard's resume probe must catch it.
      (container.overlay as StaticOverlayLockService).overlayGranted = false;
      await resume(tester);

      expect(find.text(SecurityScreen.revokedTitle), findsOneWidget);
      expectSecurityLabel(tester, 'Draw over apps', 'Needed');

      await container.capabilityMonitor.dispose();
    });
  });
}
