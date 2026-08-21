import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
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
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final AppContainer container = AppContainer.inMemory(
      usageAccessGranted: usage,
      accessibilityEnabled: accessibility,
      overlayGranted: overlay,
    );
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

  testWidgets(
      'fresh install: setup banner with 0 of 3, never a revocation warning',
      (WidgetTester tester) async {
    await pumpSecurity(
      tester,
      usage: false,
      accessibility: false,
      overlay: false,
    );

    expect(find.text(SecurityScreen.setupRequiredTitle), findsOneWidget);
    expect(find.text(SecurityScreen.setupRequiredMessage), findsOneWidget);
    expect(find.text(SecurityScreen.readyCount(0)), findsOneWidget);
    expect(find.text(SecurityScreen.revokedTitle), findsNothing);
    expect(find.text(SecurityScreen.protectionReadyTitle), findsNothing);
  });

  testWidgets('one capability granted shows 1 of 3 ready',
      (WidgetTester tester) async {
    await pumpSecurity(
      tester,
      usage: true,
      accessibility: false,
      overlay: false,
    );

    expect(find.text(SecurityScreen.setupRequiredTitle), findsOneWidget);
    expect(find.text(SecurityScreen.readyCount(1)), findsOneWidget);
    expect(find.text(SecurityScreen.revokedTitle), findsNothing);
  });

  testWidgets('two capabilities granted show 2 of 3 ready',
      (WidgetTester tester) async {
    await pumpSecurity(
      tester,
      usage: true,
      accessibility: true,
      overlay: false,
    );

    expect(find.text(SecurityScreen.setupRequiredTitle), findsOneWidget);
    expect(find.text(SecurityScreen.readyCount(2)), findsOneWidget);
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

    expect(find.text(SecurityScreen.protectionReadyTitle), findsOneWidget);
    expect(find.text(SecurityScreen.protectionReadyMessage), findsOneWidget);
    expect(find.text(SecurityScreen.setupRequiredTitle), findsNothing);
    expect(find.text(SecurityScreen.revokedTitle), findsNothing);
  });

  testWidgets('previously granted then disabled: revocation, not setup',
      (WidgetTester tester) async {
    final AppContainer container = await pumpSecurity(
      tester,
      usage: true,
      accessibility: true,
      overlay: true,
    );
    expect(find.text(SecurityScreen.protectionReadyTitle), findsOneWidget);

    (container.installedAppsService as StaticInstalledAppsService)
        .usageAccessGranted = false;
    await resumeFromSettings(tester);

    expect(find.text(SecurityScreen.revokedTitle), findsOneWidget);
    expect(find.text(SecurityScreen.setupRequiredTitle), findsNothing);
  });

  testWidgets('restore all: warning clears and ready state returns',
      (WidgetTester tester) async {
    final AppContainer container = await pumpSecurity(
      tester,
      usage: true,
      accessibility: true,
      overlay: true,
    );
    (container.installedAppsService as StaticInstalledAppsService)
        .usageAccessGranted = false;
    await resumeFromSettings(tester);
    expect(find.text(SecurityScreen.revokedTitle), findsOneWidget);

    (container.installedAppsService as StaticInstalledAppsService)
        .usageAccessGranted = true;
    await resumeFromSettings(tester);

    expect(find.text(SecurityScreen.revokedTitle), findsNothing);
    expect(find.text(SecurityScreen.protectionReadyTitle), findsOneWidget);
  });

  testWidgets('revocation takes precedence over setup in a mixed state',
      (WidgetTester tester) async {
    final AppContainer container = await pumpSecurity(
      tester,
      usage: true,
      accessibility: true,
      overlay: true,
    );
    (container.accessibility as StaticAccessibilityLockService).enabled =
        false;
    await resumeFromSettings(tester);

    expect(find.text(SecurityScreen.revokedTitle), findsOneWidget);
    expect(find.text(SecurityScreen.setupRequiredTitle), findsNothing);
  });
}
