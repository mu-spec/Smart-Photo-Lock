// Phase 11 / M1: overlay compilation, raise-only combination, D6
// relaxation detection and the enforcement cache. Pure Dart (SIMULATED).

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/profiles/security_profile.dart';
import 'package:smart_app_lock/profiles/security_profile_policy.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/rules/smart_rule_policy.dart';

typedef _L = AppSecurityLevel;

const String _a = 'com.example.notes';
const String _b = 'com.example.chat';
const String _game = 'com.example.game'; // never protected
const Set<String> _protected = <String>{_a, _b};

final SecurityProfile _normal =
    SecurityProfile.preset(SecurityProfileKind.normal);
final SecurityProfile _guest =
    SecurityProfile.preset(SecurityProfileKind.guest);

SecurityProfile _kids(Map<String, _L> apps, {_L? all}) => SecurityProfile(
      kind: SecurityProfileKind.kids,
      allProtectedLevel: all,
      appLevels: apps,
    );

SecurityProfileSet _setWith(SecurityProfile active) => SecurityProfileSet(
      profiles: <SecurityProfile>[
        for (final SecurityProfileKind k in SecurityProfileKind.values)
          k == active.kind ? active : SecurityProfile.preset(k),
      ],
      activeProfileId: active.id,
    );

final SmartRule _weekdayBCritical = SmartRule(
  id: 'weekday',
  name: 'Weekday chat',
  targetPackages: const <String>[_b],
  days: const <int>[1, 2, 3, 4, 5],
  time: SmartRuleTime.window(startMinute: 540, endMinute: 1020),
  action: SmartRuleAction.critical,
);

void main() {
  group('overlay compilation (one engine: all-day raising rules)', () {
    test('Guest → one all-day, every-day Critical entry over protected apps',
        () {
      final List<SmartRule> rules =
          SecurityProfilePolicy.overlayRules(_guest, _protected);
      expect(rules, hasLength(1));
      final SmartRule r = rules.single;
      expect(r.id, 'profile-guest-all');
      expect(r.name, 'Guest profile');
      expect(r.enabled, isTrue);
      expect(r.targetPackages.toSet(), _protected);
      expect(r.days.toList(), <int>[1, 2, 3, 4, 5, 6, 7]);
      expect(r.time, isA<SmartRuleAllDay>());
      expect(r.action, SmartRuleAction.critical);
    });

    test('no protected apps → no entry (empty targets never mean "all")', () {
      expect(SecurityProfilePolicy.overlayRules(_guest, const <String>{}),
          isEmpty);
      expect(
        SecurityProfilePolicy.nativeTransport(
            const <SmartRule>[], _guest, const <String>{}),
        isEmpty,
      );
    });

    test('per-app entries are grouped by level', () {
      final List<SmartRule> rules = SecurityProfilePolicy.overlayRules(
        _kids(<String, _L>{_a: _L.sensitive, _b: _L.critical}),
        _protected,
      );
      expect(rules.map((SmartRule r) => r.id).toList(),
          <String>['profile-kids-sensitive', 'profile-kids-critical']);
      expect(rules[0].targetPackages.toList(), <String>[_a]);
      expect(rules[1].targetPackages.toList(), <String>[_b]);
    });

    test('Normal → no overlay; transport identical to rules-only', () {
      final List<SmartRule> rules = <SmartRule>[_weekdayBCritical];
      expect(SecurityProfilePolicy.overlayRules(_normal, _protected), isEmpty);
      expect(
        SecurityProfilePolicy.nativeTransport(rules, _normal, _protected)
            .map((Map<String, Object?> e) => e.toString())
            .toList(),
        SmartRulePolicy.nativeTransport(rules)
            .map((Map<String, Object?> e) => e.toString())
            .toList(),
      );
    });
  });

  group('transportLevelFor (Dart floor mirrors the compiled overlay)', () {
    test('"all protected apps" never reaches an unprotected app', () {
      expect(SecurityProfilePolicy.transportLevelFor(_guest, _a, _protected),
          _L.critical);
      expect(SecurityProfilePolicy.transportLevelFor(_guest, _game, _protected),
          isNull);
      expect(
        SecurityProfilePolicy.transportLevelFor(_guest, _a, const <String>{}),
        isNull,
      );
    });

    test('per-app entries count as compiled; stricter of all/app wins', () {
      final SecurityProfile p = _kids(
        <String, _L>{_a: _L.critical, _game: _L.sensitive},
        all: _L.sensitive,
      );
      expect(SecurityProfilePolicy.transportLevelFor(p, _a, _protected),
          _L.critical);
      expect(SecurityProfilePolicy.transportLevelFor(p, _b, _protected),
          _L.sensitive);
      expect(SecurityProfilePolicy.transportLevelFor(p, _game, _protected),
          _L.sensitive);
      expect(SecurityProfilePolicy.transportLevelFor(_normal, _a, _protected),
          isNull);
    });
  });

  group('raise-only combination (D1)', () {
    test('effective is never below the saved baseline or the rule level', () {
      final List<SecurityProfile> profiles = <SecurityProfile>[
        _normal,
        _guest,
        _kids(<String, _L>{_a: _L.sensitive}),
        _kids(<String, _L>{_a: _L.critical, _b: _L.sensitive}),
        _kids(const <String, _L>{}, all: _L.sensitive),
      ];
      for (final SecurityProfile p in profiles) {
        for (final _L baseline in _L.values) {
          for (int day = 1; day <= 7; day++) {
            for (final int m in <int>[0, 539, 540, 1019, 1020, 1439]) {
              final DateTime at = DateTime(2026, 11, 1 + day, m ~/ 60, m % 60);
              for (final String pkg in _protected) {
                final _L? rule = SmartRulePolicy.ruleLevelFor(
                    <SmartRule>[_weekdayBCritical], pkg, at);
                final _L eff = SmartRulePolicy.effectiveLevel(
                  baseline,
                  SecurityProfilePolicy.extraLevelFor(
                      <SmartRule>[_weekdayBCritical], p, pkg, at),
                );
                expect(eff.rank >= baseline.rank, isTrue);
                if (rule != null) expect(eff.rank >= rule.rank, isTrue);
                final _L? overlay =
                    SecurityProfilePolicy.overlayLevelFor(p, pkg);
                if (overlay != null) expect(eff.rank >= overlay.rank, isTrue);
              }
            }
          }
        }
      }
    });

    test('the overlay is time-independent (all day, every day)', () {
      final SecurityProfile p = _kids(<String, _L>{_a: _L.sensitive});
      for (int day = 1; day <= 7; day++) {
        for (final int m in <int>[0, 720, 1439]) {
          expect(
            SecurityProfilePolicy.extraLevelFor(const <SmartRule>[], p, _a,
                DateTime(2026, 11, 1 + day, m ~/ 60, m % 60)),
            _L.sensitive,
          );
        }
      }
    });

    test('a stricter rule wins over a weaker overlay, and vice versa', () {
      final SecurityProfile p = _kids(<String, _L>{_b: _L.sensitive});
      final DateTime inWindow = DateTime(2026, 11, 2, 10);
      final DateTime outside = DateTime(2026, 11, 2, 20);
      expect(
        SecurityProfilePolicy.extraLevelFor(
            <SmartRule>[_weekdayBCritical], p, _b, inWindow),
        _L.critical,
      );
      expect(
        SecurityProfilePolicy.extraLevelFor(
            <SmartRule>[_weekdayBCritical], p, _b, outside),
        _L.sensitive,
      );
    });
  });

  group('D6 relaxation detection', () {
    Set<String> relaxed(SecurityProfile before, SecurityProfile after,
            [List<SmartRule> rules = const <SmartRule>[]]) =>
        SecurityProfilePolicy.relaxedPackages(
          rules: rules,
          before: before,
          after: after,
          protectedPackages: _protected,
        );

    test('leaving Guest relaxes every protected app', () {
      expect(relaxed(_guest, _normal), _protected);
    });

    test('entering Guest, or staying, relaxes nothing', () {
      expect(relaxed(_normal, _guest), isEmpty);
      expect(relaxed(_guest, _guest), isEmpty);
      expect(relaxed(_normal, _normal), isEmpty);
    });

    test('editing the active profile down or removing an app relaxes it', () {
      final SecurityProfile both =
          _kids(<String, _L>{_a: _L.critical, _b: _L.critical});
      expect(relaxed(both, _kids(<String, _L>{_a: _L.critical})), <String>{_b});
      expect(
        relaxed(both, _kids(<String, _L>{_a: _L.sensitive, _b: _L.critical})),
        <String>{_a},
      );
    });

    test('an unprotected app in a profile is never relaxed or raised', () {
      final SecurityProfile withGame = _kids(<String, _L>{_game: _L.critical});
      // The entry is compiled (not filtered) but native ignores unprotected
      // apps; Dart's relaxation is reported on the combined transport.
      expect(
        SecurityProfilePolicy.overlayRules(withGame, _protected)
            .single
            .targetPackages
            .toList(),
        <String>[_game],
      );
      expect(relaxed(withGame, _normal), <String>{_game});
    });
  });

  group('SecurityProfileEnforcementCache (R-A extended)', () {
    test('not current until the first successful read', () {
      final SecurityProfileEnforcementCache cache =
          SecurityProfileEnforcementCache();
      expect(cache.loaded, isFalse);
      expect(cache.current, isFalse);
      expect(cache.active.kind, SecurityProfileKind.normal);
      cache.update(_setWith(_guest));
      expect(cache.current, isTrue);
      expect(cache.levelFor(_a), _L.critical);
    });

    test('a failed read keeps the last good copy and is not current', () {
      final SecurityProfileEnforcementCache cache =
          SecurityProfileEnforcementCache()..update(_setWith(_guest));
      cache.markReadFailed();
      expect(cache.current, isFalse);
      expect(cache.loaded, isTrue);
      expect(cache.active.kind, SecurityProfileKind.guest); // never "Normal"
      expect(cache.levelFor(_a), _L.critical);
      cache.update(_setWith(_normal));
      expect(cache.current, isTrue);
      expect(cache.levelFor(_a), isNull);
    });

    test('normalOnly (no repository wired) is current Normal', () {
      final SecurityProfileEnforcementCache cache =
          SecurityProfileEnforcementCache.normalOnly();
      expect(cache.current, isTrue);
      expect(cache.levelFor(_a), isNull);
    });
  });
}
