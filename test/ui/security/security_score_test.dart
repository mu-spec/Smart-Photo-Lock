// Phase 9 / M2 (PRD 9E) — Security Score model (PRODUCTION code, pure Dart).
//
// The real calculator over real Phase 7 reports (ProtectionHealthEngine
// with explicit signal values) and real ProtectedApp / AppSecurityLevel
// records. SIMULATED: no Android device, native enforcement or OEM
// behaviour is observed. The expected values are the documented
// formula (docs/architecture.md, "Security Score"; spec §2–§7).

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/protection/health/protection_health_engine.dart';
import 'package:smart_app_lock/ui/screens/security/security_score.dart';

typedef _L = AppSecurityLevel;

final DateTime t0 = DateTime(2026, 11, 3, 10);

HealthSignals _signals({
  bool? configured = true,
  bool? credential = true,
  bool? apps = true,
  bool? overlay = true,
  bool? usage = true,
  bool? watcher = true,
  bool? restricted = false,
  bool? powerSave = false,
  bool? biometricEnabled = false,
  bool? biometricHardware = true,
  bool? biometricEnrolled = true,
  DateTime? observedAt,
}) =>
    HealthSignals(
      observedAt: observedAt ?? t0,
      protectionConfigured: configured,
      credentialConfigured: credential,
      hasProtectedApps: apps,
      nativeProtectionEnabled: true,
      overlayGranted: overlay,
      overlayEverGranted: true,
      accessibilityEnabled: true,
      accessibilityEverGranted: true,
      accessibilityConnected: true,
      usageAccessGranted: usage,
      usageAccessEverGranted: true,
      nativeHealthAvailable: true,
      watcherRunning: watcher,
      shieldArmed: true,
      notificationsGranted: true,
      backgroundRestricted: restricted,
      sdkInt: 34,
      powerSaveMode: powerSave,
      biometricUnlockEnabled: biometricEnabled,
      biometricHardwarePresent: biometricHardware,
      biometricEnrolled: biometricEnrolled,
    );

ProtectionHealthReport _report(HealthSignals s, {DateTime? now}) =>
    ProtectionHealthEngine.evaluate(s, now: now ?? t0);

final ProtectionHealthReport secure = _report(_signals());

/// ATTENTION REQUIRED: Usage Access missing (Accessibility still works).
final ProtectionHealthReport attention = _report(_signals(usage: false));

/// PROTECTION OFFLINE: the overlay permission was revoked.
final ProtectionHealthReport offline = _report(_signals(overlay: false));

ProtectedApp _app(String pkg, _L level) => ProtectedApp(
      packageName: pkg,
      label: pkg,
      addedAt: DateTime(2026, 11, 1),
      securityLevel: level,
    );

/// Apps whose native-confirmed level equals the saved one.
SecurityScoreAssessment _assess({
  ProtectionHealthReport? health,
  Map<String, _L> apps = const <String, _L>{},
  List<ProtectedApp>? records,
  Duration? grace = Duration.zero,
  Map<String, _L>? native,
  ScoreSourceState appsState = ScoreSourceState.loaded,
  ScoreSourceState graceState = ScoreSourceState.loaded,
  bool checking = false,
  bool failed = false,
  bool useHealth = true,
}) {
  final List<ProtectedApp> list = records ??
      <ProtectedApp>[
        for (final MapEntry<String, _L> e in apps.entries) _app(e.key, e.value),
      ];
  final Map<String, _L> confirmed = native ?? apps;
  return SecurityScore.assess(
    SecurityScoreInputs(
      appsState: appsState,
      apps: List<ProtectedApp>.unmodifiable(list),
      nativeLevelFor: (String pkg) => confirmed[pkg],
      graceState: graceState,
      grace: grace,
      health: useHealth ? (health ?? secure) : null,
      healthChecking: checking,
      healthFailed: failed,
    ),
  );
}

const List<Duration> _graceOptions = <Duration>[
  Duration.zero,
  Duration(seconds: 30),
  Duration(minutes: 1),
  Duration(minutes: 5),
];

void main() {
  group('formula and weights (spec §2–§3)', () {
    test('1. weights are 60 + 40 = 100 points, four credit units per app', () {
      expect(SecurityScore.healthPoints, 60);
      expect(SecurityScore.relockPoints, 40);
      expect(
        SecurityScore.healthPoints + SecurityScore.relockPoints,
        SecurityScore.maxPoints,
      );
      expect(SecurityScore.maxPoints, 100);
      expect(SecurityScore.maxCredit, 4);
    });

    test('2. re-lock tiers by effective grace, inclusive upper bounds', () {
      final Map<Duration, RelockTier> cases = <Duration, RelockTier>{
        Duration.zero: RelockTier.noDelay,
        const Duration(seconds: 1): RelockTier.upTo15Seconds,
        const Duration(seconds: 15): RelockTier.upTo15Seconds,
        const Duration(seconds: 16): RelockTier.upTo1Minute,
        const Duration(seconds: 60): RelockTier.upTo1Minute,
        const Duration(seconds: 61): RelockTier.upTo5Minutes,
        const Duration(minutes: 5): RelockTier.upTo5Minutes,
        const Duration(minutes: 5, seconds: 1): RelockTier.longer,
        const Duration(hours: 2): RelockTier.longer,
      };
      cases.forEach((Duration d, RelockTier t) {
        expect(RelockTier.of(d), t, reason: '$d');
      });
      expect(
        RelockTier.values.map((RelockTier t) => t.credit).toList(),
        <int>[4, 3, 2, 1, 0],
      );
    });

    test('3. F2 = floor(10 x sum(credit) / n); clamped credits; 0 apps -> 0',
        () {
      expect(SecurityScore.relockScoreOf(const <int>[]), 0);
      expect(SecurityScore.relockScoreOf(const <int>[4]), 40);
      expect(SecurityScore.relockScoreOf(const <int>[4, 4]), 40);
      expect(SecurityScore.relockScoreOf(const <int>[4, 3, 2]), 30);
      expect(SecurityScore.relockScoreOf(const <int>[4, 2, 2]), 26,
          reason: '26.67 rounds DOWN');
      expect(SecurityScore.relockScoreOf(const <int>[3]), 30);
      expect(SecurityScore.relockScoreOf(const <int>[2]), 20);
      expect(SecurityScore.relockScoreOf(const <int>[1]), 10);
      expect(SecurityScore.relockScoreOf(const <int>[0]), 0);
      expect(SecurityScore.relockScoreOf(const <int>[4, 0]), 20);
      expect(SecurityScore.relockScoreOf(const <int>[1, 0, 0]), 3,
          reason: '3.33 rounds DOWN');
      expect(SecurityScore.relockScoreOf(const <int>[9]), 40, reason: 'clamp');
      expect(SecurityScore.relockScoreOf(const <int>[-3]), 0, reason: 'clamp');
    });

    test(
        '4. credited level: native unknown -> Standard; otherwise the less '
        'strict of saved and native', () {
      for (final _L saved in _L.values) {
        expect(SecurityScore.creditedLevel(saved, null), _L.standard);
        for (final _L native in _L.values) {
          final _L expected = saved.rank <= native.rank ? saved : native;
          expect(SecurityScore.creditedLevel(saved, native), expected,
              reason: 'saved $saved, native $native');
        }
      }
    });

    test('5. the documented examples (spec §7) give the exact values', () {
      // SECURE; Critical + Sensitive + Standard; 1 minute: 60 + 30.
      SecurityScoreAssessment a = _assess(
        apps: <String, _L>{
          'bank': _L.critical,
          'chat': _L.sensitive,
          'p': _L.standard
        },
        grace: const Duration(minutes: 1),
      );
      expect((a.status, a.points, a.healthEarned, a.relockEarned),
          (SecurityScoreStatus.available, 90, 60, 30));

      // SECURE; 2 x Standard; Immediate: 60 + 40.
      a = _assess(apps: <String, _L>{'a': _L.standard, 'b': _L.standard});
      expect((a.points, a.relockEarned, a.pointsLost), (100, 40, 0));

      // SECURE; 1 x Standard; 5 minutes: 60 + 10.
      a = _assess(
        apps: <String, _L>{'a': _L.standard},
        grace: const Duration(minutes: 5),
      );
      expect(a.points, 70);

      // ATTENTION; Critical + Standard; 30 s: 0 + floor(10 x 6 / 2) = 30.
      a = _assess(
        health: attention,
        apps: <String, _L>{'bank': _L.critical, 'p': _L.standard},
        grace: const Duration(seconds: 30),
      );
      expect((a.status, a.points, a.healthEarned, a.relockEarned),
          (SecurityScoreStatus.provisional, 30, 0, 30));

      // SECURE; pending downgrade (saved Standard, native Critical); 5 min.
      a = _assess(
        apps: <String, _L>{'bank': _L.standard},
        native: <String, _L>{'bank': _L.critical},
        grace: const Duration(minutes: 5),
      );
      expect((a.points, a.heldStricter, a.unconfirmedLevels), (70, 1, 0));

      // SECURE; saved Critical, native unknown; 5 min -> counted Standard.
      a = _assess(
        apps: <String, _L>{'bank': _L.critical},
        native: const <String, _L>{},
        grace: const Duration(minutes: 5),
      );
      expect((a.points, a.heldStricter, a.unconfirmedLevels), (70, 0, 1));

      // SECURE; Critical + 2 x Standard; 30 s: 60 + floor(26.67).
      a = _assess(
        apps: <String, _L>{
          'bank': _L.critical,
          'a': _L.standard,
          'b': _L.standard
        },
        grace: const Duration(seconds: 30),
      );
      expect(a.points, 86);
    });

    test(
        '6. breakdown totals: points = F1 + F2, tier counts sum to the app '
        'count, F2 matches the tiers (all levels x grace options x health)',
        () {
      for (final ProtectionHealthReport h in <ProtectionHealthReport>[
        secure,
        attention,
      ]) {
        for (final Duration g in _graceOptions) {
          for (final _L a in _L.values) {
            for (final _L b in _L.values) {
              final SecurityScoreAssessment r = _assess(
                health: h,
                apps: <String, _L>{'a': a, 'b': b},
                grace: g,
              );
              expect(r.points, r.healthEarned! + r.relockEarned!);
              expect(
                r.tierCounts.values.fold<int>(0, (int x, int y) => x + y),
                r.appCount,
              );
              final List<int> credits = <int>[
                for (final MapEntry<RelockTier, int> e in r.tierCounts.entries)
                  for (int i = 0; i < e.value; i++) e.key.credit,
              ];
              expect(r.relockEarned, SecurityScore.relockScoreOf(credits));
              expect(r.points, inInclusiveRange(0, 100));
            }
          }
        }
      }
    });
  });

  group('availability and uncertainty (spec §4)', () {
    test(
        '7. first-time setup: no credential and no apps -> setup needed, no '
        'number', () {
      final SecurityScoreAssessment a = _assess(
        health: _report(
          _signals(configured: false, credential: false, apps: false),
        ),
      );
      expect(a.status, SecurityScoreStatus.setupNeeded);
      expect(a.points, isNull);
      expect(a.needsApps, isTrue);
      expect(a.needsCredential, isTrue);
      expect(a.status.hasPoints, isFalse);
    });

    test('8. no protected apps (credential set) -> setup needed, no number',
        () {
      final SecurityScoreAssessment a = _assess(
        health: _report(_signals(configured: false, apps: false)),
      );
      expect(a.status, SecurityScoreStatus.setupNeeded);
      expect((a.needsApps, a.needsCredential), (true, false));
      expect(a.points, isNull);

      // Health unknown: still setup (the repository is reliable), and the
      // credential is not claimed either way.
      final SecurityScoreAssessment b = _assess(useHealth: false);
      expect(b.status, SecurityScoreStatus.setupNeeded);
      expect(b.needsCredential, isNull);
    });

    test(
        '8b. apps saved but health reports protection not configured '
        '(credential missing) -> setup needed', () {
      final SecurityScoreAssessment a = _assess(
        health: _report(_signals(configured: false, credential: false)),
        apps: <String, _L>{'a': _L.critical},
      );
      expect(a.status, SecurityScoreStatus.setupNeeded);
      expect((a.needsApps, a.needsCredential), (false, true));
    });

    test('9. SECURE (fresh) with a valid setup -> available', () {
      final SecurityScoreAssessment a =
          _assess(apps: <String, _L>{'a': _L.sensitive});
      expect(a.status, SecurityScoreStatus.available);
      expect(a.healthEarned, 60);
      expect(a.topProblem, isNull);
    });

    test(
        '10. ATTENTION -> provisional: health counts 0, the top problem is '
        'reported, never above 40', () {
      final SecurityScoreAssessment a =
          _assess(health: attention, apps: <String, _L>{'a': _L.critical});
      expect(a.status, SecurityScoreStatus.provisional);
      expect(a.healthEarned, 0);
      expect(a.points, 40);
      expect(a.topProblem?.code, HealthIssueCode.usageAccessUnavailable);

      final SecurityScoreAssessment restricted = _assess(
        health: _report(_signals(restricted: true)),
        apps: <String, _L>{'a': _L.standard},
      );
      expect(restricted.status, SecurityScoreStatus.provisional);
      expect(restricted.topProblem?.code, HealthIssueCode.backgroundRestricted);
    });

    test('11. any provisional score is below any available score', () {
      int maxProvisional = -1;
      int minAvailable = 1000;
      for (final Duration g in <Duration>[
        ..._graceOptions,
        const Duration(hours: 1)
      ]) {
        for (final _L level in _L.values) {
          final int p = _assess(
            health: attention,
            apps: <String, _L>{'a': level},
            grace: g,
          ).points!;
          final int s =
              _assess(apps: <String, _L>{'a': level}, grace: g).points!;
          if (p > maxProvisional) maxProvisional = p;
          if (s < minAvailable) minAvailable = s;
        }
      }
      expect(maxProvisional, 40);
      expect(minAvailable, 60);
      expect(maxProvisional < minAvailable, isTrue);
    });

    test(
        '12. OFFLINE -> no score, even with every app Critical and '
        'Immediate re-lock', () {
      final SecurityScoreAssessment a = _assess(
        health: offline,
        apps: <String, _L>{'a': _L.critical, 'b': _L.critical},
      );
      expect(a.status, SecurityScoreStatus.withheldOffline);
      expect(a.points, isNull);
      expect(a.healthEarned, isNull);
      expect(a.relockEarned, isNull);

      final SecurityScoreAssessment watcherDown = _assess(
        health: _report(_signals(watcher: false, usage: true)),
        apps: <String, _L>{'a': _L.standard},
      );
      // Watcher down is ATTENTION or OFFLINE per Phase 7; never available.
      expect(watcherDown.status, isNot(SecurityScoreStatus.available));
    });

    test(
        '13. stale health (older than the freshness limit, or future-dated) '
        '-> unavailable, never a confident score', () {
      final ProtectionHealthReport aged = _report(
        _signals(),
        now: t0.add(ProtectionHealthEngine.defaultMaxAge).add(
              const Duration(seconds: 1),
            ),
      );
      expect(aged.stale, isTrue);
      SecurityScoreAssessment a =
          _assess(health: aged, apps: <String, _L>{'a': _L.critical});
      expect((
        a.status,
        a.reason,
        a.points
      ), (
        SecurityScoreStatus.unavailable,
        ScoreUnavailableReason.healthStale,
        null
      ));

      final ProtectionHealthReport future = _report(
        _signals(observedAt: t0.add(const Duration(minutes: 1))),
      );
      a = _assess(health: future, apps: <String, _L>{'a': _L.critical});
      expect(a.reason, ScoreUnavailableReason.healthStale);

      // Exactly at the limit is still fresh.
      final ProtectionHealthReport edge = _report(
        _signals(),
        now: t0.add(ProtectionHealthEngine.defaultMaxAge),
      );
      expect(
        _assess(health: edge, apps: <String, _L>{'a': _L.critical}).status,
        SecurityScoreStatus.available,
      );
    });

    test(
        '14. unknown health: checking -> assessing; failed -> unavailable; '
        'never checked -> unavailable', () {
      final Map<String, _L> apps = <String, _L>{'a': _L.standard};
      expect(
        _assess(useHealth: false, apps: apps, checking: true).status,
        SecurityScoreStatus.assessing,
      );
      expect(
        _assess(useHealth: false, apps: apps, failed: true).reason,
        ScoreUnavailableReason.healthFailed,
      );
      final SecurityScoreAssessment never =
          _assess(useHealth: false, apps: apps);
      expect((
        never.status,
        never.reason,
        never.points
      ), (
        SecurityScoreStatus.unavailable,
        ScoreUnavailableReason.healthNotChecked,
        null
      ));
    });

    test(
        '15. failed repository read -> unavailable (never 0), even with '
        'SECURE health; it wins over setup', () {
      final SecurityScoreAssessment a = _assess(
        appsState: ScoreSourceState.failed,
        apps: <String, _L>{'a': _L.critical},
      );
      expect((
        a.status,
        a.reason,
        a.points
      ), (
        SecurityScoreStatus.unavailable,
        ScoreUnavailableReason.appsUnreadable,
        null
      ));
      // An empty list is not shown as "setup" when the read failed.
      expect(
        _assess(appsState: ScoreSourceState.failed).status,
        SecurityScoreStatus.unavailable,
      );
    });

    test('16. loading inputs -> assessing, never a default number', () {
      expect(
        _assess(appsState: ScoreSourceState.loading).status,
        SecurityScoreStatus.assessing,
      );
      final SecurityScoreAssessment g = _assess(
        apps: <String, _L>{'a': _L.standard},
        graceState: ScoreSourceState.loading,
        grace: null,
      );
      expect((g.status, g.points), (SecurityScoreStatus.assessing, null));
    });

    test('17. re-lock setting read failure -> unavailable (settings)', () {
      for (final SecurityScoreAssessment a in <SecurityScoreAssessment>[
        _assess(
          apps: <String, _L>{'a': _L.critical},
          graceState: ScoreSourceState.failed,
          grace: null,
        ),
        _assess(apps: <String, _L>{'a': _L.critical}, grace: null),
      ]) {
        expect((
          a.status,
          a.reason,
          a.points
        ), (
          SecurityScoreStatus.unavailable,
          ScoreUnavailableReason.settingsUnreadable,
          null
        ));
      }
    });
  });

  group('levels and re-lock (spec §3, §6)', () {
    test(
        '18. Standard / Sensitive / Critical at each grace option give the '
        'documented F2', () {
      // Expected F2 per [level][grace option] (Immediate, 30 s, 1 min, 5 min).
      const Map<_L, List<int>> expected = <_L, List<int>>{
        _L.standard: <int>[40, 20, 20, 10],
        _L.sensitive: <int>[40, 30, 30, 30],
        _L.critical: <int>[40, 40, 40, 40],
      };
      expected.forEach((_L level, List<int> points) {
        for (int i = 0; i < _graceOptions.length; i++) {
          final SecurityScoreAssessment a = _assess(
            apps: <String, _L>{'x': level},
            grace: _graceOptions[i],
          );
          expect(a.relockEarned, points[i],
              reason: '$level at ${_graceOptions[i]}');
        }
      });
    });

    test(
        '19. held-stricter native level (pending downgrade): counted at the '
        'lower SAVED level and reported as held', () {
      final SecurityScoreAssessment a = _assess(
        apps: <String, _L>{'bank': _L.standard, 'chat': _L.sensitive},
        native: <String, _L>{'bank': _L.critical, 'chat': _L.critical},
        grace: const Duration(minutes: 5),
      );
      expect(a.heldStricter, 2);
      expect(a.unconfirmedLevels, 0);
      // Standard @5 min = 1, Sensitive @5 min (15 s cap) = 3 -> floor(20).
      expect(a.relockEarned, 20);
      expect(a.tierCounts[RelockTier.noDelay], 0,
          reason: 'the stricter native hold earns no extra points');
    });

    test(
        '20. an unconfirmed level change never counts as enforcement: saved '
        'stricter than native (or native unknown) is credited lower', () {
      final SecurityScoreAssessment upgrade = _assess(
        apps: <String, _L>{'bank': _L.critical},
        native: <String, _L>{'bank': _L.sensitive},
        grace: const Duration(minutes: 5),
      );
      expect(upgrade.unconfirmedLevels, 1);
      expect(upgrade.relockEarned, 30, reason: 'credited Sensitive');

      final SecurityScoreAssessment unknown = _assess(
        apps: <String, _L>{'bank': _L.sensitive, 'p': _L.standard},
        native: const <String, _L>{},
        grace: const Duration(minutes: 5),
      );
      expect(unknown.unconfirmedLevels, 1,
          reason: 'Standard without a native level is not "unconfirmed"');
      expect(unknown.relockEarned, 10, reason: 'both credited Standard');
    });

    test(
        '21. malformed stored level reads Critical (Phase 8) but cannot earn '
        'more than native confirms', () {
      final _L malformed = AppSecurityLevel.fromStorage('CRITICAL?!');
      expect(malformed, _L.critical);
      final SecurityScoreAssessment a = _assess(
        apps: <String, _L>{'x': malformed},
        native: const <String, _L>{},
        grace: const Duration(minutes: 5),
      );
      expect(a.relockEarned, 10);
      expect(a.unconfirmedLevels, 1);
    });

    test(
        '22. raising a confirmed level or shortening the grace never lowers '
        'the score; changing either is reflected at once', () {
      for (final Duration g in _graceOptions) {
        int previous = -1;
        for (final _L level in _L.values) {
          final int p =
              _assess(apps: <String, _L>{'x': level}, grace: g).points!;
          expect(p >= previous, isTrue, reason: '$level at $g');
          previous = p;
        }
      }
      for (final _L level in _L.values) {
        int previous = 1000;
        for (final Duration g in _graceOptions) {
          final int p =
              _assess(apps: <String, _L>{'x': level}, grace: g).points!;
          expect(p <= previous, isTrue, reason: '$level at $g');
          previous = p;
        }
      }
      expect(
        _assess(
                apps: <String, _L>{'x': _L.standard},
                grace: const Duration(minutes: 1))
            .points,
        80,
      );
      expect(
        _assess(
                apps: <String, _L>{'x': _L.critical},
                grace: const Duration(minutes: 1))
            .points,
        100,
      );
    });

    test('23. the number of protected apps is not rewarded', () {
      final int one = _assess(apps: <String, _L>{'a': _L.standard}).points!;
      final int many = _assess(apps: <String, _L>{
        for (int i = 0; i < 25; i++) 'app$i': _L.standard,
      }).points!;
      expect(one, many);
      final int mixedFew = _assess(
        apps: <String, _L>{'a': _L.critical, 'b': _L.standard},
        grace: const Duration(minutes: 5),
      ).points!;
      final int mixedMore = _assess(
        apps: <String, _L>{
          'a': _L.critical,
          'b': _L.standard,
          'c': _L.critical,
          'd': _L.standard,
        },
        grace: const Duration(minutes: 5),
      ).points!;
      expect(mixedFew, mixedMore, reason: 'same proportions, same score');
    });

    test(
        '24. deduplication matches the M1 summary: first record wins, blank '
        'packages ignored; only blanks -> setup', () {
      final SecurityScoreAssessment a = _assess(
        records: <ProtectedApp>[
          _app('bank', _L.critical),
          _app('bank', _L.standard),
          _app('  ', _L.standard),
        ],
        native: <String, _L>{'bank': _L.critical},
        grace: const Duration(minutes: 5),
      );
      expect(a.appCount, 1);
      expect(a.relockEarned, 40);
      expect(
        _assess(records: <ProtectedApp>[_app(' ', _L.critical)]).status,
        SecurityScoreStatus.setupNeeded,
      );
    });

    test('25. a negative stored grace is treated as no delay', () {
      expect(
        _assess(
                apps: <String, _L>{'a': _L.standard},
                grace: const Duration(seconds: -5))
            .relockEarned,
        40,
      );
    });
  });

  group('not scored (spec §1)', () {
    test(
        '26. biometric unavailable, not enrolled or not enabled is never '
        'penalised and never rewarded', () {
      final Map<String, _L> apps = <String, _L>{'a': _L.sensitive};
      final List<HealthSignals> variants = <HealthSignals>[
        _signals(),
        _signals(biometricEnabled: true),
        _signals(biometricEnabled: true, biometricHardware: false),
        _signals(biometricEnabled: true, biometricEnrolled: false),
        _signals(biometricEnabled: null, biometricHardware: null),
      ];
      final Set<(SecurityScoreStatus, int?)> results =
          <(SecurityScoreStatus, int?)>{
        for (final HealthSignals s in variants)
          () {
            final SecurityScoreAssessment a =
                _assess(health: _report(s), apps: apps);
            return (a.status, a.points);
          }(),
      };
      expect(results, <(SecurityScoreStatus, int?)>{
        (SecurityScoreStatus.available, 100),
      });
    });

    test('27. Battery Saver (a Phase 7 advisory) does not change the score',
        () {
      final Map<String, _L> apps = <String, _L>{'a': _L.standard};
      expect(
        _assess(health: _report(_signals(powerSave: true)), apps: apps).points,
        _assess(apps: apps).points,
      );
    });
  });

  group('determinism and read-only (spec §8)', () {
    test('28. same inputs -> same result; inputs are not modified', () {
      final List<ProtectedApp> records = List<ProtectedApp>.unmodifiable(
        <ProtectedApp>[_app('a', _L.critical), _app('b', _L.standard)],
      );
      int nativeCalls = 0;
      SecurityScoreAssessment run() => SecurityScore.assess(
            SecurityScoreInputs(
              appsState: ScoreSourceState.loaded,
              apps: records,
              nativeLevelFor: (String pkg) {
                nativeCalls++;
                return pkg == 'a' ? _L.critical : _L.standard;
              },
              graceState: ScoreSourceState.loaded,
              grace: const Duration(seconds: 30),
              health: secure,
            ),
          );
      final SecurityScoreAssessment first = run();
      final SecurityScoreAssessment second = run();
      expect(first.points, second.points);
      expect(first.tierCounts, second.tierCounts);
      expect(nativeCalls, 4, reason: 'one read-only lookup per app per run');
      expect(records.map((ProtectedApp a) => a.securityLevel).toList(),
          <_L>[_L.critical, _L.standard]);
      expect(() => first.tierCounts[RelockTier.longer] = 1,
          throwsUnsupportedError);
    });
  });
}
