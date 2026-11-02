// Phase 7 / M3 — Health Refresh & Regression.
//
// SIMULATED: production Home / details widgets, router, Phase 7 / M1
// engine + monitor and the in-memory container's static services, driven
// through Flutter's app-lifecycle events (legal transitions only). "Leaving
// for Android Settings" is the lifecycle ladder resumed → inactive → hidden
// → paused and back; the "manual revocation" is a change to the simulated
// Android input while the app is away. No Android Settings screen, OEM
// behaviour or real permission change is observed: physical-device QA is
// pending (docs/regression.md, combined Phase 6 + Phase 7 round).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/router.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/protection/health/protection_health_engine.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/security/credentials/biometric_options.dart';
import 'package:smart_app_lock/services/biometric_service.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/ui/screens/health/health_presentation.dart';
import 'package:smart_app_lock/ui/screens/health/health_resume_trigger.dart';
import 'package:smart_app_lock/ui/screens/health/protection_health_controller.dart';
import 'package:smart_app_lock/ui/screens/health/protection_health_screen.dart';
import 'package:smart_app_lock/ui/screens/home/home_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/utilities/result.dart';

const String _pkg = 'com.example.private';

class _Bio implements BiometricService {
  bool hardware = true;
  bool enrolled = true;
  int authenticateCalls = 0;

  @override
  Future<Result<bool>> isSupported() async => Result.success(hardware);

  @override
  Future<Result<Set<BiometricKind>>> availableKinds() async =>
      Result.success(<BiometricKind>{if (enrolled) BiometricKind.strong});

  @override
  Future<Result<bool>> authenticate({
    required String reason,
    BiometricOptions? options,
  }) async {
    authenticateCalls++;
    return Result.success(false);
  }
}

class _Fx {
  _Fx(this.container, this.bio);

  final AppContainer container;
  final _Bio bio;

  StaticWatcherService get watcher => container.watcher as StaticWatcherService;
  StaticOverlayLockService get overlay =>
      container.overlay as StaticOverlayLockService;
  StaticAccessibilityLockService get accessibility =>
      container.accessibility as StaticAccessibilityLockService;
  StaticInstalledAppsService get installed =>
      container.installedAppsService as StaticInstalledAppsService;
  DefaultAccessController get access =>
      container.accessController as DefaultAccessController;

  ProtectionHealthReport get latest => container.protectionHealth.latest()!;

  /// A healthy simulated device; every capability was granted before, so
  /// a later "off" reads as revoked (grant history), not as setup.
  static Future<_Fx> create({bool pin = true}) async {
    final _Bio bio = _Bio();
    final AppContainer c = AppContainer.inMemory(
      biometrics: bio,
      accessibilityEnabled: true,
      overlayGranted: true,
    );
    if (pin) await c.auth.enrollPin('2468');
    await c.protectedApps.add(
      ProtectedApp(
        packageName: _pkg,
        label: 'Private',
        addedAt: DateTime(2026, 11, 1),
      ),
    );
    for (final String kind in <String>[
      'overlay',
      'accessibility',
      'usageAccess',
    ]) {
      await c.preferences.markCapabilityEverGranted(kind);
    }
    (c.watcher as StaticWatcherService)
      ..protectionConfigured = pin
      ..running = true
      ..accessibilityServiceConnected = true
      ..shieldArmed = true
      ..challengePending = false
      ..backgroundRestricted = false
      ..powerSaveMode = false
      ..ignoringBatteryOptimizations = false
      ..sdkInt = 34;
    return _Fx(c, bio);
  }
}

/// Home on its own (no other tabs), so every `getHealth` call is a health
/// probe: the Security tab's existing resume synchronization would also
/// read native health and is exercised separately in the full-app tests.
Future<void> _pumpHome(
  WidgetTester tester,
  AppContainer container, {
  ValueNotifier<bool>? active,
}) async {
  tester.view.physicalSize = const Size(1080, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    AppScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light,
        onGenerateRoute: AppRouter.onGenerateRoute,
        home: Scaffold(
          body: active == null
              ? const HomeScreen()
              : ValueListenableBuilder<bool>(
                  valueListenable: active,
                  builder: (BuildContext context, bool on, Widget? _) =>
                      HomeScreen(isActive: on),
                ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Legal lifecycle transitions only (see test/ui/lock_challenge_test.dart).
class _Life {
  AppLifecycleState state = AppLifecycleState.resumed;

  Future<void> to(WidgetTester tester, AppLifecycleState next) async {
    if (state == next) return;
    tester.binding.handleAppLifecycleStateChanged(next);
    state = next;
    await tester.pump();
  }

  /// Opening Android Settings / pressing Home / screen off.
  Future<void> leave(WidgetTester tester) async {
    await to(tester, AppLifecycleState.inactive);
    await to(tester, AppLifecycleState.hidden);
    await to(tester, AppLifecycleState.paused);
  }

  /// Coming back. [settle] false keeps a gated probe observable.
  Future<void> back(WidgetTester tester, {bool settle = true}) async {
    if (state == AppLifecycleState.paused) {
      await to(tester, AppLifecycleState.hidden);
    }
    await to(tester, AppLifecycleState.inactive);
    await to(tester, AppLifecycleState.resumed);
    if (settle) await tester.pumpAndSettle();
  }

  /// Notification shade / dialog: inactive and back, without a leave.
  Future<void> shade(WidgetTester tester) async {
    await to(tester, AppLifecycleState.inactive);
    await to(tester, AppLifecycleState.resumed);
  }
}

Finder _inHome(Finder f) => find.descendant(
      of: find.byKey(const Key('home_protection_status')),
      matching: f,
    );

String? _homeTitle(WidgetTester tester) {
  for (final String t in <String>[
    HealthPresentation.secureTitle,
    HealthPresentation.attentionTitle,
    HealthPresentation.offlineTitle,
    HealthPresentation.checkingTitle,
    HealthPresentation.unavailableTitle,
  ]) {
    if (_inHome(find.text(t)).evaluate().isNotEmpty) return t;
  }
  return null;
}

String? _notice(WidgetTester tester) {
  final Finder f = find.descendant(
    of: find.byKey(const Key('health_repair_notice')),
    matching: find.byType(Text),
  );
  return f.evaluate().isEmpty ? null : tester.widget<Text>(f.first).data;
}

Future<void> _openDetailsFromHome(WidgetTester tester) async {
  final Finder fix = _inHome(find.text('Fix protection'));
  await tester.tap(
    fix.evaluate().isEmpty ? _inHome(find.text('View details')) : fix,
  );
  await tester.pumpAndSettle();
  expect(find.byType(ProtectionHealthScreen), findsOneWidget);
}

Future<void> _tapKey(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

/// One manual-revocation scenario (Phase 7 / M3 "Health Regression").
class _Scenario {
  const _Scenario(
    this.name, {
    required this.revoke,
    required this.restore,
    required this.state,
    required this.code,
    required this.category,
  });

  final String name;
  final Future<void> Function(_Fx fx) revoke;
  final Future<void> Function(_Fx fx) restore;
  final ProtectionHealthState state;
  final HealthIssueCode code;
  final HealthIssueCategory category;
}

final List<_Scenario> _scenarios = <_Scenario>[
  _Scenario(
    'overlay permission revoked',
    revoke: (_Fx fx) async => fx.overlay.overlayGranted = false,
    restore: (_Fx fx) async => fx.overlay.overlayGranted = true,
    state: ProtectionHealthState.protectionOffline,
    code: HealthIssueCode.overlayUnavailable,
    category: HealthIssueCategory.revoked,
  ),
  _Scenario(
    'Accessibility turned off (Usage Access still detects)',
    revoke: (_Fx fx) async => fx.accessibility.enabled = false,
    restore: (_Fx fx) async => fx.accessibility.enabled = true,
    state: ProtectionHealthState.attentionRequired,
    code: HealthIssueCode.accessibilityUnavailable,
    category: HealthIssueCategory.revoked,
  ),
  _Scenario(
    'Accessibility enabled but the service is not bound (rebind restores)',
    revoke: (_Fx fx) async => fx.watcher.accessibilityServiceConnected = false,
    restore: (_Fx fx) async => fx.watcher.accessibilityServiceConnected = true,
    state: ProtectionHealthState.attentionRequired,
    code: HealthIssueCode.accessibilityNotRunning,
    category: HealthIssueCategory.interrupted,
  ),
  _Scenario(
    'Usage Access revoked (Accessibility still detects)',
    revoke: (_Fx fx) async => fx.installed.usageAccessGranted = false,
    restore: (_Fx fx) async => fx.installed.usageAccessGranted = true,
    state: ProtectionHealthState.attentionRequired,
    code: HealthIssueCode.usageAccessUnavailable,
    category: HealthIssueCategory.revoked,
  ),
  _Scenario(
    'Accessibility and Usage Access both off',
    revoke: (_Fx fx) async {
      fx.accessibility.enabled = false;
      fx.installed.usageAccessGranted = false;
    },
    restore: (_Fx fx) async {
      fx.accessibility.enabled = true;
      fx.installed.usageAccessGranted = true;
    },
    state: ProtectionHealthState.protectionOffline,
    code: HealthIssueCode.detectionOffline,
    category: HealthIssueCategory.revoked,
  ),
  _Scenario(
    'notifications denied (Android 13+)',
    revoke: (_Fx fx) async => fx.watcher.notificationPermissionGranted = false,
    restore: (_Fx fx) async => fx.watcher.notificationPermissionGranted = true,
    state: ProtectionHealthState.attentionRequired,
    code: HealthIssueCode.notificationsDisabled,
    // No grant history exists for notifications: "not allowed", never a
    // claimed revocation.
    category: HealthIssueCategory.setup,
  ),
  _Scenario(
    'protection service stopped (no automatic restart)',
    revoke: (_Fx fx) async => fx.watcher.running = false,
    restore: (_Fx fx) async => fx.watcher.running = true,
    state: ProtectionHealthState.attentionRequired,
    code: HealthIssueCode.watcherNotRunning,
    category: HealthIssueCategory.interrupted,
  ),
  _Scenario(
    'Android background restriction on',
    revoke: (_Fx fx) async => fx.watcher.backgroundRestricted = true,
    restore: (_Fx fx) async => fx.watcher.backgroundRestricted = false,
    state: ProtectionHealthState.attentionRequired,
    code: HealthIssueCode.backgroundRestricted,
    category: HealthIssueCategory.restricted,
  ),
  _Scenario(
    'native enforcement not armed',
    revoke: (_Fx fx) async => fx.watcher.protectionConfigured = false,
    restore: (_Fx fx) async => fx.watcher.protectionConfigured = true,
    state: ProtectionHealthState.protectionOffline,
    code: HealthIssueCode.enforcementNotArmed,
    category: HealthIssueCategory.interrupted,
  ),
  _Scenario(
    'native health read fails',
    revoke: (_Fx fx) async => fx.watcher.getHealthError = StateError('bridge'),
    restore: (_Fx fx) async => fx.watcher.getHealthError = null,
    state: ProtectionHealthState.attentionRequired,
    code: HealthIssueCode.signalUnknown,
    category: HealthIssueCategory.uncertain,
  ),
  _Scenario(
    'last protected app removed (user choice, not a failure)',
    revoke: (_Fx fx) async => fx.container.protectedApps.remove(_pkg),
    restore: (_Fx fx) async => fx.container.protectedApps.add(
      ProtectedApp(
        packageName: _pkg,
        label: 'Private',
        addedAt: DateTime(2026, 11, 1),
      ),
    ),
    state: ProtectionHealthState.protectionOffline,
    code: HealthIssueCode.protectionNotConfigured,
    category: HealthIssueCategory.userChoice,
  ),
];

void main() {
  group('HealthResumeTrigger (unit)', () {
    late List<bool> calls;
    late HealthResumeTrigger trigger;

    setUp(() {
      calls = <bool>[];
      trigger = HealthResumeTrigger(
        onResumed: ({required bool returned}) => calls.add(returned),
      );
    });

    test('a real leave then resume reports returned: true, once', () {
      for (final AppLifecycleState s in <AppLifecycleState>[
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        trigger.didChangeAppLifecycleState(s);
      }
      expect(calls, <bool>[true]);
    });

    test('shade / dialog (inactive → resumed) reports returned: false', () {
      trigger.didChangeAppLifecycleState(AppLifecycleState.inactive);
      trigger.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(calls, <bool>[false]);
    });

    test('a repeated resumed is ignored; the leave flag is consumed', () {
      trigger
        ..didChangeAppLifecycleState(AppLifecycleState.paused)
        ..didChangeAppLifecycleState(AppLifecycleState.resumed)
        ..didChangeAppLifecycleState(AppLifecycleState.resumed)
        ..didChangeAppLifecycleState(AppLifecycleState.inactive)
        ..didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(calls, <bool>[true, false]);
    });

    testWidgets('detach stops all callbacks', (WidgetTester tester) async {
      trigger.attach();
      trigger.attach(); // idempotent: one observer
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(calls, <bool>[false]);
      trigger.detach();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(calls, <bool>[false]);
    });
  });

  group('ProtectionHealthController freshness (M3)', () {
    test(
        'an after-change check hides an old SECURE until it completes; '
        'a plain check keeps it', () async {
      final _Fx fx = await _Fx.create();
      final ProtectionHealthController c =
          ProtectionHealthController(fx.container.protectionHealth);
      await c.refresh();
      expect(c.report!.state, ProtectionHealthState.secure);

      fx.watcher.getHealthGate = Completer<void>();
      final Future<ProtectionHealthReport?> plain = c.refresh();
      expect(c.report?.state, ProtectionHealthState.secure);
      fx.watcher.getHealthGate!.complete();
      await plain;

      fx.watcher.getHealthGate = Completer<void>();
      final Future<ProtectionHealthReport?> verify =
          c.refresh(afterChange: true);
      expect(c.report, isNull, reason: 'no SECURE from pre-change evidence');
      expect(c.checking, isTrue);
      fx.watcher.getHealthGate!.complete();
      await verify;
      expect(c.report!.state, ProtectionHealthState.secure);
      c.dispose();
    });

    test('an old non-secure report stays visible while re-checking', () async {
      final _Fx fx = await _Fx.create();
      fx.watcher.running = false;
      final ProtectionHealthController c =
          ProtectionHealthController(fx.container.protectionHealth);
      await c.refresh();
      fx.watcher.getHealthGate = Completer<void>();
      final Future<ProtectionHealthReport?> verify =
          c.refresh(afterChange: true);
      expect(c.report!.state, ProtectionHealthState.attentionRequired);
      fx.watcher.getHealthGate!.complete();
      await verify;
      c.dispose();
    });

    test(
        'rapid requests: only the newest updates the view, with the newest '
        'data', () async {
      final _Fx fx = await _Fx.create();
      final ProtectionHealthController c =
          ProtectionHealthController(fx.container.protectionHealth);
      int notifications = 0;
      c.addListener(() => notifications++);
      fx.watcher.getHealthGate = Completer<void>();
      final Future<ProtectionHealthReport?> older = c.refresh();
      for (int i = 0; i < 20 && fx.watcher.getHealthCalls < 1; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      fx.overlay.overlayGranted = false; // changed after the older read
      final Future<ProtectionHealthReport?> newer =
          c.refresh(afterChange: true);
      fx.watcher.getHealthGate!.complete();
      final ProtectionHealthReport? olderResult = await older;
      expect(olderResult!.state, ProtectionHealthState.secure);
      expect(c.checking, isTrue, reason: 'the older result was ignored');
      expect(c.report, isNull, reason: 'no SECURE while verifying');
      await newer;
      expect(c.report!.state, ProtectionHealthState.protectionOffline);
      expect(notifications, greaterThan(0));
      c.dispose();
    });
  });

  group('Return from Android Settings / app resume (SIMULATED)', () {
    testWidgets(
        'revoked while away → Home shows it on return without a tap; '
        'restored → SECURE again after the fresh check',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      final _Life life = _Life();
      await _pumpHome(tester, fx.container);
      expect(_homeTitle(tester), HealthPresentation.secureTitle);
      final int start = fx.watcher.getHealthCalls;

      await life.leave(tester);
      fx.overlay.overlayGranted = false;
      await life.back(tester);
      expect(_homeTitle(tester), HealthPresentation.offlineTitle);
      expect(fx.latest.issues.first.code, HealthIssueCode.overlayUnavailable);
      expect(fx.watcher.getHealthCalls, start + 1);

      await life.leave(tester);
      fx.overlay.overlayGranted = true;
      await life.back(tester);
      expect(_homeTitle(tester), HealthPresentation.secureTitle);
      expect(fx.watcher.getHealthCalls, start + 2);
    });

    testWidgets('the check after returning never shows the old SECURE',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      final _Life life = _Life();
      await _pumpHome(tester, fx.container);
      await life.leave(tester);
      fx.watcher.getHealthGate = Completer<void>();
      fx.overlay.overlayGranted = false;
      await life.back(tester, settle: false);
      expect(_homeTitle(tester), HealthPresentation.checkingTitle);
      fx.watcher.getHealthGate!.complete();
      await tester.pumpAndSettle();
      expect(_homeTitle(tester), HealthPresentation.offlineTitle);
    });

    testWidgets(
        'rapid lifecycle events coalesce: shade pulls share one probe; '
        'repeated returns queue at most one more', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      final _Life life = _Life();
      await _pumpHome(tester, fx.container);
      final int start = fx.watcher.getHealthCalls;

      fx.watcher.getHealthGate = Completer<void>();
      for (int i = 0; i < 3; i++) {
        await life.shade(tester);
      }
      expect(fx.watcher.getHealthCalls, start + 1, reason: 'one shared probe');
      for (int i = 0; i < 3; i++) {
        await life.leave(tester);
        await life.back(tester, settle: false);
      }
      fx.watcher.getHealthGate!.complete();
      await tester.pumpAndSettle();
      expect(fx.watcher.getHealthCalls, start + 2,
          reason: 'running probe + one queued after-change probe');
      expect(_homeTitle(tester), HealthPresentation.secureTitle);

      // No loop afterwards.
      await tester.pump(const Duration(minutes: 5));
      expect(fx.watcher.getHealthCalls, start + 2);
    });

    testWidgets(
        'Home hidden (another tab) does not refresh on resume; becoming '
        'visible again refreshes once with the current state',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      final _Life life = _Life();
      final ValueNotifier<bool> active = ValueNotifier<bool>(true);
      await _pumpHome(tester, fx.container, active: active);
      active.value = false;
      await tester.pumpAndSettle();
      final int hidden = fx.watcher.getHealthCalls;

      await life.leave(tester);
      fx.watcher.running = false;
      await life.back(tester);
      await life.shade(tester);
      await tester.pump(const Duration(minutes: 2));
      expect(fx.watcher.getHealthCalls, hidden, reason: 'no hidden refresh');

      active.value = true;
      await tester.pumpAndSettle();
      expect(fx.watcher.getHealthCalls, hidden + 1);
      expect(_homeTitle(tester), HealthPresentation.attentionTitle);
    });

    testWidgets(
        'covered Home / covered details do not refresh (stand-in for a '
        'challenge or setup route); with details on top only the details '
        'screen refreshes', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      final _Life life = _Life();
      await _pumpHome(tester, fx.container);
      final NavigatorState nav = tester.state(find.byType(Navigator));

      unawaited(nav.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('challenge stand-in')),
      )));
      await tester.pumpAndSettle();
      final int covered = fx.watcher.getHealthCalls;
      await life.leave(tester);
      await life.back(tester);
      expect(fx.watcher.getHealthCalls, covered);
      nav.pop();
      await tester.pumpAndSettle();

      await _openDetailsFromHome(tester);
      final int details = fx.watcher.getHealthCalls;
      await life.leave(tester);
      fx.watcher.running = false;
      await life.back(tester);
      expect(fx.watcher.getHealthCalls, details + 1, reason: 'one, not two');
      expect(
        find.byKey(
          const ValueKey<String>('health_issue_watcher_not_running_watcher'),
        ),
        findsOneWidget,
      );

      // Covered details screen (setup screen / challenge stand-in): a
      // return probes nothing; uncovering it does not probe either.
      unawaited(tester.state<NavigatorState>(find.byType(Navigator)).push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('cover over details')),
            ),
          ));
      await tester.pumpAndSettle();
      final int coveredDetails = fx.watcher.getHealthCalls;
      await life.leave(tester);
      await life.back(tester);
      expect(fx.watcher.getHealthCalls, coveredDetails);
    });

    testWidgets(
        'Settings repair: the outcome is judged automatically from the '
        'fresh check on return', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      final _Life life = _Life();
      fx.watcher.notificationPermissionGranted = false;
      await _pumpHome(tester, fx.container);
      await _openDetailsFromHome(tester);
      final int before = fx.watcher.getHealthCalls;

      await _tapKey(tester, const Key('health_repair_notifications_disabled'));
      expect(_notice(tester), ProtectionHealthScreen.settingsOpenedNotice);
      expect(fx.watcher.getHealthCalls, before, reason: 'no claim on tap');

      // Returned without changing anything.
      await life.leave(tester);
      await life.back(tester);
      expect(_notice(tester), contains('still reports'));

      // Second attempt: allowed this time.
      await _tapKey(tester, const Key('health_repair_notifications_disabled'));
      await life.leave(tester);
      fx.watcher.notificationPermissionGranted = true;
      await life.back(tester);
      expect(_notice(tester), contains('no longer reports'));
      expect(
        find.descendant(
          of: find.byKey(const Key('health_details_status')),
          matching: find.text(HealthPresentation.secureTitle),
        ),
        findsOneWidget,
      );

      // Only one judgement per Settings visit.
      await life.leave(tester);
      await life.back(tester);
      expect(_notice(tester), contains('no longer reports'));
    });

    testWidgets(
        'Settings repair: a failed check on return is reported as unknown, '
        'never as fixed', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      final _Life life = _Life();
      fx.watcher.backgroundRestricted = true;
      await _pumpHome(tester, fx.container);
      await _openDetailsFromHome(tester);
      await _tapKey(tester, const Key('health_repair_background_restricted'));
      await life.leave(tester);
      fx.watcher.backgroundRestricted = false;
      fx.watcher.getHealthError = StateError('bridge down');
      await life.back(tester);
      expect(_notice(tester), ProtectionHealthScreen.checkFailedNotice);
      expect(_notice(tester), isNot(contains('no longer reports')));
      expect(
        find.descendant(
          of: find.byKey(const Key('health_details_status')),
          matching: find.text(HealthPresentation.secureTitle),
        ),
        findsNothing,
      );
    });

    testWidgets('Settings did not open: no automatic judgement on return',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      final _Life life = _Life();
      fx.watcher
        ..notificationPermissionGranted = false
        ..settingsOpenResult = false;
      await _pumpHome(tester, fx.container);
      await _openDetailsFromHome(tester);
      await _tapKey(tester, const Key('health_repair_notifications_disabled'));
      expect(_notice(tester), ProtectionHealthScreen.settingsFailedNotice);
      await life.leave(tester);
      await life.back(tester);
      expect(_notice(tester), ProtectionHealthScreen.settingsFailedNotice);
    });

    testWidgets(
        'a timed-out native read on return is UNKNOWN (ATTENTION), never '
        'SECURE', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      final _Life life = _Life();
      await _pumpHome(tester, fx.container);
      await life.leave(tester);
      fx.watcher.getHealthGate = Completer<void>(); // never answers
      await life.back(tester, settle: false);
      await tester.pump(const Duration(seconds: 4)); // past probeTimeout
      await tester.pumpAndSettle();
      expect(_homeTitle(tester), HealthPresentation.attentionTitle);
      expect(fx.latest.issues.map((HealthIssue i) => i.code),
          contains(HealthIssueCode.signalUnknown));
    });

    testWidgets(
        'disposing during a resume check: no late update, no observer left',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      final _Life life = _Life();
      await _pumpHome(tester, fx.container);
      await life.leave(tester);
      fx.watcher.getHealthGate = Completer<void>();
      await life.back(tester, settle: false);
      await tester.pumpWidget(const SizedBox());
      fx.watcher.getHealthGate!.complete();
      fx.watcher.getHealthGate = null;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final int after = fx.watcher.getHealthCalls;
      await life.leave(tester);
      await life.back(tester);
      expect(fx.watcher.getHealthCalls, after, reason: 'observer detached');
    });
  });

  group('Full app shell (SIMULATED)', () {
    testWidgets(
        'return after a revocation updates Home in the real shell, next to '
        'the existing Security-tab and capability resume checks',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      final _Life life = _Life();
      tester.view.physicalSize = const Size(1080, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(SmartAppLockApp(container: fx.container));
      await tester.pumpAndSettle();
      expect(_homeTitle(tester), HealthPresentation.secureTitle);

      await life.leave(tester);
      fx.overlay.overlayGranted = false;
      await life.back(tester);
      expect(_homeTitle(tester), HealthPresentation.offlineTitle);

      await life.leave(tester);
      fx.overlay.overlayGranted = true;
      await life.back(tester);
      expect(_homeTitle(tester), HealthPresentation.secureTitle);
      expect(fx.access.sessionFor(_pkg), isNull);
    });
  });

  group('Manual revocation regression via Settings round-trip (SIMULATED)', () {
    for (final _Scenario s in _scenarios) {
      testWidgets(s.name, (WidgetTester tester) async {
        final _Fx fx = await _Fx.create();
        final _Life life = _Life();
        await _pumpHome(tester, fx.container);
        expect(_homeTitle(tester), HealthPresentation.secureTitle);

        await life.leave(tester);
        await s.revoke(fx);
        await life.back(tester);
        final HealthIssue top = fx.latest.issues.first;
        expect(fx.latest.state, s.state);
        expect(top.code, s.code);
        expect(top.category, s.category);
        expect(
          _homeTitle(tester),
          s.state == ProtectionHealthState.protectionOffline
              ? HealthPresentation.offlineTitle
              : HealthPresentation.attentionTitle,
        );

        await life.leave(tester);
        await s.restore(fx);
        await life.back(tester);
        expect(fx.latest.state, ProtectionHealthState.secure,
            reason: 'recovery confirmed by a fresh check');
        expect(_homeTitle(tester), HealthPresentation.secureTitle);
        expect(fx.watcher.startCalls, 0, reason: 'health never restarts');
        expect(fx.watcher.configureCalls, 0, reason: 'health never configures');
      });
    }

    testWidgets('Battery Saver toggled: advisory only, status stays SECURE',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      final _Life life = _Life();
      await _pumpHome(tester, fx.container);
      await life.leave(tester);
      fx.watcher.powerSaveMode = true;
      await life.back(tester);
      expect(_homeTitle(tester), HealthPresentation.secureTitle);
      expect(fx.latest.issues.single.code, HealthIssueCode.batterySaverOn);
      expect(fx.latest.issues.single.severity, HealthIssueSeverity.advisory);
      expect(find.byKey(const Key('home_top_issue')), findsNothing);
    });

    testWidgets(
        'fingerprint unavailable: advisory only, status stays SECURE, no '
        'prompt', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      final _Life life = _Life();
      expect(
        (await fx.container.auth.updateBiometricOptions(
          BiometricOptions.defaults,
        ))
            .isSuccess,
        isTrue,
      );
      await _pumpHome(tester, fx.container);
      expect(_homeTitle(tester), HealthPresentation.secureTitle);
      await life.leave(tester);
      fx.bio.enrolled = false;
      await life.back(tester);
      expect(_homeTitle(tester), HealthPresentation.secureTitle);
      expect(
          fx.latest.issues.single.code, HealthIssueCode.biometricUnavailable);
      expect(fx.bio.authenticateCalls, 0);
    });

    testWidgets(
        'watcher stop / restart via Check again (no automatic restart by '
        'health)', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pumpHome(tester, fx.container);
      fx.watcher.running = false;
      await tester.tap(find.byKey(const Key('home_check_again')));
      await tester.pumpAndSettle();
      expect(_homeTitle(tester), HealthPresentation.attentionTitle);
      expect(fx.watcher.startCalls, 0);
      fx.watcher.running = true; // restarted elsewhere (user / Android)
      await tester.tap(find.byKey(const Key('home_check_again')));
      await tester.pumpAndSettle();
      expect(_homeTitle(tester), HealthPresentation.secureTitle);
    });
  });

  group('Security isolation of refresh (SIMULATED)', () {
    testWidgets(
        'Settings round-trips and resume refreshes keep a pending ticket and '
        'never authorize, mark ready, touch the challenge or the lifecycle',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      final _Life life = _Life();
      fx.watcher.notificationPermissionGranted = false;
      await _pumpHome(tester, fx.container);
      fx.watcher
        ..pendingChallenge = _pkg
        ..pendingChallengeGeneration = 9;
      await _openDetailsFromHome(tester);
      await _tapKey(tester, const Key('health_repair_notifications_disabled'));
      for (int i = 0; i < 2; i++) {
        await life.leave(tester);
        await life.back(tester);
        await life.shade(tester);
      }
      await tester.pageBack();
      await tester.pumpAndSettle();
      await life.leave(tester);
      await life.back(tester);

      expect(fx.watcher.pendingChallenge, _pkg);
      expect(fx.watcher.pendingChallengeGeneration, 9);
      expect(fx.watcher.authorizedPackages, isEmpty);
      expect(fx.watcher.authorizePackageCalls, 0);
      expect(fx.watcher.revokeAllAuthorizationsCalls, 0);
      expect(fx.watcher.startCalls, 0);
      expect(fx.watcher.stopCalls, 0);
      expect(fx.watcher.configureCalls, 0);
      expect(fx.watcher.heartbeatCalls, 0);
      expect(fx.overlay.markChallengeReadyCalls, 0);
      expect(fx.overlay.showLockChallengeCalls, 0);
      expect(fx.overlay.hideLockChallengeCalls, 0);
      expect(fx.access.sessionFor(_pkg), isNull);
      expect(fx.bio.authenticateCalls, 0);
    });

    testWidgets(
        'full app: a challenge interrupted by leaving with health details '
        'open re-presents on return; only the exact PIN grants',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      final _Life life = _Life();
      tester.view.physicalSize = const Size(1080, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(SmartAppLockApp(container: fx.container));
      await tester.pumpAndSettle();
      await fx.container.protectionBootstrap.synchronize();
      await _openDetailsFromHome(tester);

      fx.accessibility.emitForegroundPackage(_pkg);
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      // Leave (as if to Android Settings) and come back.
      await life.leave(tester);
      await life.to(tester, AppLifecycleState.hidden);
      await life.to(tester, AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      await life.back(tester);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(fx.access.sessionFor(_pkg), isNull);

      for (final String d in '1357'.split('')) {
        await tester.tap(find.byKey(Key('pin_key_$d')));
        await tester.pumpAndSettle();
      }
      expect(find.byType(PinUnlockScreen), findsOneWidget,
          reason: 'a wrong PIN keeps the challenge');
      expect(fx.access.sessionFor(_pkg), isNull);
      for (final String d in '2468'.split('')) {
        await tester.tap(find.byKey(Key('pin_key_$d')));
        await tester.pumpAndSettle();
      }
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(fx.access.sessionFor(_pkg), isNotNull);
      expect(find.byType(ProtectionHealthScreen), findsOneWidget);
    });
  });
}
