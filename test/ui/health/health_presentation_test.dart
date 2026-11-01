// Phase 7 / M2 — Protection Health presentation and controller.
//
// PRODUCTION Dart (pure wording/mapping and the dashboard view state) over
// the real Phase 7 / M1 engine and monitor with simulated services. These
// tests do not observe an Android device.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/router.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/protection/health/protection_health_engine.dart';
import 'package:smart_app_lock/protection/health/protection_health_monitor.dart';
import 'package:smart_app_lock/security/credentials/biometric_options.dart';
import 'package:smart_app_lock/services/biometric_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/watcher_service.dart';
import 'package:smart_app_lock/ui/screens/health/health_presentation.dart';
import 'package:smart_app_lock/ui/screens/health/protection_health_controller.dart';
import 'package:smart_app_lock/ui/screens/health/protection_health_screen.dart';
import 'package:smart_app_lock/utilities/result.dart';

class _Bio implements BiometricService {
  @override
  Future<Result<bool>> isSupported() async => Result.success(true);

  @override
  Future<Result<Set<BiometricKind>>> availableKinds() async =>
      Result.success(<BiometricKind>{BiometricKind.strong});

  @override
  Future<Result<bool>> authenticate({
    required String reason,
    BiometricOptions? options,
  }) async =>
      Result.success(false);
}

HealthSignals _signals({
  bool? configured = true,
  bool? credential = true,
  bool? apps = true,
  bool? overlay = true,
  bool overlayEver = false,
  bool? accessibility = true,
  bool? watcher = true,
  bool? restricted = false,
  DateTime? at,
}) =>
    HealthSignals(
      observedAt: at ?? DateTime(2026, 11, 1, 10),
      protectionConfigured: configured,
      credentialConfigured: credential,
      hasProtectedApps: apps,
      nativeProtectionEnabled: true,
      overlayGranted: overlay,
      overlayEverGranted: overlayEver,
      accessibilityEnabled: accessibility,
      accessibilityConnected: true,
      usageAccessGranted: true,
      nativeHealthAvailable: true,
      watcherRunning: watcher,
      shieldArmed: true,
      notificationsGranted: true,
      backgroundRestricted: restricted,
      sdkInt: 34,
      powerSaveMode: false,
      biometricUnlockEnabled: false,
    );

ProtectionHealthReport _eval(HealthSignals s) =>
    ProtectionHealthEngine.evaluate(s, now: s.observedAt);

/// A monitor whose next refresh can be made to throw (defensive path).
class _FlakyMonitor extends ProtectionHealthMonitor {
  _FlakyMonitor(AppContainer c, {super.maxAge})
      : super(
          protectedApps: c.protectedApps,
          credentials: c.auth,
          installedApps: c.installedAppsService,
          accessibility: c.accessibility,
          overlay: c.overlay,
          watcher: c.watcher,
          preferences: c.preferences,
          biometrics: _Bio(),
        );

  bool fail = false;
  int refreshes = 0;

  @override
  Future<ProtectionHealthReport> refresh() {
    refreshes++;
    if (fail) return Future<ProtectionHealthReport>.error(StateError('x'));
    return super.refresh();
  }
}

Future<AppContainer> _healthy() async {
  final AppContainer c = AppContainer.inMemory(
    biometrics: _Bio(),
    accessibilityEnabled: true,
    overlayGranted: true,
  );
  await c.auth.enrollPin('2468');
  await c.protectedApps.add(
    ProtectedApp(
      packageName: 'com.example.private',
      label: 'Private',
      addedAt: DateTime(2026, 11, 1),
    ),
  );
  (c.watcher as StaticWatcherService)
    ..protectionConfigured = true
    ..running = true
    ..accessibilityServiceConnected = true
    ..shieldArmed = true
    ..challengePending = false
    ..backgroundRestricted = false
    ..powerSaveMode = false
    ..sdkInt = 34;
  return c;
}

const List<String> _forbiddenClaims = <String>[
  '100%',
  'unhackable',
  'impossible to bypass',
  'cannot be bypassed',
  'fully secure',
  'guaranteed',
];

void main() {
  group('status presentation (driven only by the M1 report)', () {
    test('three PRD states map to their headline and tone', () {
      expect(
        HealthPresentation.status(_eval(_signals())).title,
        HealthPresentation.secureTitle,
      );
      expect(
        HealthPresentation.status(_eval(_signals())).level,
        SecurityLevel.secured,
      );
      final HealthStatusView attention =
          HealthPresentation.status(_eval(_signals(accessibility: false)));
      expect(attention.title, HealthPresentation.attentionTitle);
      expect(attention.level, SecurityLevel.atRisk);
      final HealthStatusView offline = HealthPresentation.status(
        _eval(_signals(overlay: false, overlayEver: true)),
      );
      expect(offline.title, HealthPresentation.offlineTitle);
      expect(offline.level, SecurityLevel.vulnerable);
      expect(offline.message, contains('not working'));
      // Never granted: still OFFLINE (nothing can be covered), but worded
      // as a permission not allowed yet rather than as a breakdown.
      final HealthStatusView notYet =
          HealthPresentation.status(_eval(_signals(overlay: false)));
      expect(notYet.title, HealthPresentation.offlineTitle);
      expect(notYet.message, contains('has not been allowed yet'));
      expect(notYet.message, isNot(contains('not working')));
    });

    test('setup and user choice are OFFLINE but never worded as a failure', () {
      final ProtectionHealthReport setup = _eval(
        _signals(configured: false, credential: false, apps: false),
      );
      final HealthStatusView s = HealthPresentation.status(setup);
      expect(s.title, HealthPresentation.offlineTitle);
      expect(s.level, SecurityLevel.notSet);
      expect(s.message, contains('Setup is not finished'));
      expect(s.message, isNot(contains('not working')));

      final ProtectionHealthReport choice = _eval(
        _signals(configured: false, credential: true, apps: false),
      );
      final HealthStatusView c = HealthPresentation.status(choice);
      expect(c.level, SecurityLevel.notSet);
      expect(c.message, contains('No apps are protected'));
      expect(c.message, isNot(contains('not working')));
    });

    test('no report / failed check / checking never read as SECURE', () {
      for (final HealthStatusView v in <HealthStatusView>[
        HealthPresentation.status(null),
        HealthPresentation.status(null, checking: true),
        HealthPresentation.status(null, failed: true),
      ]) {
        expect(v.title, isNot(HealthPresentation.secureTitle));
        expect(v.level, isNot(SecurityLevel.secured));
      }
      expect(
        HealthPresentation.status(null, failed: true).message,
        contains('does not mean protection is working'),
      );
    });

    test('a stale SECURE observation is presented as ATTENTION REQUIRED', () {
      final ProtectionHealthReport fresh = _eval(_signals());
      final ProtectionHealthReport stale = ProtectionHealthEngine.reevaluate(
        fresh,
        now: fresh.observedAt.add(const Duration(seconds: 31)),
      );
      final HealthStatusView v = HealthPresentation.status(stale);
      expect(v.title, HealthPresentation.attentionTitle);
      expect(v.message, contains('out of date'));
    });
  });

  group('issue presentation', () {
    // Every issue code under every cause the engine can attach.
    final List<HealthIssue> all = <HealthIssue>[
      for (final HealthIssueCode code in HealthIssueCode.values)
        for (final HealthCause cause in HealthCause.values)
          for (final HealthRepairAction? action in <HealthRepairAction?>[
            ...HealthRepairAction.values,
            null,
          ])
            HealthIssue(
              code: code,
              component: HealthComponent
                  .values[code.index % HealthComponent.values.length],
              cause: cause,
              action: action,
            ),
    ];

    test(
        'every code/cause/action has non-empty wording, with no absolute '
        'claims and no raw technical detail', () {
      for (final HealthIssue issue in all) {
        final HealthIssueView v = HealthPresentation.issue(issue);
        final String text = <String?>[
          v.title,
          v.explanation,
          v.categoryLabel,
          v.repair.label,
          v.repair.guidance,
        ].whereType<String>().join(' ').toLowerCase();
        expect(v.title, isNotEmpty);
        expect(v.explanation, isNotEmpty);
        for (final String claim in _forbiddenClaims) {
          expect(text, isNot(contains(claim)), reason: '$issue');
        }
        expect(text, isNot(contains('_')), reason: 'no raw ids: $issue');
      }
      for (final String claim in _forbiddenClaims) {
        expect(
          HealthPresentation.secureScope.toLowerCase(),
          isNot(contains(claim)),
        );
      }
      expect(HealthPresentation.secureScope, contains('not a guarantee'));
    });

    test(
        'categories distinguish setup, choice, revoked, stopped, '
        'restricted, unknown and advisory', () {
      expect(
        HealthIssueCategory.values
            .map(HealthPresentation.categoryLabel)
            .toSet(),
        hasLength(HealthIssueCategory.values.length),
      );
      HealthIssueView view(HealthIssueCode code, HealthCause cause) =>
          HealthPresentation.issue(
            HealthIssue(
              code: code,
              component: HealthComponent.overlay,
              cause: cause,
              action: HealthRepairAction.openOverlaySettings,
            ),
          );
      final HealthIssueView revoked =
          view(HealthIssueCode.overlayUnavailable, HealthCause.revoked);
      final HealthIssueView never =
          view(HealthIssueCode.overlayUnavailable, HealthCause.notGranted);
      expect(revoked.title, contains('was turned off'));
      expect(revoked.categoryLabel, 'Permission turned off');
      expect(never.title, contains('not allowed yet'));
      expect(never.categoryLabel, 'Setup needed');
    });

    test('repair plans follow the M1 action hint', () {
      HealthRepairPlan plan(HealthRepairAction? a) => HealthPresentation.repair(
            HealthIssue(
              code: HealthIssueCode.signalUnknown,
              component: HealthComponent.watcher,
              cause: HealthCause.unknown,
              action: a,
            ),
          );
      expect(plan(HealthRepairAction.configureProtection).tab,
          HealthPresentation.securityTab);
      expect(plan(HealthRepairAction.chooseProtectedApps).tab,
          HealthPresentation.appsTab);
      expect(plan(HealthRepairAction.openOverlaySettings).route,
          RouteNames.overlaySetup);
      expect(plan(HealthRepairAction.openAccessibilitySettings).route,
          RouteNames.accessibilitySetup);
      expect(plan(HealthRepairAction.openUsageAccessSettings).route,
          RouteNames.usageAccess);
      expect(plan(HealthRepairAction.openNotificationSettings).settingsTarget,
          ProtectionSettingsTarget.notifications);
      expect(plan(HealthRepairAction.openAppBatterySettings).settingsTarget,
          ProtectionSettingsTarget.appDetails);
      expect(plan(HealthRepairAction.openAppBatterySettings).guidance,
          contains('ColorOS'));
      expect(plan(HealthRepairAction.openBatterySaverSettings).settingsTarget,
          ProtectionSettingsTarget.batterySaver);
      expect(plan(HealthRepairAction.openSmartAppLock).kind,
          HealthRepairKind.restartProtection);
      expect(
          plan(HealthRepairAction.refresh).kind, HealthRepairKind.checkAgain);
      // No safe direct action: guidance only, never a fake button.
      for (final HealthRepairAction? a in <HealthRepairAction?>[
        HealthRepairAction.openBiometricSettings,
        null,
      ]) {
        expect(plan(a).kind, HealthRepairKind.guidanceOnly);
        expect(plan(a).hasAction, isFalse);
        expect(plan(a).label, isNull);
        expect(plan(a).guidance, isNotEmpty);
      }
    });
  });

  group('repair outcome is judged only from a fresh report', () {
    final HealthIssue overlayIssue = _eval(_signals(overlay: false))
        .issues
        .firstWhere(
            (HealthIssue i) => i.code == HealthIssueCode.overlayUnavailable);

    test('resolved only when a fresh report no longer lists the issue', () {
      expect(
        ProtectionHealthScreen.outcome(overlayIssue, _eval(_signals())),
        HealthRepairOutcome.resolved,
      );
      expect(
        ProtectionHealthScreen.outcome(
          overlayIssue,
          _eval(_signals(overlay: false)),
        ),
        HealthRepairOutcome.stillPresent,
      );
    });

    test('no report or a stale report is never "resolved"', () {
      expect(
        ProtectionHealthScreen.outcome(overlayIssue, null),
        HealthRepairOutcome.unknown,
      );
      final ProtectionHealthReport fresh = _eval(_signals());
      final ProtectionHealthReport stale = ProtectionHealthEngine.reevaluate(
        fresh,
        now: fresh.observedAt.add(const Duration(minutes: 5)),
      );
      expect(
        ProtectionHealthScreen.outcome(overlayIssue, stale),
        HealthRepairOutcome.unknown,
      );
    });
  });

  group('ProtectionHealthController', () {
    test('without a health source nothing is reported and nothing probes',
        () async {
      final ProtectionHealthController c = ProtectionHealthController(null);
      expect(c.available, isFalse);
      expect(await c.refresh(), isNull);
      expect(c.report, isNull);
      c.dispose();
    });

    test('refresh exposes the shared monitor report (one source of truth)',
        () async {
      final AppContainer container = await _healthy();
      final ProtectionHealthController a =
          ProtectionHealthController(container.protectionHealth);
      final ProtectionHealthController b =
          ProtectionHealthController(container.protectionHealth);
      final ProtectionHealthReport? r = await a.refresh();
      expect(r?.state, ProtectionHealthState.secure);
      expect(b.report?.signature, r?.signature,
          reason: 'another screen reads the same monitor');
      a.dispose();
      b.dispose();
    });

    test('concurrent refreshes share one probe', () async {
      final AppContainer container = await _healthy();
      final StaticWatcherService w = container.watcher as StaticWatcherService;
      final ProtectionHealthController a =
          ProtectionHealthController(container.protectionHealth);
      final ProtectionHealthController b =
          ProtectionHealthController(container.protectionHealth);
      final int before = w.getHealthCalls;
      await Future.wait(<Future<Object?>>[
        a.refresh(),
        a.refresh(),
        b.refresh(),
      ]);
      expect(w.getHealthCalls - before, 1);
      a.dispose();
      b.dispose();
    });

    test('a failed refresh discards a previous SECURE report', () async {
      final AppContainer container = await _healthy();
      final _FlakyMonitor m = _FlakyMonitor(container);
      final ProtectionHealthController c = ProtectionHealthController(m);
      expect((await c.refresh())?.state, ProtectionHealthState.secure);
      m.fail = true;
      expect(await c.refresh(), isNull);
      expect(c.failed, isTrue);
      expect(c.report, isNull, reason: 'never show the old SECURE');
      expect(m.latest()?.state, ProtectionHealthState.secure,
          reason: 'the monitor still holds it; the controller hides it');
      m.fail = false;
      expect((await c.refresh())?.state, ProtectionHealthState.secure);
      expect(c.failed, isFalse);
      c.dispose();
    });

    test('one timer re-renders the stale state at max age, without probing',
        () async {
      final AppContainer container = await _healthy();
      final _FlakyMonitor m = _FlakyMonitor(
        container,
        maxAge: const Duration(milliseconds: 80),
      );
      final ProtectionHealthController c = ProtectionHealthController(m);
      int notifications = 0;
      c.addListener(() => notifications++);
      await c.refresh();
      expect(c.report?.state, ProtectionHealthState.secure);
      final int afterRefresh = notifications;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(notifications, afterRefresh + 1, reason: 'one stale re-render');
      expect(c.report?.state, ProtectionHealthState.attentionRequired);
      expect(c.report?.hasIssue(HealthIssueCode.healthSnapshotStale), isTrue);
      expect(m.refreshes, 1, reason: 'no polling');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(notifications, afterRefresh + 1, reason: 'no repeating timer');
      c.dispose();
    });

    test('dispose during an in-flight refresh is safe and silent', () async {
      final AppContainer container = await _healthy();
      final StaticWatcherService w = container.watcher as StaticWatcherService;
      w.getHealthGate = Completer<void>();
      final ProtectionHealthController c =
          ProtectionHealthController(container.protectionHealth);
      int notifications = 0;
      c.addListener(() => notifications++);
      final Future<ProtectionHealthReport?> pending = c.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(c.checking, isTrue);
      expect(c.report, isNull, reason: 'loading is not SECURE');
      final int beforeDispose = notifications;
      c.dispose();
      w.getHealthGate!.complete();
      await pending;
      expect(notifications, beforeDispose, reason: 'no notify after dispose');
    });
  });
}
