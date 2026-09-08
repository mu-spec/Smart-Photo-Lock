import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/ui/screens/security/security_screen.dart';

/// Phase 4 UX: the Security tab distinguishes a first-install protection
/// setup (capabilities NEVER granted) from a revocation (previously
/// granted, now missing), and shows a ready state when all three
/// capabilities are granted.
void main() {
  Future<AppContainer> pumpSecurity(
    WidgetTester tester, {
    required bool usage,
    required bool accessibility,
    required bool overlay,
    bool configured = false,
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
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
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  }

  testWidgets('fresh install shows required shield and detector setup',
      (WidgetTester tester) async {
    await pumpSecurity(
      tester,
      usage: false,
      accessibility: false,
      overlay: false,
    );

    expect(find.text(SecurityScreen.setupRequiredTitle), findsOneWidget);
    expect(find.text(SecurityScreen.setupRequiredMessage), findsOneWidget);
    expect(find.textContaining('Accessibility required'), findsOneWidget);
    expect(find.textContaining('Shield required'), findsOneWidget);
    expect(find.text(SecurityScreen.revokedTitle), findsNothing);
    expect(find.text(SecurityScreen.protectionReadyTitle), findsNothing);
  });

  testWidgets('one detector still requires the shield',
      (WidgetTester tester) async {
    await pumpSecurity(
      tester,
      usage: true,
      accessibility: false,
      overlay: false,
    );

    expect(find.text(SecurityScreen.setupRequiredTitle), findsOneWidget);
    expect(find.textContaining('Accessibility required'), findsOneWidget);
    expect(find.textContaining('Shield required'), findsOneWidget);
    expect(find.text(SecurityScreen.revokedTitle), findsNothing);
  });

  testWidgets('both detectors still require the shield',
      (WidgetTester tester) async {
    await pumpSecurity(
      tester,
      usage: true,
      accessibility: true,
      overlay: false,
    );

    expect(find.text(SecurityScreen.setupRequiredTitle), findsOneWidget);
    expect(find.textContaining('Early detection ready'), findsOneWidget);
    expect(find.textContaining('Shield required'), findsOneWidget);
    expect(find.text(SecurityScreen.revokedTitle), findsNothing);
  });

  testWidgets('all granted: ready state, no setup warning',
      (WidgetTester tester) async {
    await pumpSecurity(
      tester,
      usage: true,
      accessibility: true,
      overlay: true,
    );

    expect(find.text('Capability setup ready'), findsOneWidget);
    expect(find.text(SecurityScreen.setupRequiredTitle), findsNothing);
    expect(find.text(SecurityScreen.revokedTitle), findsNothing);
  });

  testWidgets('active protection never also reports incomplete setup',
      (WidgetTester tester) async {
    await pumpSecurity(
      tester,
      usage: true,
      accessibility: true,
      overlay: true,
      configured: true,
    );

    expect(find.text('Protection engine active'), findsOneWidget);
    expect(find.text('Protection is not fully set up'), findsNothing);
    expect(find.text('Capability setup ready'), findsNothing);
  });

  testWidgets('configured usage-only protection reports delayed detection',
      (WidgetTester tester) async {
    await pumpSecurity(
      tester,
      usage: true,
      accessibility: false,
      overlay: true,
      configured: true,
    );

    expect(
      find.text('Protection limited by delayed detection'),
      findsOneWidget,
    );
    expect(find.textContaining('cannot guarantee flash-free'), findsOneWidget);
    expect(find.text('Protection engine active'), findsNothing);
  });

  testWidgets('losing Usage recovery remains protected by Accessibility',
      (WidgetTester tester) async {
    final AppContainer container = await pumpSecurity(
      tester,
      usage: true,
      accessibility: true,
      overlay: true,
    );
    expect(find.text('Capability setup ready'), findsOneWidget);

    (container.installedAppsService as StaticInstalledAppsService)
        .usageAccessGranted = false;
    await resumeFromSettings(tester);

    expect(find.text(SecurityScreen.revokedTitle), findsNothing);
    expect(find.text('Capability setup ready'), findsOneWidget);
    expect(find.text(SecurityScreen.setupRequiredTitle), findsNothing);
  });

  testWidgets(
      'usage-only restoration stays limited until Accessibility returns',
      (WidgetTester tester) async {
    final AppContainer container = await pumpSecurity(
      tester,
      usage: true,
      accessibility: true,
      overlay: true,
    );
    (container.installedAppsService as StaticInstalledAppsService)
        .usageAccessGranted = false;
    (container.accessibility as StaticAccessibilityLockService).enabled = false;
    await resumeFromSettings(tester);
    expect(find.text(SecurityScreen.revokedTitle), findsOneWidget);

    (container.installedAppsService as StaticInstalledAppsService)
        .usageAccessGranted = true;
    await resumeFromSettings(tester);

    expect(find.text(SecurityScreen.revokedTitle), findsOneWidget);
    expect(find.text('Capability setup ready'), findsNothing);

    (container.accessibility as StaticAccessibilityLockService).enabled = true;
    await resumeFromSettings(tester);

    expect(find.text(SecurityScreen.revokedTitle), findsNothing);
    expect(find.text('Capability setup ready'), findsOneWidget);
  });

  testWidgets('revoked required shield takes precedence over setup',
      (WidgetTester tester) async {
    final AppContainer container = await pumpSecurity(
      tester,
      usage: true,
      accessibility: true,
      overlay: true,
    );
    (container.overlay as StaticOverlayLockService).overlayGranted = false;
    await resumeFromSettings(tester);

    expect(find.text(SecurityScreen.revokedTitle), findsOneWidget);
    expect(find.text(SecurityScreen.setupRequiredTitle), findsNothing);
  });
}
