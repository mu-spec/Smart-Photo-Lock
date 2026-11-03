// Phase 9 / M1 — unit tests for the Security Center summary model.
//
// Pure Dart: ProtectedAppsSummary counting rules and the Critical status
// mapping over REAL Phase 7 engine reports (ProtectionHealthEngine.evaluate).

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/protection/health/protection_health_engine.dart';
import 'package:smart_app_lock/ui/screens/security/security_center_summary.dart';

typedef _L = AppSecurityLevel;
typedef _C = CriticalProtectionStatus;

final DateTime _t0 = DateTime(2026, 11, 3, 12);

ProtectedApp _app(String pkg, _L level, {String? label}) => ProtectedApp(
      packageName: pkg,
      label: label ?? pkg,
      addedAt: DateTime(2026, 11, 1),
      securityLevel: level,
    );

HealthSignals _signals({bool? overlay = true, bool? usage = true}) =>
    HealthSignals(
      observedAt: _t0,
      protectionConfigured: true,
      credentialConfigured: true,
      hasProtectedApps: true,
      nativeProtectionEnabled: true,
      overlayGranted: overlay,
      overlayEverGranted: true,
      accessibilityEnabled: true,
      accessibilityEverGranted: true,
      accessibilityConnected: true,
      usageAccessGranted: usage,
      usageAccessEverGranted: true,
      nativeHealthAvailable: true,
      watcherRunning: true,
      watcherLastError: null,
      shieldArmed: true,
      notificationsGranted: true,
      backgroundRestricted: false,
      sdkInt: 34,
      powerSaveMode: false,
      biometricUnlockEnabled: false,
      biometricHardwarePresent: true,
      biometricEnrolled: true,
    );

ProtectionHealthReport _report(
  HealthSignals s, {
  Duration age = Duration.zero,
}) =>
    ProtectionHealthEngine.evaluate(s, now: _t0.add(age));

void main() {
  group('ProtectedAppsSummary', () {
    test('empty input → empty summary', () {
      final ProtectedAppsSummary s =
          ProtectedAppsSummary.fromApps(const <ProtectedApp>[]);
      expect(s.isEmpty, isTrue);
      expect(s.total, 0);
      expect(s.criticalLabels, isEmpty);
      expect(s.heldStricter, 0);
    });

    test('counts each saved level; total is their sum', () {
      final ProtectedAppsSummary s =
          ProtectedAppsSummary.fromApps(<ProtectedApp>[
        _app('a', _L.standard),
        _app('b', _L.standard),
        _app('c', _L.sensitive),
        _app('d', _L.critical, label: 'Bank'),
        _app('e', _L.critical, label: 'Mail'),
      ]);
      expect(<int>[s.standard, s.sensitive, s.critical], <int>[2, 1, 2]);
      expect(s.total, 5);
      for (final _L level in _L.values) {
        expect(
          s.countOf(level),
          switch (level) {
            _L.standard => 2,
            _L.sensitive => 1,
            _L.critical => 2,
          },
        );
      }
      expect(s.criticalLabels, <String>['Bank', 'Mail']);
    });

    test(
        'a duplicated package counts once, using the FIRST record (the '
        "matcher's record)", () {
      final ProtectedAppsSummary s =
          ProtectedAppsSummary.fromApps(<ProtectedApp>[
        _app('dup', _L.critical, label: 'First'),
        _app('dup', _L.standard, label: 'Second'),
        _app(' dup ', _L.sensitive),
      ]);
      expect(s.total, 1);
      expect(s.critical, 1);
      expect(s.standard, 0);
      expect(s.sensitive, 0);
      expect(s.criticalLabels, <String>['First']);
    });

    test('blank package names are ignored', () {
      final ProtectedAppsSummary s =
          ProtectedAppsSummary.fromApps(<ProtectedApp>[
        _app('', _L.critical),
        _app('   ', _L.standard),
        _app('ok', _L.sensitive),
      ]);
      expect(s.total, 1);
      expect(s.sensitive, 1);
    });

    test('a blank label falls back to the package name', () {
      final ProtectedAppsSummary s =
          ProtectedAppsSummary.fromApps(<ProtectedApp>[
        _app('com.x', _L.critical, label: '  '),
      ]);
      expect(s.criticalLabels, <String>['com.x']);
    });

    test(
        'heldStricter counts only apps whose native level is stricter than '
        'the saved level', () {
      final Map<String, _L?> native = <String, _L?>{
        'held': _L.critical, // saved standard → held
        'same': _L.sensitive, // saved sensitive → not held
        'lower': _L.standard, // saved critical → not held (upgrade pending)
        'unknown': null, // not confirmed → not counted
      };
      final ProtectedAppsSummary s = ProtectedAppsSummary.fromApps(
        <ProtectedApp>[
          _app('held', _L.standard),
          _app('same', _L.sensitive),
          _app('lower', _L.critical),
          _app('unknown', _L.standard),
        ],
        nativeLevelFor: (String pkg) => native[pkg],
      );
      expect(s.heldStricter, 1);
      // Counts stay the SAVED levels.
      expect(<int>[s.standard, s.sensitive, s.critical], <int>[2, 1, 1]);
    });

    test('the summary is computed without mutating the input', () {
      final List<ProtectedApp> apps = <ProtectedApp>[
        _app('a', _L.critical),
        _app('b', _L.standard),
      ];
      final List<ProtectedApp> copy = List<ProtectedApp>.of(apps);
      ProtectedAppsSummary.fromApps(apps);
      expect(apps, copy);
      expect(apps.map((ProtectedApp a) => a.securityLevel),
          <_L>[_L.critical, _L.standard]);
    });
  });

  group('CriticalProtectionStatus.of (maps Phase 7 state only)', () {
    test('no Critical apps → none, whatever the health', () {
      expect(_C.of(0, null), _C.none);
      expect(_C.of(0, _report(_signals())), _C.none);
      expect(_C.of(0, _report(_signals(overlay: false))), _C.none);
    });

    test('no report (checking, failed, never checked) → unconfirmed', () {
      expect(_C.of(2, null), _C.unconfirmed);
    });

    test('fresh SECURE → checksPassed', () {
      final ProtectionHealthReport r = _report(_signals());
      expect(r.state, ProtectionHealthState.secure);
      expect(_C.of(1, r), _C.checksPassed);
    });

    test('ATTENTION REQUIRED → attention', () {
      final ProtectionHealthReport r = _report(_signals(usage: false));
      expect(r.state, ProtectionHealthState.attentionRequired);
      expect(_C.of(1, r), _C.attention);
    });

    test('PROTECTION OFFLINE → offline (never checksPassed)', () {
      final ProtectionHealthReport r = _report(_signals(overlay: false));
      expect(r.state, ProtectionHealthState.protectionOffline);
      expect(_C.of(3, r), _C.offline);
    });

    test('a stale SECURE observation is never checksPassed', () {
      final ProtectionHealthReport r = _report(
        _signals(),
        age: ProtectionHealthEngine.defaultMaxAge + const Duration(seconds: 1),
      );
      expect(r.stale, isTrue);
      expect(r.state, isNot(ProtectionHealthState.secure));
      expect(_C.of(1, r), _C.attention);
    });

    test(
        'a future-dated observation (clock moved back) is never '
        'checksPassed', () {
      final ProtectionHealthReport r =
          _report(_signals(), age: const Duration(seconds: -5));
      expect(_C.of(1, r), isNot(_C.checksPassed));
    });

    test('unknown native signals are never checksPassed', () {
      final HealthSignals s = _signals();
      final ProtectionHealthReport r = ProtectionHealthEngine.evaluate(
        HealthSignals(
          observedAt: s.observedAt,
          protectionConfigured: true,
          credentialConfigured: true,
          hasProtectedApps: true,
          nativeProtectionEnabled: null,
          overlayGranted: true,
          overlayEverGranted: true,
          accessibilityEnabled: true,
          accessibilityEverGranted: true,
          accessibilityConnected: null,
          usageAccessGranted: true,
          usageAccessEverGranted: true,
          nativeHealthAvailable: false,
          watcherRunning: null,
          watcherLastError: null,
          shieldArmed: null,
          notificationsGranted: true,
          backgroundRestricted: false,
          sdkInt: 34,
          powerSaveMode: false,
          biometricUnlockEnabled: false,
          biometricHardwarePresent: true,
          biometricEnrolled: true,
        ),
        now: _t0,
      );
      expect(r.state, isNot(ProtectionHealthState.secure));
      expect(_C.of(1, r), isNot(_C.checksPassed));
    });
  });
}
