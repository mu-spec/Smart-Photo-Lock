// Phase 10 / M3 (PRD 10K): read-only Smart Rule diagnostics.
//
// Pure Dart (SmartRuleDiagnostics) plus the bootstrap's native-exchange
// record over AppContainer.inMemory with the static watcher standing in for
// native. SIMULATED; no device.

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/impl/smart_rule_repository_impl.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/rules/smart_rule_diagnostics.dart';
import 'package:smart_app_lock/rules/smart_rule_evaluator.dart';
import 'package:smart_app_lock/rules/smart_rule_policy.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/watcher_service.dart';

typedef _L = AppSecurityLevel;
typedef _A = SmartRuleAction;
typedef _Role = SmartRuleRole;

const String _bank = 'com.example.bank';
const String _chat = 'com.example.chat';

SmartRule _r(
  String id,
  String name,
  _A action, {
  List<String> targets = const <String>[_bank],
  List<int> days = SmartRuleDays.everyDay,
  SmartRuleTime time = const SmartRuleTime.allDay(),
  bool enabled = true,
}) =>
    SmartRule(
      id: id,
      name: name,
      targetPackages: targets,
      days: days,
      time: time,
      action: action,
      enabled: enabled,
    );

SmartRuleTime _w(int sh, int eh) =>
    SmartRuleTime.window(startMinute: sh * 60, endMinute: eh * 60);

/// Monday 2026-11-02 local.
DateTime _mon(int h, [int m = 0]) => DateTime(2026, 11, 2, h, m);

final List<SmartRule> _example = <SmartRule>[
  _r('work', 'Work Hours', _A.sensitive,
      days: SmartRuleDays.weekdays, time: _w(9, 17)),
  _r('banking', 'Banking Protection', _A.critical, time: _w(12, 14)),
  _r('night', 'Night', _A.critical, time: _w(22, 6)),
  _r('weekend', 'Weekend', _A.sensitive, days: SmartRuleDays.weekend),
  _r('off', 'Old Rule', _A.critical, enabled: false),
  _r('std', 'Plain', _A.standard),
  _r('chat-only', 'Chat', _A.critical, targets: const <String>[_chat]),
];

class _Db extends InMemoryLocalDatabase {
  bool failRuleReads = false;
  int ruleWrites = 0;

  @override
  Future<String?> getSetting(String key) {
    if (failRuleReads && key == SmartRuleRepositoryImpl.storageKey) {
      throw StateError('simulated rule read failure');
    }
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) {
    if (key == SmartRuleRepositoryImpl.storageKey) ruleWrites++;
    return super.setSetting(key, value);
  }
}

void main() {
  group('16–18. which rule decides, ties and non-match reasons', () {
    test('PRD example: Standard app, Work Hours + Banking Protection', () {
      final SmartRuleAppDiagnosis d = SmartRuleDiagnostics.diagnose(
        rules: _example,
        packageName: _bank,
        savedLevel: _L.standard,
        at: _mon(12, 30),
      );
      expect(d.savedLevel, _L.standard);
      expect(d.calculatedLevel, _L.critical);
      expect(d.decidedBy, SmartRuleDecision.rule);
      expect(d.decidingRuleId, 'banking');
      expect(d.tiedRuleIds, isEmpty);
      expect(d.entryFor('banking')!.role, _Role.decides);
      expect(d.entryFor('banking')!.contributed, isTrue);
      expect(d.entryFor('work')!.role, _Role.outranked);
      expect(d.entryFor('work')!.contributed, isFalse);
      expect(d.entryFor('std')!.role, _Role.addsNothing);
      expect(d.entryFor('night')!.role, _Role.notApplying);
      expect(d.entryFor('night')!.reason, SmartRuleReason.outsideTimeWindow);
      expect(d.entryFor('weekend')!.reason, SmartRuleReason.dayNotSelected);
      expect(d.entryFor('weekend')!.dayMatch, isFalse);
      expect(d.entryFor('weekend')!.timeMatch, isTrue);
      expect(d.entryFor('off')!.reason, SmartRuleReason.ruleDisabled);
      expect(d.entryFor('off')!.enabled, isFalse);
      expect(d.entryFor('chat-only')!.reason, SmartRuleReason.appNotTargeted);
      expect(d.entryFor('chat-only')!.appMatch, isFalse);
      // Display order: role, then id.
      expect(d.entries.map((SmartRuleDiagnosticEntry e) => e.ruleId), <String>[
        'banking',
        'work',
        'std',
        'chat-only',
        'night',
        'off',
        'weekend',
      ]);
      // The calculated level is exactly what enforcement computes.
      expect(
        SmartRulePolicy.effectiveLevel(_L.standard,
            SmartRulePolicy.ruleLevelFor(_example, _bank, _mon(12, 30))),
        d.calculatedLevel,
      );
    });

    test('17. ties: first sorted id decides, others are tied', () {
      final List<SmartRule> rules = <SmartRule>[
        _r('z', 'Z', _A.critical),
        _r('a', 'A', _A.critical, time: _w(9, 11)),
        _r('m', 'M', _A.critical),
      ];
      for (final List<SmartRule> order in <List<SmartRule>>[
        rules,
        rules.reversed.toList(),
      ]) {
        final SmartRuleAppDiagnosis d = SmartRuleDiagnostics.diagnose(
          rules: order,
          packageName: _bank,
          savedLevel: _L.standard,
          at: _mon(10),
        );
        expect(d.decidingRuleId, 'a');
        expect(d.tiedRuleIds, <String>['m', 'z']);
        expect(d.entryFor('m')!.role, _Role.tied);
        expect(d.entryFor('m')!.contributed, isTrue);
      }
      // Once 'a' ends, 'm' decides.
      expect(
        SmartRuleDiagnostics.diagnose(
          rules: rules,
          packageName: _bank,
          savedLevel: _L.standard,
          at: _mon(11),
        ).decidingRuleId,
        'm',
      );
    });

    test('saved level decides when no rule is stricter', () {
      final SmartRuleAppDiagnosis d = SmartRuleDiagnostics.diagnose(
        rules: _example,
        packageName: _bank,
        savedLevel: _L.critical,
        at: _mon(12, 30),
      );
      expect(d.calculatedLevel, _L.critical);
      expect(d.decidedBy, SmartRuleDecision.savedLevel);
      expect(d.decidingRuleId, isNull);
      expect(d.entryFor('banking')!.role, _Role.coveredBySaved);
      expect(d.entryFor('work')!.role, _Role.coveredBySaved);
      expect(d.entries.any((SmartRuleDiagnosticEntry e) => e.contributed),
          isFalse);
    });

    test('Sensitive app: Sensitive rule is covered, Critical rule decides', () {
      final SmartRuleAppDiagnosis d = SmartRuleDiagnostics.diagnose(
        rules: _example,
        packageName: _bank,
        savedLevel: _L.sensitive,
        at: _mon(12, 30),
      );
      expect(d.entryFor('work')!.role, _Role.coveredBySaved);
      expect(d.entryFor('banking')!.role, _Role.decides);
      expect(d.calculatedLevel, _L.critical);
    });

    test('unprotected app: rules have no effect, nothing is calculated', () {
      final SmartRuleAppDiagnosis d = SmartRuleDiagnostics.diagnose(
        rules: _example,
        packageName: _bank,
        savedLevel: null,
        at: _mon(12, 30),
      );
      expect(d.calculatedLevel, isNull);
      expect(d.decidedBy, SmartRuleDecision.notProtected);
      expect(d.decidingRuleId, isNull);
      expect(d.entryFor('banking')!.role, _Role.appNotProtected);
      expect(d.criticalFloorActive, isFalse);
    });

    test('18. overnight after-midnight day mismatch reports the owner day', () {
      final SmartRuleAppDiagnosis d = SmartRuleDiagnostics.diagnose(
        rules: <SmartRule>[
          _r('fri', 'Friday Night', _A.critical,
              days: const <int>[5], time: _w(22, 6)),
        ],
        packageName: _bank,
        savedLevel: _L.standard,
        at: _mon(1), // Monday 01:00 → owner day Sunday
      );
      final SmartRuleDiagnosticEntry e = d.entryFor('fri')!;
      expect(e.reason, SmartRuleReason.dayNotSelected);
      expect(e.evaluation.ownerDay, DateTime.sunday);
      expect(e.evaluation.segment, SmartRuleTimeSegment.overnightAfterMidnight);
    });

    test('invalid input: nothing matches, the saved level stands', () {
      final SmartRuleAppDiagnosis utc = SmartRuleDiagnostics.diagnose(
        rules: _example,
        packageName: _bank,
        savedLevel: _L.standard,
        at: _mon(12, 30).toUtc(),
      );
      expect(utc.calculatedLevel, _L.standard);
      expect(
          utc.entries.every((SmartRuleDiagnosticEntry e) =>
              e.reason == SmartRuleReason.nonLocalTime &&
              e.role == _Role.notApplying),
          isTrue);
      final SmartRuleAppDiagnosis bad = SmartRuleDiagnostics.diagnose(
        rules: _example,
        packageName: 'not a package',
        savedLevel: _L.standard,
        at: _mon(12, 30),
      );
      expect(bad.calculatedLevel, _L.standard);
      expect(bad.entries.first.appMatch, isNull);
    });
  });

  group('19–20. saved vs calculated vs confirmed; engine and native state', () {
    final List<SmartRule> saved = <SmartRule>[
      _r('banking', 'Banking', _A.critical, time: _w(12, 14)),
    ];
    final List<Map<String, Object?>> sent =
        SmartRulePolicy.nativeTransport(saved);

    test('confirmed ONLY for an applied ack of exactly these rules', () {
      expect(
        SmartRuleDiagnostics.nativeStateFor(
            saved,
            SmartRuleNativeRecord(
                status: SmartRuleSyncStatus.applied, sentRules: sent)),
        SmartRuleNativeState.confirmed,
      );
      expect(
        SmartRuleDiagnostics.nativeStateFor(
            saved,
            SmartRuleNativeRecord(
                status: SmartRuleSyncStatus.held, sentRules: sent)),
        SmartRuleNativeState.heldStricter,
      );
      for (final SmartRuleSyncStatus s in <SmartRuleSyncStatus>[
        SmartRuleSyncStatus.kept,
        SmartRuleSyncStatus.invalid,
        SmartRuleSyncStatus.unknown,
      ]) {
        expect(
          SmartRuleDiagnostics.nativeStateFor(
              saved, SmartRuleNativeRecord(status: s, sentRules: sent)),
          SmartRuleNativeState.notConfirmed,
          reason: s.name,
        );
      }
      // Applied, but for a DIFFERENT rule set (e.g. before the latest save).
      expect(
        SmartRuleDiagnostics.nativeStateFor(
            saved,
            const SmartRuleNativeRecord(
                status: SmartRuleSyncStatus.applied,
                sentRules: <Map<String, Object?>>[])),
        SmartRuleNativeState.notConfirmed,
      );
      // No rules sent (read failed) or a failed call.
      expect(
        SmartRuleDiagnostics.nativeStateFor(
            saved,
            const SmartRuleNativeRecord(
                status: SmartRuleSyncStatus.kept, sentRules: null)),
        SmartRuleNativeState.notConfirmed,
      );
      expect(
        SmartRuleDiagnostics.nativeStateFor(
            saved,
            SmartRuleNativeRecord(
                status: SmartRuleSyncStatus.applied,
                sentRules: sent,
                failed: true)),
        SmartRuleNativeState.notConfirmed,
      );
      expect(SmartRuleDiagnostics.nativeStateFor(saved, null),
          SmartRuleNativeState.notReported);
    });

    test('a calculated Critical level is never a confirmation', () {
      final SmartRuleAppDiagnosis d = SmartRuleDiagnostics.diagnose(
        rules: saved,
        packageName: _bank,
        savedLevel: _L.standard,
        at: _mon(12, 30),
        nativeState: SmartRuleDiagnostics.nativeStateFor(saved, null),
      );
      expect(d.calculatedLevel, _L.critical);
      expect(d.nativeState, SmartRuleNativeState.notReported);
    });

    test('engine state: not loaded, read failed, behind saved, in use', () {
      final SmartRuleEnforcementCache cache = SmartRuleEnforcementCache();
      expect(SmartRuleDiagnostics.engineStateFor(cache, saved),
          SmartRuleEngineState.notLoaded);
      cache.update(const <SmartRule>[]);
      expect(SmartRuleDiagnostics.engineStateFor(cache, saved),
          SmartRuleEngineState.behindSaved);
      cache.update(saved);
      expect(SmartRuleDiagnostics.engineStateFor(cache, saved),
          SmartRuleEngineState.inUse);
      // A rename is not an enforcement difference.
      expect(
          SmartRuleDiagnostics.engineStateFor(
              cache, <SmartRule>[saved.single.copyWith(name: 'Renamed')]),
          SmartRuleEngineState.inUse);
      cache.markReadFailed();
      expect(SmartRuleDiagnostics.engineStateFor(cache, saved),
          SmartRuleEngineState.readFailed);
      expect(SmartRuleDiagnostics.engineStateWithoutSaved(cache),
          SmartRuleEngineState.readFailed);
      expect(
        SmartRuleDiagnostics.diagnose(
          rules: saved,
          packageName: _bank,
          savedLevel: _L.standard,
          at: _mon(8),
          engineState: SmartRuleEngineState.readFailed,
        ).criticalFloorActive,
        isTrue,
      );
    });

    test(
        'bootstrap record: applied → confirmed, held → held, failed → not '
        'confirmed, failed read → not confirmed (SIMULATED)', () async {
      final _Db db = _Db();
      final AppContainer c = AppContainer.inMemory(
        apps: const <AppEntry>[AppEntry(packageName: _bank, label: 'Bank')],
        database: db,
        accessClock: () => _mon(12, 30),
      );
      final StaticWatcherService w = c.watcher as StaticWatcherService;
      w.ruleClock = () => _mon(12, 30);
      await c.auth.enrollPin('2468');
      await c.protectedApps.add(ProtectedApp(
          packageName: _bank, label: 'Bank', addedAt: DateTime(2026, 11, 1)));
      expect(c.protectionBootstrap.lastRuleExchange, isNull);

      await c.smartRules.saveRule(saved.single);
      expect(c.protectionBootstrap.lastRuleExchange, isNull,
          reason: 'saving alone is not a native exchange');
      await c.protectionBootstrap.synchronize();
      List<SmartRule> rules = (await c.smartRules.getRules()).valueOrNull!;
      expect(
          SmartRuleDiagnostics.nativeStateFor(
              rules, c.protectionBootstrap.lastRuleExchange),
          SmartRuleNativeState.confirmed);

      // An unconfirmed reduction (delete without CR-2) → held.
      await c.smartRules.deleteRule('banking');
      await c.protectionBootstrap.synchronize();
      rules = (await c.smartRules.getRules()).valueOrNull!;
      expect(rules, isEmpty);
      expect(
          SmartRuleDiagnostics.nativeStateFor(
              rules, c.protectionBootstrap.lastRuleExchange),
          SmartRuleNativeState.heldStricter);

      // A failed native write (persisted=false) → not confirmed.
      w.configureFault = (_) => StaticConfigureFault.failAfterApply;
      await c.smartRules.saveRule(saved.single);
      expect((await c.protectionBootstrap.synchronize()).isFailure, isTrue);
      rules = (await c.smartRules.getRules()).valueOrNull!;
      expect(c.protectionBootstrap.lastRuleExchange!.failed, isTrue);
      expect(
          SmartRuleDiagnostics.nativeStateFor(
              rules, c.protectionBootstrap.lastRuleExchange),
          SmartRuleNativeState.notConfirmed);

      // A failed rule read sends no rules → not confirmed; engine read failed.
      w.configureFault = null;
      db.failRuleReads = true;
      await c.protectionBootstrap.synchronize();
      expect(c.protectionBootstrap.lastRuleExchange!.sentRules, isNull);
      expect(
          SmartRuleDiagnostics.nativeStateFor(
              rules, c.protectionBootstrap.lastRuleExchange),
          SmartRuleNativeState.notConfirmed);
      expect(
          SmartRuleDiagnostics.engineStateFor(
              c.protectionBootstrap.ruleCache, rules),
          SmartRuleEngineState.readFailed);
    });
  });

  group('21–22. no sensitive state, no side effects', () {
    test('21. diagnosis and record carry no secret or authorization state',
        () async {
      final AppContainer c = AppContainer.inMemory(
        apps: const <AppEntry>[AppEntry(packageName: _bank, label: 'Bank')],
        accessClock: () => _mon(12, 30),
      );
      await c.auth.enrollPin('2468');
      await c.protectedApps.add(ProtectedApp(
          packageName: _bank, label: 'Bank', addedAt: DateTime(2026, 11, 1)));
      await c.smartRules.saveRule(_example[1]);
      await c.protectionBootstrap.synchronize();
      final SmartRuleAppDiagnosis d = SmartRuleDiagnostics.diagnose(
        rules: _example,
        packageName: _bank,
        savedLevel: _L.standard,
        at: _mon(12, 30),
        nativeState: SmartRuleDiagnostics.nativeStateFor(
            <SmartRule>[_example[1]], c.protectionBootstrap.lastRuleExchange),
      );
      final String dump = <Object?>[
        d,
        ...d.entries,
        ...d.entries.map((SmartRuleDiagnosticEntry e) => e.evaluation),
        d.resolution,
        c.protectionBootstrap.lastRuleExchange,
      ].join('\n');
      expect(dump, isNot(contains('2468')));
      expect(dump, isNot(contains(c.protectionBootstrap.session)));
      for (final String word in <String>[
        'ticket',
        'token',
        'pin',
        'pattern',
        'biometric',
        'challenge',
        'grant',
        'session',
      ]) {
        expect(dump.toLowerCase(), isNot(contains(word)), reason: word);
      }
    });

    test('22. diagnosing performs no write, sync or native call', () async {
      final _Db db = _Db();
      final AppContainer c = AppContainer.inMemory(
        apps: const <AppEntry>[AppEntry(packageName: _bank, label: 'Bank')],
        database: db,
        accessClock: () => _mon(12, 30),
      );
      final StaticWatcherService w = c.watcher as StaticWatcherService;
      await c.auth.enrollPin('2468');
      await c.protectedApps.add(ProtectedApp(
          packageName: _bank, label: 'Bank', addedAt: DateTime(2026, 11, 1)));
      await c.smartRules.saveRule(_example[1]);
      await c.protectionBootstrap.synchronize();
      final int writes = db.ruleWrites;
      final int configures = w.configureCalls;
      final int authorizes = w.authorizePackageCalls;
      final SmartRuleNativeRecord? record =
          c.protectionBootstrap.lastRuleExchange;
      final List<SmartRule> rules =
          (await c.smartRules.getRules()).valueOrNull!;
      for (int h = 0; h < 24; h++) {
        SmartRuleDiagnostics.diagnose(
          rules: rules,
          packageName: _bank,
          savedLevel: _L.standard,
          at: _mon(h),
          engineState: SmartRuleDiagnostics.engineStateFor(
              c.protectionBootstrap.ruleCache, rules),
          nativeState: SmartRuleDiagnostics.nativeStateFor(rules, record),
        );
      }
      expect(db.ruleWrites, writes);
      expect(w.configureCalls, configures);
      expect(w.authorizePackageCalls, authorizes);
      expect(identical(c.protectionBootstrap.lastRuleExchange, record), isTrue);
      expect(w.authorizedPackages, isEmpty);
    });
  });
}
