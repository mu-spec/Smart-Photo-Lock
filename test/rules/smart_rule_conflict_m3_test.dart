// Phase 10 / M3 (PRD 10J): conflict resolution of overlapping Smart Rules.
//
// Pure Dart: SmartRuleConflictPolicy through the production SmartRulePolicy
// entry points (ruleLevelFor, levelAt, relaxedPackages). The cross-language
// vectors live in smart_rule_parity_vectors_m3_test.dart; this file covers
// the policy contract and the CR-2 relaxation interplay explicitly.

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/rules/smart_rule_conflict.dart';
import 'package:smart_app_lock/rules/smart_rule_policy.dart';

typedef _L = AppSecurityLevel;
typedef _A = SmartRuleAction;

const String _bank = 'com.example.bank';
const String _chat = 'com.example.chat';

SmartRule _r(
  String id,
  _A action, {
  List<String> targets = const <String>[_bank],
  List<int> days = SmartRuleDays.everyDay,
  SmartRuleTime time = const SmartRuleTime.allDay(),
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

SmartRuleTime _w(int sh, int sm, int eh, int em) =>
    SmartRuleTime.window(startMinute: sh * 60 + sm, endMinute: eh * 60 + em);

/// Monday 2026-11-02 local.
DateTime _mon(int h, [int m = 0, int s = 0]) => DateTime(2026, 11, 2, h, m, s);

_L _effective(_L saved, List<SmartRule> rules, DateTime at,
        [String app = _bank]) =>
    SmartRulePolicy.effectiveLevel(
        saved, SmartRulePolicy.ruleLevelFor(rules, app, at));

void main() {
  group('locked priority Critical > Sensitive > Standard > Unlocked', () {
    test('priority list and ranks', () {
      expect(SmartRuleConflictPolicy.priority,
          <_A>[_A.critical, _A.sensitive, _A.standard, _A.unlocked]);
      for (int i = 0; i + 1 < SmartRuleConflictPolicy.priority.length; i++) {
        expect(
          SmartRuleConflictPolicy.rank(SmartRuleConflictPolicy.priority[i]),
          greaterThan(SmartRuleConflictPolicy.rank(
              SmartRuleConflictPolicy.priority[i + 1])),
        );
      }
    });

    test('every pair of actions: the stronger one wins in both orders', () {
      for (final _A a in _A.values) {
        for (final _A b in _A.values) {
          final List<SmartRule> ab = <SmartRule>[_r('a', a), _r('b', b)];
          final SmartRuleResolution r1 =
              SmartRulePolicy.resolutionFor(ab, _bank, _mon(10));
          final SmartRuleResolution r2 = SmartRulePolicy.resolutionFor(
              ab.reversed.toList(), _bank, _mon(10));
          final _A strongest =
              SmartRuleConflictPolicy.rank(a) >= SmartRuleConflictPolicy.rank(b)
                  ? a
                  : b;
          expect(r1.strongestAction, strongest, reason: '$a vs $b');
          expect(r2.strongestAction, strongest, reason: '$b vs $a');
          expect(r1.ruleLevel, strongest.raisesTo);
          expect(r1.strongestRuleIds, r2.strongestRuleIds);
        }
      }
    });
  });

  group('PRD 10J examples: effective = stricter(saved, strictest rule)', () {
    final DateTime at = _mon(10);
    test('Standard + Sensitive + Critical → Critical', () {
      expect(
          _effective(
              _L.standard,
              <SmartRule>[
                _r('s', _A.sensitive),
                _r('c', _A.critical),
              ],
              at),
          _L.critical);
    });
    test('Sensitive + Standard + Critical → Critical', () {
      expect(
          _effective(
              _L.sensitive,
              <SmartRule>[
                _r('s', _A.standard),
                _r('c', _A.critical),
              ],
              at),
          _L.critical);
    });
    test('Critical + Sensitive → Critical', () {
      expect(_effective(_L.critical, <SmartRule>[_r('s', _A.sensitive)], at),
          _L.critical);
    });
    test('Standard + Standard → Standard', () {
      expect(_effective(_L.standard, <SmartRule>[_r('s', _A.standard)], at),
          _L.standard);
    });
    test('Critical + Unlocked → Critical (Unlocked never operational)', () {
      expect(_effective(_L.critical, <SmartRule>[_r('u', _A.unlocked)], at),
          _L.critical);
      expect(_effective(_L.standard, <SmartRule>[_r('u', _A.unlocked)], at),
          _L.standard);
    });
    test('no matching rule → saved baseline', () {
      for (final _L saved in _L.values) {
        expect(_effective(saved, const <SmartRule>[], at), saved);
        expect(
            _effective(
                saved,
                <SmartRule>[
                  _r('c', _A.critical, targets: <String>[_chat]),
                ],
                at),
            saved);
      }
    });
    test('disabled rules are ignored', () {
      expect(
          _effective(
              _L.standard,
              <SmartRule>[
                _r('c', _A.critical, enabled: false),
              ],
              at),
          _L.standard);
    });
  });

  group('1–10. overlapping rules', () {
    test('1. two matching rules with different levels', () {
      final List<SmartRule> rules = <SmartRule>[
        _r('work', _A.sensitive, time: _w(9, 0, 17, 0)),
        _r('lunch', _A.critical, time: _w(12, 0, 14, 0)),
      ];
      expect(
          SmartRulePolicy.ruleLevelFor(rules, _bank, _mon(11)), _L.sensitive);
      expect(SmartRulePolicy.ruleLevelFor(rules, _bank, _mon(12)), _L.critical);
      expect(
          SmartRulePolicy.resolutionFor(rules, _bank, _mon(12)).decidingRuleId,
          'lunch');
    });

    test('2. three or more matching rules', () {
      final List<SmartRule> rules = <SmartRule>[
        _r('a', _A.standard),
        _r('b', _A.sensitive),
        _r('c', _A.critical),
        _r('d', _A.unlocked),
        _r('e', _A.sensitive),
      ];
      final SmartRuleResolution r =
          SmartRulePolicy.resolutionFor(rules, _bank, _mon(10));
      expect(r.ruleLevel, _L.critical);
      expect(r.decidingRuleId, 'c');
      expect(r.matchingRuleIds, <String>['a', 'b', 'c', 'd', 'e']);
    });

    test('3. same-level tie: deciding id is the first sorted id', () {
      final List<SmartRule> rules = <SmartRule>[
        _r('zeta', _A.critical),
        _r('Alpha', _A.critical), // uppercase sorts before lowercase
        _r('beta', _A.critical),
      ];
      final SmartRuleResolution r =
          SmartRulePolicy.resolutionFor(rules, _bank, _mon(10));
      expect(r.strongestRuleIds, <String>['Alpha', 'beta', 'zeta']);
      expect(r.decidingRuleId, 'Alpha');
      expect(r.tiedRuleIds, <String>['beta', 'zeta']);
    });

    test('4. insertion order never changes level or deciding rule', () {
      final List<SmartRule> rules = <SmartRule>[
        _r('m', _A.sensitive, time: _w(8, 0, 20, 0)),
        _r('c2', _A.critical, time: _w(10, 0, 11, 0)),
        _r('c1', _A.critical, time: _w(10, 30, 12, 0)),
        _r('s', _A.standard),
      ];
      final List<List<SmartRule>> orders = <List<SmartRule>>[
        rules,
        rules.reversed.toList(),
        <SmartRule>[rules[2], rules[0], rules[3], rules[1]],
        <SmartRule>[rules[1], rules[3], rules[0], rules[2]],
      ];
      for (int minute = 0; minute < 24 * 60; minute += 15) {
        final DateTime at = _mon(minute ~/ 60, minute % 60);
        final SmartRuleResolution base =
            SmartRulePolicy.resolutionFor(rules, _bank, at);
        for (final List<SmartRule> o in orders) {
          final SmartRuleResolution r =
              SmartRulePolicy.resolutionFor(o, _bank, at);
          expect(r.ruleLevel, base.ruleLevel);
          expect(r.decidingRuleId, base.decidingRuleId);
          expect(r.strongestRuleIds, base.strongestRuleIds);
        }
      }
    });

    test('5. a disabled higher-priority rule never counts', () {
      final List<SmartRule> rules = <SmartRule>[
        _r('crit', _A.critical, enabled: false),
        _r('sens', _A.sensitive),
      ];
      final SmartRuleResolution r =
          SmartRulePolicy.resolutionFor(rules, _bank, _mon(10));
      expect(r.ruleLevel, _L.sensitive);
      expect(r.decidingRuleId, 'sens');
      expect(r.matchingRuleIds, <String>['sens']);
    });

    test('6. an expired or nonmatching higher-priority rule never counts', () {
      final List<SmartRule> rules = <SmartRule>[
        _r('crit-morning', _A.critical, time: _w(6, 0, 9, 0)),
        _r('crit-tuesday', _A.critical, days: const <int>[2]),
        _r('crit-chat', _A.critical, targets: const <String>[_chat]),
        _r('sens', _A.sensitive),
      ];
      expect(SmartRulePolicy.ruleLevelFor(rules, _bank, _mon(9)), _L.sensitive,
          reason: '09:00 is the exclusive end of crit-morning');
      expect(SmartRulePolicy.ruleLevelFor(rules, _bank, _mon(8, 59, 59)),
          _L.critical);
    });

    test('7. overnight overlap: owner day of each part', () {
      final List<SmartRule> rules = <SmartRule>[
        _r('fri-night', _A.sensitive,
            days: const <int>[5], time: _w(22, 0, 6, 0)),
        _r('sat-early', _A.critical,
            days: const <int>[6], time: _w(4, 0, 5, 0)),
      ];
      // Saturday 04:30: Friday-night (owner Friday) AND Saturday-early.
      final DateTime sat0430 = DateTime(2026, 11, 7, 4, 30);
      final SmartRuleResolution r =
          SmartRulePolicy.resolutionFor(rules, _bank, sat0430);
      expect(r.ruleLevel, _L.critical);
      expect(r.matchingRuleIds, <String>['fri-night', 'sat-early']);
      // Saturday 05:00: Critical ended, Friday night continues to 06:00.
      expect(
          SmartRulePolicy.ruleLevelFor(rules, _bank, DateTime(2026, 11, 7, 5)),
          _L.sensitive);
      // Sunday 04:30: no Saturday-night rule, Sunday not owner of Friday.
      expect(
          SmartRulePolicy.ruleLevelFor(
              rules, _bank, DateTime(2026, 11, 8, 4, 30)),
          isNull);
    });

    test('8. Sunday → Monday rollover', () {
      final List<SmartRule> rules = <SmartRule>[
        _r('sun-night', _A.critical,
            days: const <int>[7], time: _w(23, 0, 1, 0)),
        _r('mon', _A.sensitive, days: const <int>[1]),
      ];
      expect(
          SmartRulePolicy.ruleLevelFor(
              rules, _bank, DateTime(2026, 11, 9, 0, 59)),
          _L.critical,
          reason: 'Monday 00:59 belongs to Sunday night');
      expect(
          SmartRulePolicy.ruleLevelFor(rules, _bank, DateTime(2026, 11, 9, 1)),
          _L.sensitive);
      expect(SmartRulePolicy.levelAt(rules, _bank, 1, 30), _L.critical);
      expect(SmartRulePolicy.levelAt(rules, _bank, 7, 30), isNull,
          reason: 'Sunday 00:30 belongs to Saturday night (not selected)');
    });

    test('9. all-day vs timed overlap', () {
      final List<SmartRule> rules = <SmartRule>[
        _r('all', _A.sensitive),
        _r('timed', _A.critical, time: _w(13, 0, 15, 0)),
      ];
      expect(SmartRulePolicy.ruleLevelFor(rules, _bank, _mon(0)), _L.sensitive);
      expect(SmartRulePolicy.ruleLevelFor(rules, _bank, _mon(13)), _L.critical);
      expect(
          SmartRulePolicy.ruleLevelFor(rules, _bank, _mon(15)), _L.sensitive);
      expect(SmartRulePolicy.ruleLevelFor(rules, _bank, _mon(23, 59, 59)),
          _L.sensitive);
    });

    test('10. removing the winner falls back to the next strongest', () {
      final SmartRule winner = _r('winner', _A.critical, time: _w(9, 0, 17, 0));
      final SmartRule fallback =
          _r('fallback', _A.sensitive, time: _w(8, 0, 18, 0));
      expect(_effective(_L.standard, <SmartRule>[winner, fallback], _mon(10)),
          _L.critical);
      expect(_effective(_L.standard, <SmartRule>[fallback], _mon(10)),
          _L.sensitive,
          reason: 'never straight back to Standard');
      expect(
          _effective(_L.standard,
              <SmartRule>[winner.copyWith(enabled: false), fallback], _mon(10)),
          _L.sensitive);
    });

    test('K. rules for different apps never leak across apps', () {
      final List<SmartRule> rules = <SmartRule>[
        _r('bank', _A.critical),
        _r('chat', _A.sensitive, targets: const <String>[_chat]),
      ];
      expect(SmartRulePolicy.ruleLevelFor(rules, _bank, _mon(10)), _L.critical);
      expect(
          SmartRulePolicy.ruleLevelFor(rules, _chat, _mon(10)), _L.sensitive);
      expect(SmartRulePolicy.ruleLevelFor(rules, 'com.example.other', _mon(10)),
          isNull);
    });
  });

  group('CR-2 interplay: a reduction is any loss of strictness', () {
    final SmartRule crit = _r('crit', _A.critical, time: _w(9, 0, 17, 0));
    final SmartRule sens = _r('sens', _A.sensitive, time: _w(8, 0, 18, 0));
    final SmartRule inner = _r('inner', _A.sensitive, time: _w(10, 0, 11, 0));

    test('deleting the winner while a weaker rule remains needs CR-2', () {
      expect(
          SmartRulePolicy.relaxedPackages(
              <SmartRule>[crit, sens], <SmartRule>[sens]),
          <String>{_bank});
    });

    test('disabling the winner needs CR-2', () {
      expect(
          SmartRulePolicy.relaxedPackages(<SmartRule>[crit, sens],
              <SmartRule>[crit.copyWith(enabled: false), sens]),
          <String>{_bank});
    });

    test('deleting a fully outranked rule is not a reduction', () {
      // inner (Sensitive 10–11) is inside crit (Critical 9–17): removing it
      // changes nothing at any minute of the week.
      expect(
          SmartRulePolicy.relaxedPackages(
              <SmartRule>[crit, inner], <SmartRule>[crit]),
          isEmpty);
    });

    test('lowering the winner to the level of a remaining rule needs CR-2', () {
      expect(
          SmartRulePolicy.relaxedPackages(<SmartRule>[crit, sens],
              <SmartRule>[crit.copyWith(action: _A.sensitive), sens]),
          <String>{_bank});
    });

    test('adding a weaker overlapping rule is never a reduction', () {
      expect(
          SmartRulePolicy.relaxedPackages(
              <SmartRule>[crit], <SmartRule>[crit, sens, inner]),
          isEmpty);
    });

    test('reordering is never a reduction', () {
      expect(
          SmartRulePolicy.relaxedPackages(
              <SmartRule>[crit, sens, inner], <SmartRule>[inner, sens, crit]),
          isEmpty);
    });
  });
}
