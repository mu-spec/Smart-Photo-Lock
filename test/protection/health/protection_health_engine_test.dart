// Phase 7 / M1 — Protection Health engine (PRODUCTION code, pure Dart).
//
// These tests exercise the real classifier with explicit signal values.
// They do not run Android: Accessibility binding, overlay grants,
// isBackgroundRestricted, Battery Saver and biometric hardware are supplied
// as inputs, not observed on a device.
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/protection/health/protection_health_engine.dart';

final DateTime t0 = DateTime(2026, 11, 1, 10);

HealthSignals healthy({
  DateTime? observedAt,
  bool? configured = true,
  bool? credential = true,
  bool? apps = true,
  bool? nativeEnabled = true,
  bool? overlay = true,
  bool overlayEver = true,
  bool? accessibility = true,
  bool accessibilityEver = true,
  bool? connected = true,
  bool? usage = true,
  bool usageEver = true,
  bool native = true,
  bool? watcher = true,
  String? lastError,
  bool? shield = true,
  bool? notifications = true,
  bool? restricted = false,
  int? sdk = 34,
  bool? powerSave = false,
  bool? biometricEnabled = false,
  bool? biometricHardware = true,
  bool? biometricEnrolled = true,
}) =>
    HealthSignals(
      observedAt: observedAt ?? t0,
      protectionConfigured: configured,
      credentialConfigured: credential,
      hasProtectedApps: apps,
      nativeProtectionEnabled: nativeEnabled,
      overlayGranted: overlay,
      overlayEverGranted: overlayEver,
      accessibilityEnabled: accessibility,
      accessibilityEverGranted: accessibilityEver,
      accessibilityConnected: connected,
      usageAccessGranted: usage,
      usageAccessEverGranted: usageEver,
      nativeHealthAvailable: native,
      watcherRunning: watcher,
      watcherLastError: lastError,
      shieldArmed: shield,
      notificationsGranted: notifications,
      backgroundRestricted: restricted,
      sdkInt: sdk,
      powerSaveMode: powerSave,
      biometricUnlockEnabled: biometricEnabled,
      biometricHardwarePresent: biometricHardware,
      biometricEnrolled: biometricEnrolled,
    );

ProtectionHealthReport eval(HealthSignals s, {DateTime? now}) =>
    ProtectionHealthEngine.evaluate(s, now: now ?? t0);

List<String> ids(ProtectionHealthReport r) =>
    r.issues.map((HealthIssue i) => i.code.id).toList();

void main() {
  group('foundation', () {
    test('all core signals positively observed and fresh is SECURE', () {
      final ProtectionHealthReport r = eval(healthy());
      expect(r.state, ProtectionHealthState.secure);
      expect(r.issues, isEmpty);
      expect(r.stale, isFalse);
      expect(
        r.limitations,
        contains(HealthLimitation.oemBackgroundControlsUnobservable),
      );
      expect(
        r.components[HealthComponent.oemBackgroundControls],
        ComponentStatus.unknown,
        reason: 'OEM power managers are never claimed as unrestricted',
      );
    });

    test('state ids and issue ids are stable machine-readable strings', () {
      expect(
        ProtectionHealthState.values.map((ProtectionHealthState s) => s.id),
        <String>['SECURE', 'ATTENTION_REQUIRED', 'PROTECTION_OFFLINE'],
      );
      final Set<String> issueIds =
          HealthIssueCode.values.map((HealthIssueCode c) => c.id).toSet();
      expect(issueIds.length, HealthIssueCode.values.length);
      for (final String id in issueIds) {
        expect(id, matches(RegExp(r'^[a-z][a-z_]*$')));
      }
      final Map<String, Object?> json = eval(
        healthy(overlay: false),
      ).toJson();
      expect(json['state'], 'PROTECTION_OFFLINE');
      final List<Object?> issues = json['issues']! as List<Object?>;
      expect(issues.first, <String, Object?>{
        'id': 'overlay_unavailable',
        'severity': 'offline',
        'component': 'overlay',
        'cause': 'revoked',
        'category': 'revoked',
        'action': 'open_overlay_settings',
      });
    });

    test('evaluation is deterministic and issues are severity-ordered', () {
      final HealthSignals s = healthy(
        overlay: false,
        accessibility: false,
        watcher: false,
        notifications: false,
        powerSave: true,
        biometricEnabled: true,
        biometricEnrolled: false,
      );
      final ProtectionHealthReport a = eval(s);
      final ProtectionHealthReport b = eval(s);
      expect(a.toJson(), b.toJson());
      expect(a.signature, b.signature);
      final List<int> severities =
          a.issues.map((HealthIssue i) => i.severity.index).toList();
      expect(severities, List<int>.of(severities)..sort());
    });
  });

  group('required capability health', () {
    test('first-time setup (no credential) is setup, not a system failure', () {
      final ProtectionHealthReport r = eval(
        healthy(configured: false, credential: false, apps: false),
      );
      expect(r.state, ProtectionHealthState.protectionOffline);
      expect(ids(r), <String>['protection_not_configured']);
      final HealthIssue issue = r.issues.single;
      expect(issue.cause, HealthCause.setupIncomplete);
      expect(issue.category, HealthIssueCategory.setup);
      expect(issue.category.isSystemFailure, isFalse);
      expect(issue.action, HealthRepairAction.configureProtection);
      expect(
        r.components[HealthComponent.protectionConfiguration],
        ComponentStatus.notSetUp,
      );
    });

    test('no protected apps is the user choice, not a system failure', () {
      final ProtectionHealthReport r = eval(
        healthy(configured: false, credential: true, apps: false),
      );
      expect(r.state, ProtectionHealthState.protectionOffline);
      final HealthIssue issue = r.issues.single;
      expect(issue.code, HealthIssueCode.protectionNotConfigured);
      expect(issue.cause, HealthCause.noProtectedApps);
      expect(issue.category, HealthIssueCategory.userChoice);
      expect(issue.category.isSystemFailure, isFalse);
      expect(issue.action, HealthRepairAction.chooseProtectedApps);
      expect(
        r.components[HealthComponent.protectionConfiguration],
        ComponentStatus.disabledByUser,
      );
    });

    test('configured protection that stopped is the only system failure', () {
      final Map<HealthIssueCategory, HealthSignals> cases =
          <HealthIssueCategory, HealthSignals>{
        HealthIssueCategory.interrupted: healthy(watcher: false),
        HealthIssueCategory.revoked: healthy(overlay: false),
        HealthIssueCategory.setup: healthy(overlay: false, overlayEver: false),
        HealthIssueCategory.restricted: healthy(restricted: true),
        HealthIssueCategory.uncertain: healthy(watcher: null),
      };
      cases.forEach((HealthIssueCategory expected, HealthSignals s) {
        final HealthIssue issue = eval(s).issues.first;
        expect(issue.category, expected, reason: '$issue');
        expect(
          issue.category.isSystemFailure,
          expected == HealthIssueCategory.interrupted,
        );
      });
      expect(
        eval(healthy(powerSave: true)).issues.single.category,
        HealthIssueCategory.advisory,
      );
    });

    test('overlay revoked vs never granted are distinguished; both OFFLINE',
        () {
      final ProtectionHealthReport revoked = eval(healthy(overlay: false));
      final ProtectionHealthReport never = eval(
        healthy(overlay: false, overlayEver: false),
      );
      for (final ProtectionHealthReport r in <ProtectionHealthReport>[
        revoked,
        never,
      ]) {
        expect(r.state, ProtectionHealthState.protectionOffline);
        expect(r.hasIssue(HealthIssueCode.overlayUnavailable), isTrue);
      }
      expect(
          revoked.components[HealthComponent.overlay], ComponentStatus.revoked);
      expect(revoked.issues.first.cause, HealthCause.revoked);
      expect(
          never.components[HealthComponent.overlay], ComponentStatus.notSetUp);
      expect(never.issues.first.cause, HealthCause.notGranted);
    });

    test('a single missing detector is ATTENTION REQUIRED, never SECURE', () {
      final ProtectionHealthReport noA11y = eval(healthy(accessibility: false));
      expect(noA11y.state, ProtectionHealthState.attentionRequired);
      expect(ids(noA11y), <String>['accessibility_unavailable']);
      final ProtectionHealthReport noUsage = eval(healthy(usage: false));
      expect(noUsage.state, ProtectionHealthState.attentionRequired);
      expect(ids(noUsage), <String>['usage_access_unavailable']);
    });

    test('both detection paths unavailable is OFFLINE with specific causes',
        () {
      final ProtectionHealthReport r = eval(
        healthy(accessibility: false, usage: false, usageEver: false),
      );
      expect(r.state, ProtectionHealthState.protectionOffline);
      expect(ids(r), <String>[
        'detection_offline',
        'accessibility_unavailable',
        'usage_access_unavailable',
      ]);
      expect(r.issues[2].cause, HealthCause.notGranted);
      expect(r.issues[1].cause, HealthCause.revoked);
    });

    test('detection offline cause: setup vs revoked vs interrupted', () {
      HealthIssue detection(HealthSignals s) => eval(s).issues.firstWhere(
            (HealthIssue i) => i.code == HealthIssueCode.detectionOffline,
          );
      // Fresh install: neither detector ever granted → setup wording.
      final HealthIssue fresh = detection(
        healthy(
          accessibility: false,
          accessibilityEver: false,
          usage: false,
          usageEver: false,
        ),
      );
      expect(fresh.cause, HealthCause.notGranted);
      expect(fresh.category, HealthIssueCategory.setup);
      // Any revocation → revoked.
      expect(
        detection(
          healthy(accessibility: false, usage: false, usageEver: false),
        ).cause,
        HealthCause.revoked,
      );
      // Granted but stopped (Accessibility unbound, watcher stopped).
      final HealthIssue stopped = detection(
        healthy(connected: false, watcher: false),
      );
      expect(stopped.cause, HealthCause.notRunning);
      expect(stopped.category.isSystemFailure, isTrue);
    });

    test('notifications denied is ATTENTION (documented degraded state)', () {
      final ProtectionHealthReport r = eval(healthy(notifications: false));
      expect(r.state, ProtectionHealthState.attentionRequired);
      expect(ids(r), <String>['notifications_disabled']);
    });
  });

  group('protection engine health', () {
    test('Accessibility enabled in Settings but not bound is not operational',
        () {
      final ProtectionHealthReport r = eval(healthy(connected: false));
      expect(r.state, ProtectionHealthState.attentionRequired);
      expect(ids(r), <String>['accessibility_not_running']);
      expect(
        r.components[HealthComponent.accessibilityDetection],
        ComponentStatus.notRunning,
      );
      // ... and with no usage fallback it is OFFLINE, not merely attention.
      final ProtectionHealthReport alone = eval(
        healthy(connected: false, usage: false),
      );
      expect(alone.state, ProtectionHealthState.protectionOffline);
      expect(alone.hasIssue(HealthIssueCode.detectionOffline), isTrue);
    });

    test('watcher interruption is reported with the native reason', () {
      final ProtectionHealthReport r = eval(
        healthy(watcher: false, lastError: 'Android stopped the service.'),
      );
      expect(r.state, ProtectionHealthState.attentionRequired);
      expect(ids(r), <String>['watcher_not_running']);
      expect(
          r.issues.single.detail['lastError'], 'Android stopped the service.');
      expect(r.components[HealthComponent.watcher], ComponentStatus.notRunning);
    });

    test(
        'usage fallback needs the watcher: stopped watcher + no a11y = OFFLINE',
        () {
      final ProtectionHealthReport r = eval(
        healthy(watcher: false, accessibility: false),
      );
      expect(r.state, ProtectionHealthState.protectionOffline);
      expect(r.hasIssue(HealthIssueCode.detectionOffline), isTrue);
      expect(r.hasIssue(HealthIssueCode.watcherNotRunning), isTrue);
      expect(ProtectionHealthEngine.usageAccessPath(healthy(watcher: false)),
          isFalse);
    });

    test('shield not pre-armed while overlay is granted is ATTENTION', () {
      final ProtectionHealthReport r = eval(healthy(shield: false));
      expect(r.state, ProtectionHealthState.attentionRequired);
      expect(ids(r), <String>['shield_not_armed']);
      // The overlay issue supersedes the shield issue when overlay is gone.
      final ProtectionHealthReport noOverlay = eval(
        healthy(overlay: false, shield: false),
      );
      expect(noOverlay.hasIssue(HealthIssueCode.shieldNotArmed), isFalse);
    });

    test('saved configuration without native enforcement is OFFLINE', () {
      final ProtectionHealthReport off = eval(healthy(nativeEnabled: false));
      expect(off.state, ProtectionHealthState.protectionOffline);
      expect(ids(off), <String>['enforcement_not_armed']);
      expect(off.issues.single.category, HealthIssueCategory.interrupted);
      expect(
        off.components[HealthComponent.nativeEnforcement],
        ComponentStatus.notRunning,
      );
      final ProtectionHealthReport unknown = eval(
        healthy(nativeEnabled: null),
      );
      expect(unknown.state, ProtectionHealthState.attentionRequired);
      expect(
        unknown.issues.single.component,
        HealthComponent.nativeEnforcement,
      );
    });

    test('the Flutter heartbeat is not an input: no SECURE from heartbeat', () {
      // HealthSignals has no heartbeat field; a dead watcher with every
      // capability granted is never SECURE.
      final ProtectionHealthReport r = eval(healthy(watcher: false));
      expect(r.state, isNot(ProtectionHealthState.secure));
    });

    test('native health unreadable: one UNKNOWN issue, never SECURE', () {
      final ProtectionHealthReport r = eval(healthy(native: false));
      expect(r.state, ProtectionHealthState.attentionRequired);
      expect(
        r.issues
            .where((HealthIssue i) => i.code == HealthIssueCode.signalUnknown)
            .map((HealthIssue i) => i.component)
            .toList(),
        <HealthComponent>[HealthComponent.nativeHealth],
        reason: 'no per-signal duplicates when the whole snapshot is missing',
      );
      expect(r.components[HealthComponent.watcher], ComponentStatus.unknown);
      expect(
        r.components[HealthComponent.accessibilityDetection],
        ComponentStatus.unknown,
        reason: 'the bound signal is native; it is not assumed',
      );
      expect(ProtectionHealthEngine.accessibilityPath(healthy(native: false)),
          isNull);
    });
  });

  group('UNKNOWN and staleness', () {
    test('each unknown core signal yields ATTENTION, never SECURE', () {
      final Map<String, HealthSignals> cases = <String, HealthSignals>{
        'configured': healthy(configured: null),
        'native enforcement': healthy(nativeEnabled: null),
        'overlay': healthy(overlay: null),
        'accessibility': healthy(accessibility: null),
        'connected': healthy(connected: null),
        'usage': healthy(usage: null),
        'watcher': healthy(watcher: null),
        'shield': healthy(shield: null),
        'notifications': healthy(notifications: null),
        'restriction(api 30)': healthy(restricted: null, sdk: 30),
      };
      cases.forEach((String name, HealthSignals s) {
        final ProtectionHealthReport r = eval(s);
        expect(r.state, ProtectionHealthState.attentionRequired, reason: name);
        expect(r.hasIssue(HealthIssueCode.signalUnknown), isTrue, reason: name);
      });
    });

    test('snapshot older than maxAge cannot stay SECURE', () {
      final ProtectionHealthReport fresh = eval(healthy());
      final ProtectionHealthReport atLimit = ProtectionHealthEngine.reevaluate(
        fresh,
        now: t0.add(ProtectionHealthEngine.defaultMaxAge),
      );
      expect(atLimit.state, ProtectionHealthState.secure);
      final ProtectionHealthReport old = ProtectionHealthEngine.reevaluate(
        fresh,
        now: t0.add(
          ProtectionHealthEngine.defaultMaxAge +
              const Duration(milliseconds: 1),
        ),
      );
      expect(old.state, ProtectionHealthState.attentionRequired);
      expect(old.stale, isTrue);
      expect(ids(old), <String>['health_snapshot_stale']);
      expect(old.issues.single.action, HealthRepairAction.refresh);
    });

    test('future-dated snapshot (clock moved back) is stale', () {
      final ProtectionHealthReport r = eval(
        healthy(observedAt: t0.add(const Duration(seconds: 1))),
      );
      expect(r.stale, isTrue);
      expect(r.state, ProtectionHealthState.attentionRequired);
    });

    test('staleness never upgrades an OFFLINE report', () {
      final ProtectionHealthReport r = eval(
        healthy(overlay: false),
        now: t0.add(const Duration(hours: 1)),
      );
      expect(r.state, ProtectionHealthState.protectionOffline);
      expect(r.hasIssue(HealthIssueCode.healthSnapshotStale), isTrue);
    });

    test('exhaustive: SECURE iff every core signal is positively observed', () {
      // 3^9 combinations of the core signals (true / false / UNKNOWN):
      // overlay, a11y, bound, usage, watcher, shield, notifications,
      // restricted, native enforcement.
      const List<bool?> v = <bool?>[true, false, null];
      const int n = 9;
      int total = 1;
      for (int i = 0; i < n; i++) {
        total *= v.length;
      }
      int secure = 0;
      for (int code = 0; code < total; code++) {
        final List<bool?> x = <bool?>[];
        int rest = code;
        for (int i = 0; i < n; i++) {
          x.add(v[rest % v.length]);
          rest ~/= v.length;
        }
        final HealthSignals s = healthy(
          overlay: x[0],
          accessibility: x[1],
          connected: x[2],
          usage: x[3],
          watcher: x[4],
          shield: x[5],
          notifications: x[6],
          restricted: x[7],
          nativeEnabled: x[8],
        );
        final ProtectionHealthReport r = eval(s);
        final bool allPositive = x[0] == true &&
            x[1] == true &&
            x[2] == true &&
            x[3] == true &&
            x[4] == true &&
            x[5] == true &&
            x[6] == true &&
            x[7] == false &&
            x[8] == true;
        expect(
          r.state == ProtectionHealthState.secure,
          allPositive,
          reason: s.toJson().toString(),
        );
        if (r.state == ProtectionHealthState.secure) secure++;
        // OFFLINE only from a definite negative observation.
        final bool offlineExpected = x[0] == false ||
            x[8] == false ||
            (ProtectionHealthEngine.accessibilityPath(s) == false &&
                ProtectionHealthEngine.usageAccessPath(s) == false);
        expect(
          r.state == ProtectionHealthState.protectionOffline,
          offlineExpected,
          reason: s.toJson().toString(),
        );
      }
      expect(total, 19683);
      expect(secure, 1);
    });
  });

  group('background restriction health', () {
    test('Android "Restricted" background state is ATTENTION', () {
      final ProtectionHealthReport r = eval(healthy(restricted: true));
      expect(r.state, ProtectionHealthState.attentionRequired);
      expect(ids(r), <String>['background_restricted']);
      expect(r.issues.single.action, HealthRepairAction.openAppBatterySettings);
      expect(r.issues.single.detail['sdkInt'], '34');
    });

    test('below API 28 the restriction is unsupported, not invented', () {
      final ProtectionHealthReport r = eval(
        healthy(restricted: null, sdk: 27),
      );
      expect(r.state, ProtectionHealthState.secure);
      expect(
        r.components[HealthComponent.backgroundRestriction],
        ComponentStatus.unsupported,
      );
      expect(
        r.limitations,
        contains(HealthLimitation.backgroundRestrictionApiUnsupported),
      );
    });

    test('Battery Saver is advisory: reported, state unchanged', () {
      final ProtectionHealthReport r = eval(healthy(powerSave: true));
      expect(r.state, ProtectionHealthState.secure);
      expect(ids(r), <String>['battery_saver_on']);
      expect(r.issues.single.severity, HealthIssueSeverity.advisory);
    });
  });

  group('biometric health', () {
    test('biometric never makes core protection OFFLINE or ATTENTION', () {
      for (final (bool?, bool?, bool?) b in <(bool?, bool?, bool?)>[
        (false, false, false),
        (true, false, null),
        (true, true, false),
        (true, null, null),
        (null, null, null),
      ]) {
        final ProtectionHealthReport r = eval(
          healthy(
            biometricEnabled: b.$1,
            biometricHardware: b.$2,
            biometricEnrolled: b.$3,
          ),
        );
        expect(r.state, ProtectionHealthState.secure, reason: '$b');
      }
    });

    test('user-disabled biometric is intentional, with no issue', () {
      final ProtectionHealthReport r = eval(healthy(biometricEnabled: false));
      expect(r.components[HealthComponent.biometric],
          ComponentStatus.disabledByUser);
      expect(r.issues, isEmpty);
    });

    test('enabled biometric whose enrollment was removed is advisory', () {
      final ProtectionHealthReport r = eval(
        healthy(biometricEnabled: true, biometricEnrolled: false),
      );
      expect(ids(r), <String>['biometric_unavailable']);
      expect(r.issues.single.cause, HealthCause.notEnrolled);
      expect(r.issues.single.action, HealthRepairAction.openBiometricSettings);
      final ProtectionHealthReport noSensor = eval(
        healthy(biometricEnabled: true, biometricHardware: false),
      );
      expect(noSensor.issues.single.cause, HealthCause.unsupported);
      expect(noSensor.issues.single.action, isNull);
    });
  });

  test('recovery: returning capabilities restore SECURE', () {
    final List<HealthSignals> timeline = <HealthSignals>[
      healthy(),
      healthy(overlay: false),
      healthy(overlay: false, accessibility: false, usage: false),
      healthy(watcher: false),
      healthy(),
    ];
    expect(
      timeline.map((HealthSignals s) => eval(s).state).toList(),
      <ProtectionHealthState>[
        ProtectionHealthState.secure,
        ProtectionHealthState.protectionOffline,
        ProtectionHealthState.protectionOffline,
        ProtectionHealthState.attentionRequired,
        ProtectionHealthState.secure,
      ],
    );
  });
}
