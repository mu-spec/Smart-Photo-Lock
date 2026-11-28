// Guided permission setup and troubleshooting (Easy Permission Setup).
//
// SIMULATED (host widget tests; Android capability state comes from the
// static platform services). Not device QA.
//
//  G1–G4  one central step: progress, completed items, ONE current item and
//         ONE main action; the next Android screen is never opened without
//         a new tap; status only from Android reads.
//  G5–G7  return from Android settings comes back to the hub; first
//         not-enabled return shows no warning; repeated returns show short
//         help; Restricted Settings help only behind "Help" and only on
//         Android 13+ (or unknown SDK); App info via the allowlisted target.
//  G8     an explicit decline (Not now) is respected: no troubleshooting.
//  G9     unknown status is never "Enabled".
//  G10    Android settings launch unavailable is reported as such.
//  G11    dedicated screens opened outside guided setup are unchanged.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/router.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/watcher_service.dart';
import 'package:smart_app_lock/ui/screens/onboarding/onboarding_permissions_step.dart';
import 'package:smart_app_lock/ui/screens/permissions/accessibility_setup_screen.dart';
import 'package:smart_app_lock/ui/screens/permissions/overlay_setup_screen.dart';
import 'package:smart_app_lock/ui/screens/permissions/usage_access_screen.dart';
import 'package:smart_app_lock/utilities/result.dart';

typedef _S = OnboardingPermissionsStep;

class _FailingA11y extends StaticAccessibilityLockService {
  @override
  Future<Result<void>> requestServiceEnable() async {
    requestServiceEnableCalls++;
    return Result.failure(StateError('no settings activity'));
  }
}

class _FailingOverlay extends StaticOverlayLockService {
  @override
  Future<Result<void>> requestOverlayPermission() async {
    requestCalls++;
    return Result.failure(StateError('no settings activity'));
  }
}

class _FailingUsage extends StaticInstalledAppsService {
  _FailingUsage() : super(const <AppEntry>[], usageAccessGranted: false);
  @override
  Future<Result<void>> requestUsageAccess() async {
    requestUsageAccessCalls++;
    return Result.failure(StateError('no settings activity'));
  }
}

void main() {
  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  AppContainer newContainer({
    bool accessibility = false,
    bool overlay = false,
    bool usage = false,
  }) =>
      AppContainer.inMemory(
        accessibilityEnabled: accessibility,
        overlayGranted: overlay,
        usageAccessGranted: usage,
      );

  StaticAccessibilityLockService a11y(AppContainer c) =>
      c.accessibility as StaticAccessibilityLockService;
  StaticOverlayLockService overlayOf(AppContainer c) =>
      c.overlay as StaticOverlayLockService;
  StaticInstalledAppsService usageOf(AppContainer c) =>
      c.installedAppsService as StaticInstalledAppsService;
  StaticWatcherService watcherOf(AppContainer c) =>
      c.watcher as StaticWatcherService;

  Future<void> pumpHub(WidgetTester tester, AppContainer c) async {
    tallView(tester);
    await tester.pumpWidget(AppScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark,
        onGenerateRoute: AppRouter.onGenerateRoute,
        home: Scaffold(body: OnboardingPermissionsStep(onContinue: () {})),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final Finder f = find.byKey(Key(key));
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  /// The user leaves for Android settings, then comes back.
  Future<void> leaveAndReturn(WidgetTester tester,
      {VoidCallback? whileAway}) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    whileAway?.call();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  }

  String currentTitle(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const Key('onboarding_current_step_title')))
      .data!;

  String actionLabel(WidgetTester tester) => tester
      .widget<Text>(find.descendant(
        of: find.byKey(const Key('onboarding_current_action')),
        matching: find.byType(Text),
      ))
      .data!;

  /// Allow → (Accessibility disclosure) Agree → Android → back.
  Future<void> attemptAccessibility(WidgetTester tester, AppContainer c,
      {bool grant = false}) async {
    await tapKey(tester, 'onboarding_current_action');
    expect(find.byType(AccessibilitySetupScreen), findsOneWidget);
    expect(find.text(AccessibilitySetupScreen.disclosureTitle), findsOneWidget);
    final int before = a11y(c).requestServiceEnableCalls;
    await tapKey(tester, 'accessibility_open_settings');
    expect(a11y(c).requestServiceEnableCalls, before + 1);
    await leaveAndReturn(tester,
        whileAway: grant ? () => a11y(c).enabled = true : null);
  }

  group('G guided central step', () {
    testWidgets(
        'G1 nothing granted: title, progress, ONE current item (Accessibility) '
        'with one main action; nothing opened automatically',
        (WidgetTester tester) async {
      final AppContainer c = newContainer();
      // "Nothing granted" includes the optional notification permission.
      watcherOf(c).notificationPermissionGranted = false;
      await pumpHub(tester, c);
      expect(find.text(_S.title), findsOneWidget);
      expect(find.text('Set Up Protection'), findsOneWidget);
      expect(find.text(_S.progressLabel(0, 2)), findsOneWidget);
      expect(find.byKey(const Key('onboarding_current_step')), findsOneWidget);
      expect(find.text(_S.stepLabel(1, 2)), findsOneWidget);
      expect(currentTitle(tester), 'Accessibility service');
      expect(actionLabel(tester), _S.allowLabel);
      expect(find.byKey(const Key('onboarding_current_action')),
          findsOneWidget);
      expect(find.byKey(const Key('onboarding_not_enabled_help')),
          findsNothing);
      expect(find.byKey(const Key('onboarding_setup_help')), findsNothing);
      expect(find.text(_S.enabledLabel), findsNothing);
      expect(a11y(c).requestServiceEnableCalls, 0);
      expect(overlayOf(c).requestCalls, 0);
      expect(usageOf(c).requestUsageAccessCalls, 0);
      expect(watcherOf(c).openedSettings, isEmpty);
    });

    testWidgets('G2 completed items are marked; the next missing one is current',
        (WidgetTester tester) async {
      await pumpHub(tester, newContainer(accessibility: true));
      expect(find.text(_S.progressLabel(1, 2)), findsOneWidget);
      expect(find.text(_S.stepLabel(2, 2)), findsOneWidget);
      expect(currentTitle(tester), 'Draw over apps');
      expect(
        find.descendant(
          of: find.byKey(const Key('onboarding_perm_accessibility')),
          matching: find.text(_S.enabledLabel),
        ),
        findsOneWidget,
      );
    });

    testWidgets(
        'G3 Usage access is current only after the required items and is '
        'marked Recommended; skipping stays possible',
        (WidgetTester tester) async {
      await pumpHub(tester, newContainer(accessibility: true, overlay: true));
      expect(currentTitle(tester), 'Usage access');
      // Required items complete: progress is full and Usage access is an
      // extra (recommended) step, never "Step 3 of 3".
      expect(find.text(_S.progressLabel(2, 2)), findsOneWidget);
      expect(find.text(_S.extraStepLabel), findsOneWidget);
      expect(find.textContaining('of 3'), findsNothing);
      expect(find.text(_S.incompleteNote), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('onboarding_perm_usage')),
          matching: find.text(_S.notEnabledRecommendedLabel),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('onboarding_current_step')),
          matching: find.text(_S.recommendedTag),
        ),
        findsOneWidget,
      );
      expect(find.text(_S.continueLabel), findsOneWidget);
      expect(find.textContaining('Protection Active'), findsNothing);
    });

    testWidgets(
        'G4 all allowed: no current action, honest all-set card, never '
        '"Protection Active"', (WidgetTester tester) async {
      await pumpHub(
          tester, newContainer(accessibility: true, overlay: true, usage: true));
      expect(find.byKey(const Key('onboarding_current_step')), findsNothing);
      expect(find.byKey(const Key('onboarding_setup_complete')), findsOneWidget);
      expect(find.text(_S.progressLabel(2, 2)), findsOneWidget);
      expect(find.textContaining('Protection Active'), findsNothing);
      expect(find.textContaining('Protected'), findsNothing);
      expect(find.text(_S.continueLabel), findsOneWidget);
    });
  });

  group('G return from Android settings and troubleshooting', () {
    testWidgets(
        'G5 grant: disclosure + Agree precede the hand-off; on return the '
        'flow comes back to the hub, which shows the next item without '
        'opening it', (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await pumpHub(tester, c);
      await tapKey(tester, 'onboarding_current_action');
      expect(find.byType(AccessibilitySetupScreen), findsOneWidget);
      expect(find.byKey(const Key('accessibility_consent_question')),
          findsOneWidget);
      expect(a11y(c).requestServiceEnableCalls, 0,
          reason: 'disclosure precedes any Android hand-off');
      await tapKey(tester, 'accessibility_open_settings');
      expect(a11y(c).requestServiceEnableCalls, 1);
      await leaveAndReturn(tester, whileAway: () => a11y(c).enabled = true);

      expect(find.byType(AccessibilitySetupScreen), findsNothing,
          reason: 'no extra confirmation screen');
      expect(find.text(AccessibilitySetupScreen.enabledTitle), findsNothing);
      expect(currentTitle(tester), 'Draw over apps');
      expect(find.text(_S.progressLabel(1, 2)), findsOneWidget);
      expect(actionLabel(tester), _S.allowLabel);
      expect(overlayOf(c).requestCalls, 0,
          reason: 'next Android screen needs a new tap');
      expect(find.byKey(const Key('onboarding_not_enabled_help')),
          findsNothing);
    });

    testWidgets(
        'G6 not granted: first return shows no warning ("Try Again" only); '
        'second shows short help; Help reveals Restricted Settings guidance '
        'and App info; nothing is granted', (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await pumpHub(tester, c);

      await attemptAccessibility(tester, c);
      expect(find.byType(AccessibilitySetupScreen), findsNothing,
          reason: 'returns to the hub after the Android hand-off');
      expect(currentTitle(tester), 'Accessibility service');
      expect(actionLabel(tester), _S.tryAgainLabel);
      expect(find.byKey(const Key('onboarding_not_enabled_help')),
          findsNothing, reason: 'no warning after a first decline');
      expect(find.byKey(const Key('onboarding_setup_help_toggle')),
          findsNothing);

      await attemptAccessibility(tester, c);
      expect(find.byKey(const Key('onboarding_not_enabled_help')),
          findsOneWidget);
      expect(find.text(_S.notEnabledTitle), findsOneWidget);
      expect(find.text(_S.notEnabledMessage), findsOneWidget);
      expect(find.byKey(const Key('onboarding_setup_help')), findsNothing,
          reason: 'Restricted Settings help is never shown automatically');
      expect(find.byKey(const Key('onboarding_restricted_help')),
          findsNothing);

      await tapKey(tester, 'onboarding_setup_help_toggle');
      expect(find.byKey(const Key('onboarding_setup_help')), findsOneWidget);
      expect(find.text(_S.helpGeneral['accessibility']!), findsOneWidget);
      expect(find.text(_S.restrictedHeading), findsOneWidget);
      expect(find.text(_S.restrictedSteps), findsOneWidget);
      expect(find.text(_S.restrictedTrust), findsOneWidget);
      expect(find.text(_S.restrictedAlternative), findsOneWidget);
      expect(watcherOf(c).openedSettings, isEmpty);

      await tapKey(tester, 'onboarding_open_app_info');
      expect(watcherOf(c).openedSettings,
          <ProtectionSettingsTarget>[ProtectionSettingsTarget.appDetails]);
      expect(find.byKey(const Key('onboarding_help_message')), findsNothing);
      expect(a11y(c).enabled, isFalse, reason: 'setup never grants');
      expect(a11y(c).requestServiceEnableCalls, 2,
          reason: 'no automatic re-launch');

      // A real grant afterwards clears the help and moves on.
      await attemptAccessibility(tester, c, grant: true);
      expect(currentTitle(tester), 'Draw over apps');
      expect(find.byKey(const Key('onboarding_not_enabled_help')),
          findsNothing);
      expect(actionLabel(tester), _S.allowLabel);
    });

    testWidgets(
        'G7 Android 12 (SDK 31): help has no Restricted Settings section; '
        'App info failure is reported', (WidgetTester tester) async {
      final AppContainer c = newContainer();
      watcherOf(c).sdkInt = 31;
      await pumpHub(tester, c);
      await attemptAccessibility(tester, c);
      await attemptAccessibility(tester, c);
      await tapKey(tester, 'onboarding_setup_help_toggle');
      expect(find.byKey(const Key('onboarding_setup_help')), findsOneWidget);
      expect(find.byKey(const Key('onboarding_restricted_help')),
          findsNothing);
      expect(find.byKey(const Key('onboarding_open_app_info')), findsNothing);
    });

    testWidgets('G7b App info could not be opened: short manual instruction',
        (WidgetTester tester) async {
      final AppContainer c = newContainer();
      watcherOf(c).sdkInt = 34;
      watcherOf(c).settingsOpenResult = false;
      await pumpHub(tester, c);
      await attemptAccessibility(tester, c);
      await attemptAccessibility(tester, c);
      await tapKey(tester, 'onboarding_setup_help_toggle');
      await tapKey(tester, 'onboarding_open_app_info');
      expect(find.text(_S.appInfoOpenFailedMessage), findsOneWidget);
    });

    testWidgets(
        'G8 an explicit "Not now" is respected: no warning, no help, '
        'nothing opened', (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await pumpHub(tester, c);
      for (int i = 0; i < 3; i++) {
        await tapKey(tester, 'onboarding_current_action');
        await tapKey(tester, 'accessibility_decline');
        expect(find.byType(AccessibilitySetupScreen), findsNothing);
      }
      expect(actionLabel(tester), _S.allowLabel);
      expect(find.byKey(const Key('onboarding_not_enabled_help')),
          findsNothing);
      expect(a11y(c).requestServiceEnableCalls, 0);
      expect(watcherOf(c).openedSettings, isEmpty);
      expect(find.text(_S.skipLabel), findsOneWidget);
    });

    testWidgets(
        'G8b overlay and usage flows also return to the hub after the '
        'Android hand-off', (WidgetTester tester) async {
      final AppContainer c = newContainer(accessibility: true);
      await pumpHub(tester, c);
      await tapKey(tester, 'onboarding_current_action');
      expect(find.byType(OverlaySetupScreen), findsOneWidget);
      await tester.tap(find.text(OverlaySetupScreen.openSettingsLabel));
      await tester.pumpAndSettle();
      expect(overlayOf(c).requestCalls, 1);
      await leaveAndReturn(tester,
          whileAway: () => overlayOf(c).overlayGranted = true);
      expect(find.byType(OverlaySetupScreen), findsNothing);
      expect(currentTitle(tester), 'Usage access');
      expect(usageOf(c).requestUsageAccessCalls, 0);

      await tapKey(tester, 'onboarding_current_action');
      expect(find.byType(UsageAccessScreen), findsOneWidget);
      await tester.tap(find.text(UsageAccessScreen.openSettingsLabel));
      await tester.pumpAndSettle();
      await leaveAndReturn(tester,
          whileAway: () => usageOf(c).usageAccessGranted = true);
      expect(find.byType(UsageAccessScreen), findsNothing);
      expect(find.byKey(const Key('onboarding_setup_complete')), findsOneWidget);
    });
  });

  group('G status and launch failures', () {
    testWidgets('G9 unknown status: "Couldn\'t check", never Enabled; Check again',
        (WidgetTester tester) async {
      tallView(tester);
      await tester.pumpWidget(AppScope(
        container: newContainer(),
        child: MaterialApp(
          onGenerateRoute: AppRouter.onGenerateRoute,
          home: Scaffold(
            body: OnboardingPermissionsStep(
              onContinue: () {},
              probes: <String, OnboardingPermissionProbe>{
                'accessibility': () async => Result.failure(StateError('x')),
              },
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('onboarding_current_unknown')),
          findsOneWidget);
      expect(find.byKey(const Key('onboarding_current_check_again')),
          findsOneWidget);
      expect(find.text(_S.enabledLabel), findsNothing);
      expect(find.text(_S.progressLabel(0, 2)), findsOneWidget);
    });

    Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
      tallView(tester);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const Key('open'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<bool>(builder: (_) => screen),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'G10 settings launch unavailable is shown as such (not "could not '
        'check"), and guided mode stays on the screen',
        (WidgetTester tester) async {
      final _FailingA11y a = _FailingA11y();
      await pumpScreen(
          tester, AccessibilitySetupScreen(service: a, returnToSetup: true));
      await tapKey(tester, 'accessibility_open_settings');
      expect(a.requestServiceEnableCalls, 1);
      expect(find.text(AccessibilitySetupScreen.launchFailedTitle),
          findsOneWidget);
      expect(find.text(AccessibilitySetupScreen.launchFailedMessage),
          findsOneWidget);
      expect(find.text(AccessibilitySetupScreen.unavailableTitle),
          findsNothing);
      await leaveAndReturn(tester);
      expect(find.byType(AccessibilitySetupScreen), findsOneWidget);
    });

    testWidgets('G10b overlay launch failure', (WidgetTester tester) async {
      final _FailingOverlay o = _FailingOverlay();
      await pumpScreen(tester, OverlaySetupScreen(service: o));
      await tester.tap(find.text(OverlaySetupScreen.openSettingsLabel));
      await tester.pumpAndSettle();
      expect(o.requestCalls, 1);
      expect(find.text(OverlaySetupScreen.launchFailedTitle), findsOneWidget);
      expect(find.text(OverlaySetupScreen.unavailableTitle), findsNothing);
    });

    testWidgets('G10c usage launch failure', (WidgetTester tester) async {
      final _FailingUsage u = _FailingUsage();
      await pumpScreen(tester, UsageAccessScreen(service: u));
      await tester.tap(find.text(UsageAccessScreen.openSettingsLabel));
      await tester.pumpAndSettle();
      expect(u.requestUsageAccessCalls, 1);
      expect(find.text(UsageAccessScreen.launchFailedTitle), findsOneWidget);
      expect(find.text(UsageAccessScreen.unavailableTitle), findsNothing);
    });

    testWidgets(
        'G11 outside guided setup the dedicated screen is unchanged: after a '
        'grant it shows its enabled view and Done',
        (WidgetTester tester) async {
      final StaticAccessibilityLockService a =
          StaticAccessibilityLockService();
      await pumpScreen(tester, AccessibilitySetupScreen(service: a));
      await tapKey(tester, 'accessibility_open_settings');
      await leaveAndReturn(tester, whileAway: () => a.enabled = true);
      expect(find.byType(AccessibilitySetupScreen), findsOneWidget);
      expect(find.text(AccessibilitySetupScreen.enabledTitle), findsOneWidget);
      expect(find.text(AccessibilitySetupScreen.doneLabel), findsOneWidget);
    });
  });
}
