// Phase 10 / M2 (PRD 10F): raise-only Smart Rule semantics, v1 → v2
// migration and schema handling.
//
// Pure Dart (no device, no native). Native mirrors these semantics in
// SmartRulePolicy.kt and is covered by SmartRuleEnforcementTest.kt.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/repositories/impl/smart_rule_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/smart_rule_repository.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/rules/smart_rule_document.dart';
import 'package:smart_app_lock/rules/smart_rule_policy.dart';

typedef _L = AppSecurityLevel;
typedef _A = SmartRuleAction;

const String _bank = 'com.example.bank';
const String _chat = 'com.example.chat';

/// 2026-11-02 is a Monday.
DateTime _mon(int h, [int m = 0]) => DateTime(2026, 11, 2, h, m);
DateTime _tue(int h, [int m = 0]) => DateTime(2026, 11, 3, h, m);
DateTime _sun(int h, [int m = 0]) => DateTime(2026, 11, 8, h, m);

SmartRule _rule({
  String id = 'r1',
  List<String> targets = const <String>[_bank],
  List<int> days = SmartRuleDays.everyDay,
  SmartRuleTime time = const SmartRuleTime.allDay(),
  _A action = _A.critical,
  bool enabled = true,
}) =>
    SmartRule(
      id: id,
      name: 'Rule $id',
      targetPackages: targets,
      days: days,
      time: time,
      action: action,
      enabled: enabled,
    );

SmartRuleTime _win(int startH, int endH) =>
    SmartRuleTime.window(startMinute: startH * 60, endMinute: endH * 60);

void main() {
  group('1–3. baseline floor: rules only raise', () {
    test('1. effective = max(baseline, rule) for every baseline × action', () {
      for (final _L baseline in _L.values) {
        for (final _A action in _A.levelActions) {
          final AppSecurityLevel? rule = SmartRulePolicy.ruleLevelFor(
            <SmartRule>[_rule(action: action)],
            _bank,
            _mon(12),
          );
          final AppSecurityLevel effective =
              SmartRulePolicy.effectiveLevel(baseline, rule);
          expect(effective.rank >= baseline.rank, isTrue,
              reason: '$baseline × $action never below the baseline');
          final _L expected = action.raisesTo == null ||
                  !action.raisesTo!.isStricterThan(baseline)
              ? baseline
              : action.raisesTo!;
          expect(effective, expected, reason: '$baseline × $action');
        }
      }
    });

    test('2. Standard and Unlocked never take part (no lower, no unlock)', () {
      for (final _A a in <_A>[_A.standard, _A.unlocked]) {
        expect(a.raisesTo, isNull);
        expect(a.canRaise, isFalse);
        expect(
          SmartRulePolicy.ruleLevelFor(
              <SmartRule>[_rule(action: a)], _bank, _mon(12)),
          isNull,
        );
        for (final _L b in _L.values) {
          expect(SmartRulePolicy.effectiveLevel(b, null), b);
        }
      }
      // Never sent to native either.
      expect(
        SmartRulePolicy.nativeTransport(<SmartRule>[
          _rule(id: 'a', action: _A.standard),
          _rule(id: 'b', action: _A.unlocked),
        ]),
        isEmpty,
      );
    });

    test('3. disabled, non-target and UTC instants never match', () {
      expect(
        SmartRulePolicy.ruleLevelFor(
            <SmartRule>[_rule(enabled: false)], _bank, _mon(12)),
        isNull,
      );
      expect(
        SmartRulePolicy.ruleLevelFor(<SmartRule>[_rule()], _chat, _mon(12)),
        isNull,
      );
      expect(
        SmartRulePolicy.ruleLevelFor(
          <SmartRule>[_rule()],
          _bank,
          DateTime.utc(2026, 11, 2, 12),
        ),
        isNull,
        reason: 'local-time contract: a UTC instant is never evaluated',
      );
    });
  });

  group('4–5. conditions', () {
    test('4. overnight window belongs to its start day; end exclusive', () {
      final List<SmartRule> rules = <SmartRule>[
        _rule(days: <int>[7], time: _win(22, 2), action: _A.sensitive),
      ];
      expect(SmartRulePolicy.ruleLevelFor(rules, _bank, _sun(21, 59)), isNull);
      expect(
          SmartRulePolicy.ruleLevelFor(rules, _bank, _sun(22)), _L.sensitive);
      expect(
          SmartRulePolicy.ruleLevelFor(rules, _bank, _mon(1, 59)), _L.sensitive,
          reason: 'Sunday rolls into Monday');
      expect(SmartRulePolicy.ruleLevelFor(rules, _bank, _mon(2)), isNull);
      expect(SmartRulePolicy.ruleLevelFor(rules, _bank, _tue(1)), isNull);
      expect(SmartRulePolicy.levelAt(rules, _bank, 1, 60), _L.sensitive);
      expect(SmartRulePolicy.levelAt(rules, _bank, 2, 60), isNull);
    });

    test('5. overlapping rules → the strictest raising action (M2 interim)',
        () {
      final List<SmartRule> rules = <SmartRule>[
        _rule(id: 'a', action: _A.sensitive),
        _rule(id: 'b', time: _win(9, 17), action: _A.critical),
        _rule(id: 'c', action: _A.standard),
      ];
      expect(SmartRulePolicy.ruleLevelFor(rules, _bank, _mon(8)), _L.sensitive);
      expect(SmartRulePolicy.ruleLevelFor(rules, _bank, _mon(9)), _L.critical);
      expect(
          SmartRulePolicy.ruleLevelFor(rules, _bank, _mon(17)), _L.sensitive);
    });
  });

  group('6–8. change analysis', () {
    final SmartRule base = _rule(
      targets: <String>[_bank, _chat],
      days: SmartRuleDays.weekdays,
      time: _win(9, 17),
      action: _A.critical,
    );

    test('6. disable / delete / narrow / lower → relaxed (CR-2 required)', () {
      final Map<String, (List<SmartRule>, Set<String>)> cases =
          <String, (List<SmartRule>, Set<String>)>{
        'disabled': (
          <SmartRule>[base.copyWith(enabled: false)],
          <String>{_bank, _chat}
        ),
        'deleted': (<SmartRule>[], <String>{_bank, _chat}),
        'target removed': (
          <SmartRule>[
            base.copyWith(targetPackages: <String>[_bank])
          ],
          <String>{_chat}
        ),
        'day removed': (
          <SmartRule>[
            base.copyWith(days: <int>[1, 2, 3, 4])
          ],
          <String>{_bank, _chat}
        ),
        'window shortened': (
          <SmartRule>[base.copyWith(time: _win(10, 17))],
          <String>{_bank, _chat}
        ),
        'lowered to Sensitive': (
          <SmartRule>[base.copyWith(action: _A.sensitive)],
          <String>{_bank, _chat}
        ),
        'changed to Standard': (
          <SmartRule>[base.copyWith(action: _A.standard)],
          <String>{_bank, _chat}
        ),
        'changed to Unlocked': (
          <SmartRule>[base.copyWith(action: _A.unlocked)],
          <String>{_bank, _chat}
        ),
      };
      cases.forEach((String label, (List<SmartRule>, Set<String>) c) {
        expect(
          SmartRulePolicy.relaxedPackages(<SmartRule>[base], c.$1),
          c.$2,
          reason: label,
        );
      });
    });

    test('7. widen / raise / rename / non-raising edits → nothing relaxed', () {
      for (final List<SmartRule> after in <List<SmartRule>>[
        <SmartRule>[base],
        <SmartRule>[base.copyWith(name: 'Renamed')],
        <SmartRule>[base.copyWith(days: SmartRuleDays.everyDay)],
        <SmartRule>[base.copyWith(time: const SmartRuleTime.allDay())],
        <SmartRule>[
          base.copyWith(targetPackages: <String>[_bank, _chat, 'a.b'])
        ],
        <SmartRule>[base, _rule(id: 'x', action: _A.sensitive)],
      ]) {
        expect(
            SmartRulePolicy.relaxedPackages(<SmartRule>[base], after), isEmpty);
      }
      // Removing or disabling a rule that never raised relaxes nothing.
      final SmartRule std = _rule(id: 's', action: _A.standard);
      expect(SmartRulePolicy.relaxedPackages(<SmartRule>[std], <SmartRule>[]),
          isEmpty);
      expect(
        SmartRulePolicy.relaxedPackages(
            <SmartRule>[std], <SmartRule>[std.copyWith(enabled: false)]),
        isEmpty,
      );
    });

    test('8. raisedAt lists only apps stricter right now', () {
      final SmartRule night = _rule(time: _win(22, 6), action: _A.critical);
      expect(
          SmartRulePolicy.raisedAt(<SmartRule>[], <SmartRule>[night], _mon(23)),
          <String>{_bank});
      expect(
          SmartRulePolicy.raisedAt(<SmartRule>[], <SmartRule>[night], _mon(12)),
          isEmpty);
      expect(
        SmartRulePolicy.raisedAt(
          <SmartRule>[_rule(action: _A.sensitive)],
          <SmartRule>[_rule(action: _A.critical)],
          _mon(12),
        ),
        <String>{_bank},
      );
    });
  });

  group('9–10. native transport and cache', () {
    test('9. transport: enabled raising rules only, canonical and stable', () {
      final List<SmartRule> rules = <SmartRule>[
        _rule(id: 'b', time: _win(22, 6), action: _A.sensitive),
        _rule(id: 'a', targets: <String>[_chat], action: _A.critical),
        _rule(id: 'c', enabled: false),
        _rule(id: 'd', action: _A.standard),
      ];
      final List<Map<String, Object?>> t =
          SmartRulePolicy.nativeTransport(rules);
      expect(t, hasLength(2));
      for (final Map<String, Object?> m in t) {
        expect(m.keys.toSet(),
            <String>{'level', 'days', 'allDay', 'start', 'end', 'targets'});
        expect(<String>{'sensitive', 'critical'}, contains(m['level']));
      }
      expect(jsonEncode(SmartRulePolicy.nativeTransport(rules.reversed)),
          jsonEncode(t),
          reason: 'order-independent');
      expect(SmartRulePolicy.transportVersion, 1);
    });

    test('10. cache answers per instant and keeps the last good copy', () {
      final SmartRuleEnforcementCache cache = SmartRuleEnforcementCache();
      expect(cache.levelFor(_bank, _mon(12)), isNull);
      cache.update(<SmartRule>[_rule(time: _win(9, 17))]);
      expect(cache.levelFor(_bank, _mon(12)), _L.critical);
      expect(cache.levelFor(_bank, _mon(18)), isNull,
          reason: 'clock read per decision; no timer');
      expect(cache.levelFor(_bank, _mon(9)), _L.critical,
          reason: 'clock moved back: evaluated again, no stale answer');
    });
  });

  group('11–15. schema v2 and v1 migration', () {
    String v1Doc(List<Map<String, Object?>> rules) =>
        jsonEncode(<String, Object?>{
          'schema': 'smart_rules',
          'version': 1,
          'rules': rules
        });
    Map<String, Object?> v1Rule(String id, {bool enabled = true}) =>
        <String, Object?>{
          'id': id,
          'name': 'Night $id',
          'enabled': enabled,
          'targets': <String>[_bank, _chat],
          'days': <int>[1, 7],
          'time': <String, Object?>{
            'type': 'window',
            'start': 1320,
            'end': 360
          },
        };

    test('11. v1 migrates explicitly: every field kept, action = Standard', () {
      final SmartRuleDocumentRead read = SmartRuleDocument.decodeDocument(
        v1Doc(<Map<String, Object?>>[v1Rule('a'), v1Rule('b', enabled: false)]),
      );
      expect(read.storedVersion, 1);
      expect(read.migrated, isTrue);
      expect(read.rules.map((SmartRule r) => r.id), <String>['a', 'b']);
      final SmartRule a = read.rules.first;
      expect(a.name, 'Night a');
      expect(a.enabled, isTrue);
      expect(read.rules.last.enabled, isFalse);
      expect(a.targetPackages, <String>[_bank, _chat]);
      expect(a.days, <int>[1, 7]);
      expect(a.time, _win(22, 6));
      expect(a.action, _A.standard);
      expect(SmartRuleAction.migratedFromV1, _A.standard);
      // No surprise activation: nothing is enforced or sent to native.
      expect(SmartRulePolicy.ruleLevelFor(read.rules, _bank, _sun(23)), isNull);
      expect(SmartRulePolicy.nativeTransport(read.rules), isEmpty);
    });

    test('12. v1 with an action key, v2 without, or an unknown action: corrupt',
        () {
      final Map<String, Object?> withAction = <String, Object?>{
        ...v1Rule('a'),
        'action': 'critical',
      };
      expect(
          () => SmartRuleDocument.decode(
              v1Doc(<Map<String, Object?>>[withAction])),
          throwsA(isA<SmartRuleDocumentException>().having(
              (SmartRuleDocumentException e) => e.problem,
              'problem',
              SmartRuleDocumentProblem.corrupt)));
      for (final Object? action in <Object?>[
        null,
        'Critical',
        'strict',
        'unlock',
        2,
        true,
      ]) {
        final Map<String, Object?> rule = <String, Object?>{
          ...v1Rule('a'),
          if (action != null) 'action': action,
        };
        final String doc = jsonEncode(<String, Object?>{
          'schema': 'smart_rules',
          'version': 2,
          'rules': <Object?>[rule],
        });
        expect(
          () => SmartRuleDocument.decode(doc),
          throwsA(isA<SmartRuleDocumentException>().having(
              (SmartRuleDocumentException e) => e.problem,
              'problem',
              SmartRuleDocumentProblem.corrupt)),
          reason: 'action $action never falls back to Standard',
        );
      }
    });

    // P11-M3 intended update: the current schema is v3 (level rules keep
    // the exact v2 field layout); profile rules are covered in
    // smart_rule_profile_m3_model_test.dart.
    test(
        '13. round trip keeps every level action, including reserved '
        'Unlocked (written as the current v3)', () {
      final List<SmartRule> rules = <SmartRule>[
        for (final _A a in _A.levelActions) _rule(id: a.storageId, action: a),
      ];
      expect(SmartRuleDocument.decode(SmartRuleDocument.encode(rules)), rules);
      final SmartRuleDocumentRead read =
          SmartRuleDocument.decodeDocument(SmartRuleDocument.encode(rules));
      expect(read.storedVersion, 3);
      expect(read.migrated, isFalse);
    });

    test(
        '14. repository: a v1 store reads migrated and is written as the '
        'current v3 only on the next confirmed change', () async {
      final InMemoryLocalDatabase db = InMemoryLocalDatabase();
      final String raw = v1Doc(<Map<String, Object?>>[v1Rule('a')]);
      await db.setSetting(SmartRuleRepositoryImpl.storageKey, raw);
      final SmartRuleRepositoryImpl repo = SmartRuleRepositoryImpl(db);
      final List<SmartRule> rules = (await repo.getRules()).valueOrNull!;
      expect(rules.single.action, _A.standard);
      expect(await db.getSetting(SmartRuleRepositoryImpl.storageKey), raw,
          reason: 'reading never rewrites');
      expect(
        (await repo.saveRule(rules.single.copyWith(action: _A.sensitive),
                expected: rules.single))
            .isSuccess,
        isTrue,
      );
      final Map<String, dynamic> stored =
          jsonDecode((await db.getSetting(SmartRuleRepositoryImpl.storageKey))!)
              as Map<String, dynamic>;
      expect(stored['version'], 3);
      expect((stored['rules'] as List<dynamic>).single['action'], 'sensitive');
    });

    test('15. a future version fails closed and stays byte-for-byte', () async {
      final InMemoryLocalDatabase db = InMemoryLocalDatabase();
      const String raw =
          '{"schema":"smart_rules","version":4,"rules":[{"x":1}],"z":{}}';
      await db.setSetting(SmartRuleRepositoryImpl.storageKey, raw);
      final SmartRuleRepositoryImpl repo = SmartRuleRepositoryImpl(db);
      final Object? error = (await repo.getRules()).errorOrNull;
      expect(error, isA<SmartRuleStoreException>());
      expect((error! as SmartRuleStoreException).kind,
          SmartRuleStoreErrorKind.unsupportedVersion);
      expect((await repo.saveRule(_rule())).isFailure, isTrue);
      expect(await db.getSetting(SmartRuleRepositoryImpl.storageKey), raw);
    });
  });

  group('16. compare-and-swap (stale form never overwrites)', () {
    test('mustBeNew / expected conflicts write nothing', () async {
      final InMemoryLocalDatabase db = InMemoryLocalDatabase();
      final SmartRuleRepositoryImpl repo = SmartRuleRepositoryImpl(db);
      final SmartRule shown = _rule();
      expect((await repo.saveRule(shown, mustBeNew: true)).isSuccess, isTrue);
      final SmartRule newer = shown.copyWith(name: 'Changed elsewhere');
      expect((await repo.saveRule(newer)).isSuccess, isTrue);
      final String? before =
          await db.getSetting(SmartRuleRepositoryImpl.storageKey);

      SmartRuleStoreErrorKind? kind(Object? e) =>
          e is SmartRuleStoreException ? e.kind : null;
      expect(kind((await repo.saveRule(shown, mustBeNew: true)).errorOrNull),
          SmartRuleStoreErrorKind.conflict);
      expect(
        kind((await repo.saveRule(shown.copyWith(action: _A.sensitive),
                expected: shown))
            .errorOrNull),
        SmartRuleStoreErrorKind.conflict,
      );
      expect(
        kind((await repo.setRuleEnabled(shown.id,
                enabled: false, expected: shown))
            .errorOrNull),
        SmartRuleStoreErrorKind.conflict,
      );
      expect(
          kind((await repo.deleteRule(shown.id, expected: shown)).errorOrNull),
          SmartRuleStoreErrorKind.conflict);
      expect(await db.getSetting(SmartRuleRepositoryImpl.storageKey), before);
      expect((await repo.getRules()).valueOrNull, <SmartRule>[newer]);
    });
  });
}
