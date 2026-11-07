// Phase 11 / M1: Dart side of the Dart/Kotlin Security Profile parity
// vectors.
//
// Executes test/fixtures/security_profiles/profile_vectors.json, the SAME
// file the Kotlin JVM test SecurityProfileParityVectorsTest executes against
// native SmartRuleTransport / SmartRulePolicy / ProtectionStateStore.
// Expected values come from an independent reference model
// (generate_profile_vectors.py). This test also proves that Dart compiles
// each profile to exactly the overlay transport, and sends exactly the
// combined transport, that Kotlin is fed.
//
// SIMULATED / pure: no device, no native code runs here.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/profiles/security_profile.dart';
import 'package:smart_app_lock/profiles/security_profile_document.dart';
import 'package:smart_app_lock/profiles/security_profile_policy.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/rules/smart_rule_policy.dart';

const String _fixture = 'test/fixtures/security_profiles/profile_vectors.json';

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

List<String> _sortedCanonical(Iterable<Object?> list) =>
    list.map(_canonical).toList()..sort();

String _char(AppSecurityLevel? l) => switch (l) {
      AppSecurityLevel.critical => 'C',
      AppSecurityLevel.sensitive => 'S',
      AppSecurityLevel.standard => 'T',
      null => '-',
    };

/// Decodes one fixture profile through the REAL document decoder (embedded
/// in an otherwise default document, so the set validation runs too).
SecurityProfile _profile(Object? raw) {
  final Map<String, Object?> p = raw! as Map<String, Object?>;
  final Map<String, Object?> doc =
      jsonDecode(SecurityProfileDocument.encode(SecurityProfileSet.defaults()))
          as Map<String, Object?>;
  final List<Object?> profiles = <Object?>[
    for (final Object? q in doc['profiles']! as List<Object?>)
      (q! as Map<String, Object?>)['id'] == p['id'] ? p : q,
  ];
  doc['profiles'] = profiles;
  doc['activeProfileId'] = p['id'];
  return SecurityProfileDocument.decode(jsonEncode(doc)).active;
}

List<SmartRule> _rules(Object? raw) => <SmartRule>[
      for (final Object? r in raw! as List<Object?>) SmartRule.fromJson(r),
    ];

Map<String, AppSecurityLevel> _baselines(Object? raw) =>
    <String, AppSecurityLevel>{
      for (final MapEntry<String, Object?> e
          in (raw! as Map<String, Object?>).entries)
        e.key: AppSecurityLevel.fromStorage(e.value),
    };

DateTime _local(Map<String, String> week, int day, int minute) {
  final DateTime d = DateTime.parse(week['$day']!);
  return DateTime(d.year, d.month, d.day, minute ~/ 60, minute % 60);
}

void main() {
  final Map<String, Object?> v = _load();
  final Map<String, String> week =
      (v['referenceWeek']! as Map<String, Object?>).cast<String, String>();
  final List<Map<String, Object?>> scenarios =
      (v['scenarios']! as List<Object?>).cast<Map<String, Object?>>();
  final List<Map<String, Object?>> switches =
      (v['switches']! as List<Object?>).cast<Map<String, Object?>>();

  test('fixture shape', () {
    expect(v['version'], 1);
    expect(scenarios, hasLength(7));
    expect(switches, hasLength(11));
    expect((v['invalidDocuments']! as List<Object?>), hasLength(17));
  });

  test('presets: Dart defaults equal the fixture presets exactly', () {
    final List<Object?> encoded = (jsonDecode(
            SecurityProfileDocument.encode(SecurityProfileSet.defaults()))
        as Map<String, Object?>)['profiles']! as List<Object?>;
    expect(encoded.map(_canonical).toList(),
        (v['presets']! as List<Object?>).map(_canonical).toList());
  });

  group('scenarios', () {
    for (final Map<String, Object?> s in scenarios) {
      final String id = s['id']! as String;
      final List<SmartRule> rules = _rules(s['rules']);
      final Map<String, AppSecurityLevel> base = _baselines(s['baselines']);
      final Set<String> protectedSet = base.keys.toSet();
      final SecurityProfile profile = _profile(s['profile']);

      test('$id: Dart compiles exactly the fixture overlay transport', () {
        expect(
          _sortedCanonical(SmartRulePolicy.nativeTransport(
            SecurityProfilePolicy.overlayRules(profile, protectedSet),
          )),
          _sortedCanonical(s['overlayTransport']! as List<Object?>),
        );
      });

      test('$id: Dart sends Kotlin exactly the fixture combined transport', () {
        final List<Map<String, Object?>> sent =
            SecurityProfilePolicy.nativeTransport(rules, profile, protectedSet);
        expect(_sortedCanonical(sent),
            _sortedCanonical(s['transport']! as List<Object?>));
        if (profile.isEmpty) {
          // Normal: byte-for-byte the rules-only transport (no change).
          expect(sent.map(_canonical).toList(),
              SmartRulePolicy.nativeTransport(rules).map(_canonical).toList());
        }
      });

      test('$id: hand-written cases', () {
        for (final Object? raw in s['cases']! as List<Object?>) {
          final Map<String, Object?> c = raw! as Map<String, Object?>;
          final String app = c['app']! as String;
          final DateTime at = DateTime.parse(c['local']! as String);
          final String why = '$id: ${c['name']}';
          expect(SmartRulePolicy.ruleLevelFor(rules, app, at),
              _level(c['ruleLevel']),
              reason: why);
          final AppSecurityLevel? baseline = base[app];
          if (baseline == null) {
            expect(c['effective'], isNull, reason: why);
            continue;
          }
          expect(SecurityProfilePolicy.overlayLevelFor(profile, app),
              _level(c['overlayLevel']),
              reason: why);
          final AppSecurityLevel? extra =
              SecurityProfilePolicy.extraLevelFor(rules, profile, app, at);
          expect(extra, _level(c['extraLevel']), reason: why);
          final AppSecurityLevel eff =
              SmartRulePolicy.effectiveLevel(baseline, extra);
          expect(eff, _level(c['effective']), reason: why);
          expect(eff.rank >= baseline.rank, isTrue, reason: '$why (floor)');
        }
      });

      test('$id: dense grid (effective and engine level)', () {
        final List<int> minutes =
            (s['gridMinutes']! as List<Object?>).cast<int>();
        final Map<String, Object?> grid = s['grid']! as Map<String, Object?>;
        final Map<String, Object?> tgrid =
            s['transportGrid']! as Map<String, Object?>;
        final List<SmartRule> combined = <SmartRule>[
          ...rules,
          ...SecurityProfilePolicy.overlayRules(profile, protectedSet),
        ];
        for (final String pkg in grid.keys) {
          final List<String> rows =
              (grid[pkg]! as List<Object?>).cast<String>();
          final List<String> trows =
              (tgrid[pkg]! as List<Object?>).cast<String>();
          for (int day = 1; day <= 7; day++) {
            final String engine = minutes
                .map((int m) =>
                    _char(SmartRulePolicy.levelAt(combined, pkg, day, m)))
                .join();
            expect(engine, trows[day - 1], reason: '$id $pkg day $day engine');
            // The Dart floor's per-package view of the same transport
            // (rules + transportLevelFor), incl. unprotected packages.
            final String dartView = minutes.map((int m) {
              final AppSecurityLevel? r =
                  SmartRulePolicy.levelAt(rules, pkg, day, m);
              final AppSecurityLevel? o =
                  SecurityProfilePolicy.transportLevelFor(
                      profile, pkg, protectedSet);
              if (r == null) return _char(o);
              if (o == null) return _char(r);
              return _char(o.isStricterThan(r) ? o : r);
            }).join();
            expect(dartView, trows[day - 1],
                reason: '$id $pkg day $day transportLevelFor');
            final AppSecurityLevel? baseline = base[pkg];
            final String eff = minutes.map((int m) {
              if (baseline == null) return '-';
              return _char(SmartRulePolicy.effectiveLevel(
                baseline,
                SecurityProfilePolicy.extraLevelFor(
                    rules, profile, pkg, _local(week, day, m)),
              ));
            }).join();
            expect(eff, rows[day - 1], reason: '$id $pkg day $day effective');
          }
        }
      });
    }
  });

  group('switches and edits (D6 relaxation)', () {
    for (final Map<String, Object?> s in switches) {
      final String name = s['name']! as String;
      test(name, () {
        final List<SmartRule> rules = _rules(s['rules']);
        final Set<String> protectedSet =
            _baselines(s['baselines']).keys.toSet();
        final SecurityProfile before = _profile(s['before']);
        final SecurityProfile after = _profile(s['after']);
        expect(
          _sortedCanonical(SecurityProfilePolicy.nativeTransport(
              rules, before, protectedSet)),
          _sortedCanonical(s['beforeTransport']! as List<Object?>),
        );
        expect(
          _sortedCanonical(SecurityProfilePolicy.nativeTransport(
              rules, after, protectedSet)),
          _sortedCanonical(s['afterTransport']! as List<Object?>),
        );
        final Set<String> relaxed = SecurityProfilePolicy.relaxedPackages(
          rules: rules,
          before: before,
          after: after,
          protectedPackages: protectedSet,
        );
        expect(relaxed.toList()..sort(),
            (s['relaxedPackages']! as List<Object?>).cast<String>());
        expect(relaxed.isNotEmpty, s['relaxes']);
      });
    }
  });

  group('invalid documents are rejected (never reach native)', () {
    for (final Object? raw in v['invalidDocuments']! as List<Object?>) {
      final Map<String, Object?> d = raw! as Map<String, Object?>;
      test(d['name']! as String, () {
        expect(
          () => SecurityProfileDocument.decode(jsonEncode(d['document'])),
          throwsA(isA<SecurityProfileDocumentException>().having(
            (SecurityProfileDocumentException e) => e.problem.name,
            'problem',
            d['problem'],
          )),
        );
      });
    }
  });
}
