// Phase 19 / M1 — Accessibility prominent disclosure and consent.
//
// Host/widget tests (simulated). Android's own Accessibility switch and
// the Restricted Settings behaviour are device/Play-track QA only.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/router.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/ui/screens/onboarding/onboarding_permissions_step.dart';
import 'package:smart_app_lock/ui/screens/permissions/accessibility_setup_screen.dart';

typedef _S = AccessibilitySetupScreen;

void main() {
  /// Pushes the disclosure screen over a host page so pop results are seen.
  Future<({StaticAccessibilityLockService service, List<Object?> results})>
      pushScreen(WidgetTester tester, {bool enabled = false}) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final StaticAccessibilityLockService service =
        StaticAccessibilityLockService(enabled: enabled);
    final List<Object?> results = <Object?>[];
    await tester.pumpWidget(AppScope(
      container: AppContainer.inMemory(accessibilityEnabled: enabled),
      child: MaterialApp(
        theme: AppTheme.dark,
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => results.add(
                  await Navigator.of(context).push<Object?>(
                    MaterialPageRoute<Object?>(
                      builder: (_) => AccessibilitySetupScreen(service: service),
                    ),
                  ),
                ),
                child: const Text('host_open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('host_open'));
    await tester.pumpAndSettle();
    return (service: service, results: results);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final Finder f = find.byKey(Key(key));
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  group('P19-M1 disclosure content and placement', () {
    testWidgets(
        'D1 the full disclosure and an Agree / Not now pair are shown BEFORE '
        'any Android settings request', (WidgetTester tester) async {
      final r = await pushScreen(tester);
      expect(find.text(_S.disclosureTitle), findsOneWidget);
      expect(find.text(_S.disclosureBody), findsOneWidget);
      expect(find.text(_S.disclosureNever), findsOneWidget);
      expect(find.text(_S.notUsedElsewhere), findsOneWidget);
      expect(find.byKey(const Key('accessibility_consent_question')),
          findsOneWidget);
      expect(find.text(_S.openSettingsLabel), findsOneWidget);
      expect(find.text(_S.declineLabel), findsOneWidget);
      expect(_S.openSettingsLabel, 'Agree');
      expect(_S.declineLabel, 'Not now');
      // Nothing was requested just by showing the disclosure.
      expect(r.service.requestServiceEnableCalls, 0);
      expect(r.service.enabled, isFalse);
    });

    test('D2 wording matches the verified service behaviour', () {
      // What is accessed (config: typeWindowStateChanged, no window content;
      // service: event package name + window class only).
      expect(_S.disclosureBody, contains('Accessibility service'));
      expect(_S.disclosureBody, contains('package name'));
      expect(_S.disclosureBody, contains('window type'));
      expect(_S.disclosureBody, contains('even when Smart App Lock is closed'));
      // How it is used, and the fallback when declined.
      expect(_S.disclosureBody, contains('protected apps on this phone'));
      expect(_S.disclosureBody, contains('Usage access'));
      // Not read / not acted / not transmitted or shared; what is stored.
      expect(_S.disclosureNever, contains('does not read the text'));
      expect(_S.disclosureNever, contains('does not tap, type or act'));
      expect(_S.disclosureNever, contains('never leaves your phone'));
      expect(_S.disclosureNever, contains('not shared'));
      expect(_S.disclosureNever, contains('encrypted security records'));
      // No misleading permission or security claims.
      for (final String t in <String>[
        _S.disclosureBody,
        _S.disclosureNever,
        _S.settingsNote,
        _S.consentQuestion,
      ]) {
        expect(t.toLowerCase(), isNot(contains('100%')));
        expect(t.toLowerCase(), isNot(contains('required for security')));
        expect(t.toLowerCase(), isNot(contains('automatically')));
      }
    });

    testWidgets('D3 once enabled, the disclosure/consent is not shown again',
        (WidgetTester tester) async {
      await pushScreen(tester, enabled: true);
      expect(find.text(_S.enabledTitle), findsOneWidget);
      expect(find.text(_S.disclosureBody), findsNothing);
      expect(find.byKey(const Key('accessibility_consent_question')),
          findsNothing);
      expect(find.text(_S.declineLabel), findsNothing);
    });
  });

  group('P19-M1 consent behaviour', () {
    testWidgets(
        'C1 Agree is the consent; only then is the existing Android '
        'hand-off called, and nothing is enabled by the app',
        (WidgetTester tester) async {
      final r = await pushScreen(tester);
      await tapKey(tester, 'accessibility_open_settings');
      expect(r.service.requestServiceEnableCalls, 1);
      expect(r.service.enabled, isFalse,
          reason: 'only the user can turn it on in Android');
      expect(find.text(_S.notEnabledTitle), findsOneWidget);

      // The user really enables it in Android, then returns.
      r.service.enabled = true;
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
      expect(find.text(_S.enabledTitle), findsOneWidget);
    });

    testWidgets('C2 Not now declines: closes, opens nothing, enables nothing',
        (WidgetTester tester) async {
      final r = await pushScreen(tester);
      await tapKey(tester, 'accessibility_decline');
      expect(find.byType(AccessibilitySetupScreen), findsNothing);
      expect(r.results, <Object?>[false]);
      expect(r.service.requestServiceEnableCalls, 0);
      expect(r.service.enabled, isFalse);
    });

    testWidgets('C3 navigating away (Back) is never treated as consent',
        (WidgetTester tester) async {
      final r = await pushScreen(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AccessibilitySetupScreen), findsNothing);
      expect(r.service.requestServiceEnableCalls, 0);
      expect(r.service.enabled, isFalse);
    });

    testWidgets('C4 after declining, the disclosure can be opened again',
        (WidgetTester tester) async {
      final r = await pushScreen(tester);
      await tapKey(tester, 'accessibility_decline');
      await tester.tap(find.text('host_open'));
      await tester.pumpAndSettle();
      expect(find.text(_S.disclosureBody), findsOneWidget);
      await tapKey(tester, 'accessibility_open_settings');
      expect(r.service.requestServiceEnableCalls, 1);
    });
  });

  group('P19-M1 onboarding permission step (existing flow)', () {
    testWidgets(
        'O1 the Accessibility row opens the disclosure first; Not now '
        'returns to the step as Required; no other permission is requested',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final AppContainer c = AppContainer.inMemory();
      final StaticAccessibilityLockService a11y =
          c.accessibility as StaticAccessibilityLockService;
      final StaticOverlayLockService overlay =
          c.overlay as StaticOverlayLockService;
      final StaticInstalledAppsService usage =
          c.installedAppsService as StaticInstalledAppsService;
      final StaticWatcherService watcher = c.watcher as StaticWatcherService;
      final bool usageBefore = usage.usageAccessGranted;
      int continued = 0;
      await tester.pumpWidget(AppScope(
        container: c,
        child: MaterialApp(
          onGenerateRoute: AppRouter.onGenerateRoute,
          home: Scaffold(
            body: OnboardingPermissionsStep(onContinue: () => continued++),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final Finder row = find.byKey(const Key('onboarding_perm_accessibility'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();

      expect(find.byType(AccessibilitySetupScreen), findsOneWidget);
      expect(find.text(_S.disclosureBody), findsOneWidget);
      expect(a11y.requestServiceEnableCalls, 0,
          reason: 'disclosure precedes any Android hand-off');

      await tapKey(tester, 'accessibility_decline');
      expect(find.byType(AccessibilitySetupScreen), findsNothing);
      expect(find.text(OnboardingPermissionsStep.title), findsOneWidget);
      expect(
        find.descendant(
          of: row,
          matching: find.text(OnboardingPermissionsStep.notEnabledRequiredLabel),
        ),
        findsOneWidget,
      );
      expect(a11y.requestServiceEnableCalls, 0);
      expect(a11y.enabled, isFalse);
      expect(overlay.requestCalls, 0);
      expect(usage.usageAccessGranted, usageBefore);
      expect(watcher.openedSettings, isEmpty);
      expect(continued, 0, reason: 'declining does not advance onboarding');
      // The user may still continue without Accessibility (existing path).
      expect(find.text(OnboardingPermissionsStep.skipLabel), findsOneWidget);
    });
  });
}
