// Phase 11 / M3: Dart side of the Dart/Kotlin "Apply profile" parity
// vectors (test/fixtures/security_profiles/activation_vectors.json, the SAME
// file ProfileActivationParityVectorsTest.kt executes). Proves Dart compiles
// each scenario to EXACTLY the fixture transport (what native receives),
// that the Dart effective level and the per-layer diagnosis equal the
// independent reference grid, and that the combined relaxed set of every
// transition equals the reference. Pure Dart; SIMULATED.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/profiles/security_profile.dart';
import 'package:smart_app_lock/profiles/security_profile_policy.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/rules/smart_rule_policy.dart';

typedef _J = Map<String, dynamic>;

final _J _v = jsonDecode(
  File('test/fixtures/security_profiles/activation_vectors.json')
      .readAsStringSync(),
) as _J;

/// Exact storage id (no lenient fallback in a parity test).
AppSecurityLevel? _level(Object? raw) => raw == null
    ? null
    : AppSecurityLevel.values
        .firstWhere((AppSecurityLevel l) => l.storageId == raw);

List<SmartRule> _rules(Object? raw) => <SmartRule>[
      for (final Object? r in raw! as List<dynamic>)
        SmartRule.fromJson(r, version: 3),
    ];

SecurityProfile _profile(_J p) {
  final Map<String, AppSecurityLevel> apps = <String, AppSecurityLevel>{
    for (final MapEntry<String, dynamic> e in (p['apps'] as _J).entries)
      e.key: _level(e.value)!,
  };
  final String id = p['id'] as String;
  final SecurityProfileKind? kind = SecurityProfileKind.fromId(id);
  return kind != null
      ? SecurityProfile(
          kind: kind, allProtectedLevel: _level(p['all']), appLevels: apps)
      : SecurityProfile.custom(
          id: id,
          name: p['name'] as String,
          allProtectedLevel: _level(p['all']),
          appLevels: apps);
}

SecurityProfileSet _set(_J raw) {
  SecurityProfileSet s = SecurityProfileSet.defaults();
  for (final Object? p in raw['profiles'] as List<dynamic>) {
    final SecurityProfile profile = _profile(p! as _J);
    s = s.byId(profile.id) == null
        ? s.withAdded(profile)
        : s.withProfile(profile);
  }
  return s.withActive(raw['active'] as String);
}

List<String> _t(List<dynamic> t) =>
    t.map((dynamic e) => (e as Map<dynamic, dynamic>).toString()).toList();

String _ch(AppSecurityLevel? l) => switch (l) {
      AppSecurityLevel.critical => 'C',
      AppSecurityLevel.sensitive => 'S',
      AppSecurityLevel.standard => 'T',
      null => '-',
    };

DateTime _at(int day, int minute) =>
    DateTime(2026, 11, 1 + day, minute ~/ 60, minute % 60);

void main() {
  final List<_J> scenarios =
      (_v['scenarios'] as List<dynamic>).cast<_J>().toList();
  final List<_J> transitions =
      (_v['transitions'] as List<dynamic>).cast<_J>().toList();

  test('fixture shape (7 scenarios, 23 cases, 10 transitions, 5 relaxing)', () {
    expect(_v['version'], 1);
    expect(scenarios, hasLength(7));
    expect(
        scenarios.fold<int>(
            0, (int n, _J s) => n + (s['cases'] as List<dynamic>).length),
        23);
    expect(transitions, hasLength(10));
    expect(transitions.where((_J t) => t['relaxes'] == true), hasLength(5));
  });

  for (final _J s in scenarios) {
    group('${s['id']}', () {
      final _J baselines = s['baselines'] as _J;
      final Set<String> protectedSet = baselines.keys.toSet();
      final List<SmartRule> rules = _rules(s['rules']);
      final SecurityProfileSet set = _set(s['profiles'] as _J);

      AppSecurityLevel? effective(String pkg, DateTime at) {
        final AppSecurityLevel? saved = _level(baselines[pkg]);
        if (saved == null) return null;
        final AppSecurityLevel? extra = SmartRulePolicy.ruleLevelFor(
            SecurityProfilePolicy.combinedRules(rules, set, protectedSet),
            pkg,
            at);
        return extra != null && extra.isStricterThan(saved) ? extra : saved;
      }

      test('rules are valid v3 JSON and round-trip exactly', () {
        expect(
            <Object?>[for (final SmartRule r in rules) r.toJson()], s['rules']);
      });

      test('Dart sends Kotlin exactly the fixture transport', () {
        expect(
          _t(SecurityProfilePolicy.combinedTransport(rules, set, protectedSet)),
          _t(s['transport'] as List<dynamic>),
        );
      });

      test('hand-written cases (effective = diagnosis)', () {
        for (final Object? raw in s['cases'] as List<dynamic>) {
          final _J c = raw! as _J;
          final String app = c['app'] as String;
          final DateTime at = _at(c['day'] as int, c['minute'] as int);
          expect(effective(app, at), _level(c['effective']),
              reason: '${c['name']}');
          expect(
            ProtectionLayerDiagnostics.diagnose(
              rules: rules,
              profiles: set,
              packageName: app,
              savedLevel: _level(baselines[app]),
              protectedPackages: protectedSet,
              at: at,
            ).effectiveLevel,
            _level(c['effective']),
            reason: '${c['name']} (diagnosis)',
          );
        }
      });

      test('dense grid (effective and diagnosis)', () {
        final List<int> minutes =
            (s['gridMinutes'] as List<dynamic>).cast<int>().toList();
        for (final MapEntry<String, dynamic> row in (s['grid'] as _J).entries) {
          final String pkg = row.key;
          final List<String> days =
              (row.value as List<dynamic>).cast<String>().toList();
          for (int day = 1; day <= 7; day++) {
            final String got =
                minutes.map((int m) => _ch(effective(pkg, _at(day, m)))).join();
            expect(got, days[day - 1], reason: '$pkg day $day');
            final String diag = minutes
                .map((int m) => _ch(ProtectionLayerDiagnostics.diagnose(
                      rules: rules,
                      profiles: set,
                      packageName: pkg,
                      savedLevel: _level(baselines[pkg]),
                      protectedPackages: protectedSet,
                      at: _at(day, m),
                    ).effectiveLevel))
                .join();
            expect(diag, days[day - 1], reason: '$pkg day $day (diagnosis)');
          }
        }
      });
    });
  }

  group('transitions', () {
    for (final _J t in transitions) {
      test('${t['name']}: transports and relaxed set', () {
        final Set<String> protectedSet = (t['baselines'] as _J).keys.toSet();
        final List<SmartRule> rb = _rules(t['rulesBefore']);
        final List<SmartRule> ra = _rules(t['rulesAfter']);
        final SecurityProfileSet pb = _set(t['profilesBefore'] as _J);
        final SecurityProfileSet pa = _set(t['profilesAfter'] as _J);
        expect(
            _t(SecurityProfilePolicy.combinedTransport(rb, pb, protectedSet)),
            _t(t['beforeTransport'] as List<dynamic>));
        expect(
            _t(SecurityProfilePolicy.combinedTransport(ra, pa, protectedSet)),
            _t(t['afterTransport'] as List<dynamic>));
        expect(
          SecurityProfilePolicy.combinedRelaxedPackages(
            rulesBefore: rb,
            rulesAfter: ra,
            profilesBefore: pb,
            profilesAfter: pa,
            protectedPackages: protectedSet,
          ),
          (t['relaxedPackages'] as List<dynamic>).cast<String>().toSet(),
        );
      });
    }
  });
}
