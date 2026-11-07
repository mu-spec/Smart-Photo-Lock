// Phase 10 / M3 (PRD 10J, 10L): Dart side of the Dart/Kotlin parity
// vectors.
//
// Executes test/fixtures/smart_rules/conflict_vectors.json — the SAME file
// the Kotlin JVM test SmartRuleParityVectorsTest executes against native
// SmartRuleTransport / SmartRulePolicy / ProtectionStateStore. Expected values
// come from an independent reference model (generate_conflict_vectors.py),
// not from either implementation. This test also proves that the transport
// Kotlin is fed is exactly what Dart's nativeTransport() sends for the same
// rules, so both sides evaluate the same rule set.
//
// SIMULATED / pure: no device, no native code runs here.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/rules/smart_rule_conflict.dart';
import 'package:smart_app_lock/rules/smart_rule_diagnostics.dart';
import 'package:smart_app_lock/rules/smart_rule_evaluator.dart';
import 'package:smart_app_lock/rules/smart_rule_policy.dart';

const String _fixture = 'test/fixtures/smart_rules/conflict_vectors.json';

Map<String, Object?> _load() =>
    jsonDecode(File(_fixture).readAsStringSync()) as Map<String, Object?>;

AppSecurityLevel? _level(Object? id) =>
    id == null ? null : AppSecurityLevel.fromStorage(id);

String _canonical(Object? v) {
  if (v is Map) {
    final List<String> keys = v.keys.cast<String>().toList()..sort();
    return '{${keys.map((String k) => '"$k":${_canonical(v[k])}').join(',')}}';
  }
  if (v is List) return '[${v.map(_canonical).join(',')}]';
  return jsonEncode(v);
}

List<String> _strings(Object? raw) => (raw! as List<Object?>).cast<String>();

final class _Set {
  _Set(this.raw)
      : id = raw['id']! as String,
        rules = <SmartRule>[
          for (final Object? r in raw['rules']! as List<Object?>)
            SmartRule.fromJson(r),
        ],
        baselines = <String, AppSecurityLevel>{
          for (final MapEntry<String, Object?> e
              in (raw['baselines']! as Map<String, Object?>).entries)
            e.key: AppSecurityLevel.fromStorage(e.value),
        };

  final Map<String, Object?> raw;
  final String id;
  final List<SmartRule> rules;
  final Map<String, AppSecurityLevel> baselines;

  List<Map<String, Object?>> get cases =>
      (raw['cases']! as List<Object?>).cast<Map<String, Object?>>();
  List<int> get gridMinutes =>
      (raw['gridMinutes']! as List<Object?>).cast<int>();
  Map<String, List<String>> get grid => <String, List<String>>{
        for (final MapEntry<String, Object?> e
            in (raw['grid']! as Map<String, Object?>).entries)
          e.key: _strings(e.value),
      };
}

/// Local instant of ISO [day] / [minute] in the fixture's reference week.
DateTime _at(int day, int minute, [int second = 0]) =>
    DateTime(2026, 11, 1 + day, minute ~/ 60, minute % 60, second);

String _char(AppSecurityLevel? l) => switch (l) {
      AppSecurityLevel.critical => 'C',
      AppSecurityLevel.sensitive => 'S',
      _ => '-',
    };

void _checkCases(_Set s, List<SmartRule> rules, String label) {
  for (final Map<String, Object?> c in s.cases) {
    final String app = c['app']! as String;
    final DateTime local = DateTime.parse(c['local']! as String);
    expect(local.isUtc, isFalse);
    final String why = '$label/${s.id}: ${c['name']}';
    final AppSecurityLevel? ruleLevel = _level(c['ruleLevel']);
    final SmartRuleResolution r =
        SmartRulePolicy.resolutionFor(rules, app, local);
    expect(r.ruleLevel, ruleLevel, reason: why);
    expect(SmartRulePolicy.ruleLevelFor(rules, app, local), ruleLevel,
        reason: why);
    expect(
      SmartRulePolicy.levelAt(
          rules, app, c['day']! as int, c['minute']! as int),
      ruleLevel,
      reason: '$why (levelAt)',
    );
    expect(r.strongestRuleIds, _strings(c['strongest']), reason: why);
    expect(r.matchingRuleIds, _strings(c['matching']), reason: why);
    final AppSecurityLevel? saved = s.baselines[app];
    final SmartRuleAppDiagnosis d = SmartRuleDiagnostics.diagnose(
      rules: rules,
      packageName: app,
      savedLevel: saved,
      at: local,
    );
    expect(d.calculatedLevel, _level(c['effective']), reason: why);
    if (saved != null) {
      expect(SmartRulePolicy.effectiveLevel(saved, ruleLevel),
          _level(c['effective']),
          reason: why);
    }
    expect(d.decidingRuleId, c['deciding'], reason: why);
    expect(d.tiedRuleIds, _strings(c['tied']), reason: why);
  }
}

void main() {
  final Map<String, Object?> v = _load();
  final List<_Set> sets = <_Set>[
    for (final Object? s in v['ruleSets']! as List<Object?>)
      _Set(s! as Map<String, Object?>),
  ];

  test('fixture is the expected shape (11 sets, 57 cases)', () {
    expect(v['version'], 1);
    expect(sets, hasLength(11));
    expect(sets.fold<int>(0, (int n, _Set s) => n + s.cases.length), 57);
  });

  group('11–13. shared vectors: matching, conflict and effective level', () {
    for (final _Set s in sets) {
      test('${s.id}: Dart sends Kotlin exactly the fixture transport', () {
        final List<String> dart = SmartRulePolicy.nativeTransport(s.rules)
            .map(_canonical)
            .toList()
          ..sort();
        final List<String> fixture = (s.raw['transport']! as List<Object?>)
            .map(_canonical)
            .toList()
          ..sort();
        expect(dart, fixture);
      });

      test('${s.id}: hand-written cases', () {
        _checkCases(s, s.rules, 'as stored');
      });

      test('${s.id}: dense boundary grid (14. boundary parity)', () {
        final Map<String, List<String>> grid = s.grid;
        final List<int> minutes = s.gridMinutes;
        for (final MapEntry<String, List<String>> e in grid.entries) {
          for (int day = 1; day <= 7; day++) {
            final StringBuffer viaLevelAt = StringBuffer();
            final StringBuffer viaClock = StringBuffer();
            for (final int m in minutes) {
              viaLevelAt.write(
                  _char(SmartRulePolicy.levelAt(s.rules, e.key, day, m)));
              // Seconds never move a boundary: :59 is the same minute.
              viaClock.write(_char(SmartRulePolicy.ruleLevelFor(
                  s.rules, e.key, _at(day, m, 59))));
            }
            expect(viaLevelAt.toString(), e.value[day - 1],
                reason: '${s.id} ${e.key} day $day');
            expect(viaClock.toString(), e.value[day - 1],
                reason: '${s.id} ${e.key} day $day (clock)');
          }
        }
      });
    }
  });

  group('4. rule order never changes the outcome', () {
    for (final _Set s in sets.where((_Set s) => s.rules.length > 1)) {
      test('${s.id}: every permutation gives the same results', () {
        for (final List<SmartRule> p in _permutations(s.rules)) {
          _checkCases(s, p, 'permuted ${p.map((SmartRule r) => r.id)}');
          for (final MapEntry<String, List<String>> e in s.grid.entries) {
            for (int day = 1; day <= 7; day++) {
              final String row = s.gridMinutes
                  .map((int m) =>
                      _char(SmartRulePolicy.levelAt(p, e.key, day, m)))
                  .join();
              expect(row, e.value[day - 1]);
            }
          }
          expect(
            SmartRulePolicy.nativeTransport(p).map(_canonical).toList(),
            SmartRulePolicy.nativeTransport(s.rules).map(_canonical).toList(),
            reason: 'canonical transport order',
          );
        }
      });
    }
  });

  group('DST and time-zone instants (wall-clock parity)', () {
    final Map<String, Object?> dst = v['dst']! as Map<String, Object?>;
    final List<SmartRule> rules = <SmartRule>[
      for (final Object? r in dst['rules']! as List<Object?>)
        SmartRule.fromJson(r),
    ];
    test('Dart transport equals the DST fixture transport', () {
      expect(
        SmartRulePolicy.nativeTransport(rules).map(_canonical).toList()..sort(),
        (dst['transport']! as List<Object?>).map(_canonical).toList()..sort(),
      );
    });
    test('each local day/minute (Kotlin derives it from the epoch) agrees', () {
      for (final Object? raw in dst['instants']! as List<Object?>) {
        final Map<String, Object?> i = raw! as Map<String, Object?>;
        expect(
          SmartRulePolicy.levelAt(rules, 'com.example.bank',
              i['localDay']! as int, i['localMinute']! as int),
          _level(i['ruleLevel']),
          reason: i['name']! as String,
        );
      }
    });
  });

  group('CR-2 / held boundary: which changes are reductions (shared vectors)',
      () {
    final List<Object?> pairs = v['relaxation']! as List<Object?>;
    test('fixture carries 21 relaxation pairs', () {
      expect(pairs, hasLength(21));
    });
    for (final Object? raw in pairs) {
      final Map<String, Object?> c = raw! as Map<String, Object?>;
      List<SmartRule> rules(String key) => <SmartRule>[
            for (final Object? r in c[key]! as List<Object?>)
              SmartRule.fromJson(r),
          ];
      List<String> canon(Object? t) =>
          (t! as List<Object?>).map(_canonical).toList()..sort();
      test('${c['name']}', () {
        final List<SmartRule> before = rules('before');
        final List<SmartRule> after = rules('after');
        expect(
            SmartRulePolicy.nativeTransport(before).map(_canonical).toList()
              ..sort(),
            canon(c['beforeTransport']));
        expect(
            SmartRulePolicy.nativeTransport(after).map(_canonical).toList()
              ..sort(),
            canon(c['afterTransport']));
        final List<String> relaxed =
            SmartRulePolicy.relaxedPackages(before, after).toList()..sort();
        expect(relaxed, c['relaxedPackages']);
        expect(relaxed.isNotEmpty, c['relaxes']);
        // Order of either list never changes the decision.
        expect(
            SmartRulePolicy.relaxedPackages(before.reversed, after.reversed)
                .toList()
              ..sort(),
            relaxed);
      });
    }
  });

  group('15. invalid input handling', () {
    test('every invalid stored rule is rejected (never repaired)', () {
      for (final Object? raw in v['invalidRules']! as List<Object?>) {
        final Map<String, Object?> c = raw! as Map<String, Object?>;
        expect(
          () => SmartRule.fromJson(c['rule']),
          throwsA(isA<SmartRuleFormatException>()),
          reason: c['name']! as String,
        );
      }
    });

    test('invalid queries never match (Dart and Kotlin both give no level)',
        () {
      final Map<String, Object?> q =
          v['invalidQueries']! as Map<String, Object?>;
      final List<SmartRule> rules = <SmartRule>[
        for (final Object? r in q['rules']! as List<Object?>)
          SmartRule.fromJson(r),
      ];
      for (final Object? raw in q['queries']! as List<Object?>) {
        final Map<String, Object?> c = raw! as Map<String, Object?>;
        expect(
          SmartRulePolicy.levelAt(rules, c['app']! as String, c['day']! as int,
              c['minute']! as int),
          isNull,
          reason: c['name']! as String,
        );
      }
      // Dart-only boundaries: a malformed package or a UTC instant is
      // invalid input, never a match.
      final DateTime monday = DateTime(2026, 11, 2, 9, 20);
      expect(
          SmartRulePolicy.ruleLevelFor(rules, 'not a package', monday), isNull);
      expect(
        const SmartRuleEvaluator()
            .evaluate(rules.single, 'com.example.bank', monday.toUtc())
            .outcome,
        SmartRuleOutcome.invalidInput,
      );
      expect(
          SmartRulePolicy.ruleLevelFor(
              rules, 'com.example.bank', monday.toUtc()),
          isNull);
    });

    test('Dart never produces a transport entry Kotlin must reject', () {
      // Every invalid transport shape corresponds to data nativeTransport()
      // cannot emit: only enabled Critical/Sensitive rules with validated
      // days, minutes and packages are sent.
      for (final _Set s in sets) {
        for (final Map<String, Object?> t
            in SmartRulePolicy.nativeTransport(s.rules)) {
          expect(<Object?>['critical', 'sensitive'], contains(t['level']));
          final List<int> days = (t['days']! as List<Object?>).cast<int>();
          expect(days, isNotEmpty);
          expect(days.every((int d) => d >= 1 && d <= 7), isTrue);
          expect(t['allDay'], isA<bool>());
          if (t['allDay'] == false) {
            expect(t['start'], isNot(t['end']));
            expect(t['start'], inInclusiveRange(0, 1439));
            expect(t['end'], inInclusiveRange(0, 1439));
          }
          final List<String> targets = _strings(t['targets']);
          expect(targets, isNotEmpty);
          expect(targets.every(SmartRule.isValidPackageName), isTrue);
        }
      }
    });
  });
}

/// All permutations for up to 4 rules; otherwise 30 seeded shuffles plus
/// the reversed order.
Iterable<List<SmartRule>> _permutations(List<SmartRule> rules) sync* {
  if (rules.length <= 4) {
    yield* _allPermutations(rules);
    return;
  }
  final Random random = Random(1003);
  yield rules.reversed.toList();
  for (int i = 0; i < 30; i++) {
    yield List<SmartRule>.of(rules)..shuffle(random);
  }
}

Iterable<List<SmartRule>> _allPermutations(List<SmartRule> items) sync* {
  if (items.length <= 1) {
    yield List<SmartRule>.of(items);
    return;
  }
  for (int i = 0; i < items.length; i++) {
    final List<SmartRule> rest = List<SmartRule>.of(items)..removeAt(i);
    for (final List<SmartRule> p in _allPermutations(rest)) {
      yield <SmartRule>[items[i], ...p];
    }
  }
}
