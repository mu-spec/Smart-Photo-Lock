// Phase 11 / M3 (§3, §4, §7, §9): "Apply profile" activation compiled as a
// temporary ADDITIONAL raise-only overlay; deterministic conflicts
// (strictest wins, stable-id attribution only, no last-write-wins,
// fallback to the next strongest layer); expiry is evaluation, never a
// snapshot change; every manual reduction of the COMBINED policy is
// detected (CR-2). Pure Dart; no device. All results SIMULATED.

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/profiles/security_profile.dart';
import 'package:smart_app_lock/profiles/security_profile_policy.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/rules/smart_rule_policy.dart';
import 'package:smart_app_lock/ui/screens/smart/profile_change.dart';

typedef _L = AppSecurityLevel;
typedef _A = SmartRuleAction;

const String _notes = 'com.example.notes'; // protected, Standard
const String _chat = 'com.example.chat'; // protected, Sensitive
const String _maps = 'com.example.maps'; // NOT protected
const Set<String> _protected = <String>{_notes, _chat};
const Map<String, _L> _saved = <String, _L>{
  _notes: _L.standard,
  _chat: _L.sensitive,
};
const String _tripId = 'custom-00000000000a';

// 2026-11-02 is a Monday.
DateTime _at(int weekday, int hour, [int minute = 0]) =>
    DateTime(2026, 11, 1 + weekday, hour, minute);

SmartRule _apply(
  String id,
  String profile, {
  List<int> days = const <int>[6, 7],
  SmartRuleTime? time,
  bool enabled = true,
}) =>
    SmartRule(
      id: id,
      name: 'Apply $profile',
      targetPackages: const <String>[],
      days: days,
      time: time ?? SmartRuleTime.window(startMinute: 1320, endMinute: 360),
      action: _A.applyProfile,
      profileId: profile,
      enabled: enabled,
    );

SmartRule _direct(String id, String pkg, _A action,
        {List<int> days = SmartRuleDays.everyDay}) =>
    SmartRule(
      id: id,
      name: 'Direct $id',
      targetPackages: <String>[pkg],
      days: days,
      time: const SmartRuleTime.allDay(),
      action: action,
    );

SecurityProfile _trip(_L? all, {Map<String, _L> apps = const <String, _L>{}}) =>
    SecurityProfile.custom(
        id: _tripId, name: 'Trip', allProtectedLevel: all, appLevels: apps);

SecurityProfileSet _set({
  String active = 'normal',
  SecurityProfile? trip,
  Map<String, _L>? kids,
}) {
  SecurityProfileSet s = SecurityProfileSet.defaults();
  if (trip != null) s = s.withAdded(trip);
  if (kids != null) {
    s = s.withProfile(
        SecurityProfile(kind: SecurityProfileKind.kids, appLevels: kids));
  }
  return s.withActive(active);
}

/// What enforcement computes: stricter(saved, combined rules).
_L? _effective(
  List<SmartRule> rules,
  SecurityProfileSet set,
  String pkg,
  DateTime at,
) {
  final _L? saved = _saved[pkg];
  if (saved == null) return null;
  final _L? extra = SmartRulePolicy.ruleLevelFor(
      SecurityProfilePolicy.combinedRules(rules, set, _protected), pkg, at);
  return extra != null && extra.isStricterThan(saved) ? extra : saved;
}

ProtectionLayerDiagnosis _diag(
  List<SmartRule> rules,
  SecurityProfileSet set,
  String pkg,
  DateTime at,
) =>
    ProtectionLayerDiagnostics.diagnose(
      rules: rules,
      profiles: set,
      packageName: pkg,
      savedLevel: _saved[pkg],
      protectedPackages: _protected,
      at: at,
    );

List<String> _t(List<Map<String, Object?>> t) =>
    t.map((Map<String, Object?> e) => e.toString()).toList();

Set<String> _relaxed(
  List<SmartRule> rulesBefore,
  List<SmartRule> rulesAfter, {
  SecurityProfileSet? before,
  SecurityProfileSet? after,
}) =>
    SecurityProfilePolicy.combinedRelaxedPackages(
      rulesBefore: rulesBefore,
      rulesAfter: rulesAfter,
      profilesBefore: before ?? _set(),
      profilesAfter: after ?? before ?? _set(),
      protectedPackages: _protected,
    );

void main() {
  group('§3 activation = temporary additional overlay', () {
    final List<SmartRule> weekendGuest = <SmartRule>[_apply('w', 'guest')];

    test(
        'Normal + scheduled Guest (Sat/Sun 22:00–06:00): Critical only '
        'inside the window; overnight belongs to its start day', () {
      final SecurityProfileSet s = _set();
      final Map<DateTime, _L> expectNotes = <DateTime, _L>{
        _at(5, 23): _L.standard, // Fri night: Fri not selected
        _at(6, 5, 59): _L.standard, // Sat early: Fri's window
        _at(6, 12): _L.standard,
        _at(6, 21, 59): _L.standard,
        _at(6, 22): _L.critical, // start inclusive
        _at(7, 3): _L.critical, // Sat window continues into Sun
        _at(7, 6): _L.standard, // end exclusive
        _at(7, 22): _L.critical,
        _at(1, 5, 59): _L.critical, // Sun window continues into Mon
        _at(1, 6): _L.standard,
      };
      expectNotes.forEach((DateTime t, _L want) {
        expect(_effective(weekendGuest, s, _notes, t), want, reason: '$t');
        expect(_effective(weekendGuest, s, _chat, t),
            want == _L.critical ? _L.critical : _L.sensitive,
            reason: '$t');
      });
      expect(profileRuleMatchesAt(weekendGuest.single, _at(7, 3)), isTrue);
      expect(profileRuleMatchesAt(weekendGuest.single, _at(6, 3)), isFalse);
      expect(
          profileRuleMatchesAt(weekendGuest.single, _at(6, 3).toUtc()), isFalse,
          reason: 'UTC instants never match');
    });

    test('the manual profile is never changed by a rule', () {
      final SecurityProfileSet s = _set(active: 'work');
      final List<SmartRule> act =
          SecurityProfilePolicy.activationRules(weekendGuest, s, _protected);
      expect(act, isNotEmpty);
      expect(s.activeProfileId, 'work');
      expect(
          act.every((SmartRule r) =>
              r.id.startsWith(SecurityProfilePolicy.activationRulePrefix)),
          isTrue);
      expect(act.every((SmartRule r) => !r.isProfileRule), isTrue);
    });

    test(
        'unprotected apps are never enrolled (Guest "all" = protected apps '
        'only; an empty protected set compiles to nothing)', () {
      expect(_effective(weekendGuest, _set(), _maps, _at(6, 23)), isNull);
      for (final SmartRule r in SecurityProfilePolicy.activationRules(
          weekendGuest, _set(), _protected)) {
        expect(r.targetPackages.toSet().difference(_protected), isEmpty);
      }
      expect(
        SecurityProfilePolicy.activationRules(
            weekendGuest, _set(), const <String>{}),
        isEmpty,
      );
    });

    test('Work manual + scheduled Kids (chat Critical): only chat rises', () {
      final SecurityProfileSet s =
          _set(active: 'work', kids: const <String, _L>{_chat: _L.critical});
      final List<SmartRule> rules = <SmartRule>[_apply('k', 'kids')];
      expect(_effective(rules, s, _chat, _at(6, 23)), _L.critical);
      expect(_effective(rules, s, _notes, _at(6, 23)), _L.standard);
      expect(_effective(rules, s, _chat, _at(6, 12)), _L.sensitive);
    });

    test(
        'Normal / Home / Work / empty Kids as a scheduled target add '
        'nothing (R4): transport identical to no rule', () {
      for (final String id in <String>['normal', 'home', 'work', 'kids']) {
        expect(
          _t(SecurityProfilePolicy.combinedTransport(
              <SmartRule>[_apply('r', id)], _set(), _protected)),
          _t(SecurityProfilePolicy.combinedTransport(
              const <SmartRule>[], _set(), _protected)),
          reason: id,
        );
      }
    });

    test('disabled activation rules compile to nothing', () {
      expect(
        SecurityProfilePolicy.activationRules(
            <SmartRule>[_apply('w', 'guest', enabled: false)],
            _set(),
            _protected),
        isEmpty,
      );
    });

    test(
        'without profile rules the combined transport EQUALS the M2 '
        'transport for every manual profile', () {
      final List<SmartRule> rules = <SmartRule>[
        _direct('d', _notes, _A.sensitive),
      ];
      for (final String active in <String>[
        'normal',
        'home',
        'work',
        'guest',
        'kids',
      ]) {
        final SecurityProfileSet s = _set(active: active);
        expect(
          _t(SecurityProfilePolicy.combinedTransport(rules, s, _protected)),
          _t(SecurityProfilePolicy.nativeTransport(
              rules, s.active, _protected)),
          reason: active,
        );
      }
    });

    test(
        'the transport carries the rule\'s own days and window (native '
        'evaluates time; no timer)', () {
      final List<String> t = _t(SecurityProfilePolicy.combinedTransport(
          weekendGuest, _set(), _protected));
      final String expected = _t(SmartRulePolicy.nativeTransport(<SmartRule>[
        SmartRule(
          id: 'x',
          name: 'x',
          targetPackages: _protected,
          days: const <int>[6, 7],
          time: SmartRuleTime.window(startMinute: 1320, endMinute: 360),
          action: _A.critical,
        ),
      ])).single;
      expect(t, contains(expected));
      expect(t, hasLength(1));
    });
  });

  group('§3/R2 missing profile reference fails CLOSED', () {
    test(
        'a dangling reference is Critical for every protected app inside '
        'its window only; never an unprotected app', () {
      final List<SmartRule> rules = <SmartRule>[_apply('m', _tripId)];
      final SecurityProfileSet s = _set();
      expect(SecurityProfilePolicy.referencesMissingProfile(rules.single, s),
          isTrue);
      expect(_effective(rules, s, _notes, _at(6, 23)), _L.critical);
      expect(_effective(rules, s, _chat, _at(6, 23)), _L.critical);
      expect(_effective(rules, s, _notes, _at(6, 12)), _L.standard);
      expect(_effective(rules, s, _maps, _at(6, 23)), isNull);
      expect(
        SecurityProfilePolicy.referencesMissingProfile(
            rules.single, _set(trip: _trip(_L.sensitive))),
        isFalse,
      );
    });
  });

  group('§4 deterministic conflicts', () {
    test(
        'two overlapping activations: strictest wins in either order; the '
        'attributed rule never depends on list order', () {
      final SecurityProfileSet s = _set(trip: _trip(_L.sensitive));
      final SmartRule guest = _apply('z-guest', 'guest');
      final SmartRule trip = _apply('a-trip', _tripId);
      for (final List<SmartRule> rules in <List<SmartRule>>[
        <SmartRule>[guest, trip],
        <SmartRule>[trip, guest],
      ]) {
        expect(_effective(rules, s, _notes, _at(6, 23)), _L.critical);
        final ProtectionLayerDiagnosis d = _diag(rules, s, _notes, _at(6, 23));
        expect(d.scheduledLevel, _L.critical);
        expect(d.scheduledRuleId, 'z-guest');
        expect(d.scheduledProfileId, 'guest');
        expect(d.decidedBy, ProtectionLayer.scheduledProfile);
      }
    });

    test(
        'equal strictness: attribution is the lowest stable id (never the '
        'last written)', () {
      final SecurityProfileSet s = _set(trip: _trip(_L.critical));
      for (final List<SmartRule> rules in <List<SmartRule>>[
        <SmartRule>[_apply('b', 'guest'), _apply('a', _tripId)],
        <SmartRule>[_apply('a', _tripId), _apply('b', 'guest')],
      ]) {
        final ProtectionLayerDiagnosis d = _diag(rules, s, _notes, _at(6, 23));
        expect(d.scheduledRuleId, 'a');
        expect(d.scheduledProfileId, _tripId);
        expect(d.effectiveLevel, _L.critical);
      }
    });

    test(
        'layer ties go saved > manual > direct > scheduled (attribution '
        'only; the level is the same)', () {
      final List<SmartRule> rules = <SmartRule>[
        _apply('w', 'guest'),
        _direct('d', _notes, _A.critical),
      ];
      // Manual Guest ties direct and scheduled at Critical.
      ProtectionLayerDiagnosis d =
          _diag(rules, _set(active: 'guest'), _notes, _at(6, 23));
      expect(d.effectiveLevel, _L.critical);
      expect(d.decidedBy, ProtectionLayer.manualProfile);
      // Direct ties scheduled.
      d = _diag(rules, _set(), _notes, _at(6, 23));
      expect(d.decidedBy, ProtectionLayer.directRule);
      expect(d.directRuleId, 'd');
      expect(d.scheduledRuleId, 'w');
    });

    test(
        'a stronger direct rule beats a weaker scheduled profile and vice '
        'versa', () {
      final SecurityProfileSet s = _set(trip: _trip(_L.sensitive));
      ProtectionLayerDiagnosis d = _diag(<SmartRule>[
        _apply('t', _tripId),
        _direct('d', _notes, _A.critical),
      ], s, _notes, _at(6, 23));
      expect(d.effectiveLevel, _L.critical);
      expect(d.decidedBy, ProtectionLayer.directRule);
      d = _diag(<SmartRule>[
        _apply('w', 'guest'),
        _direct('d', _notes, _A.sensitive),
      ], s, _notes, _at(6, 23));
      expect(d.effectiveLevel, _L.critical);
      expect(d.decidedBy, ProtectionLayer.scheduledProfile);
    });

    test(
        'a scheduled profile never lowers a stricter saved level or '
        'manual profile', () {
      final SecurityProfileSet s = _set(
          active: 'guest',
          trip: _trip(null, apps: const <String, _L>{_chat: _L.sensitive}));
      final ProtectionLayerDiagnosis d =
          _diag(<SmartRule>[_apply('t', _tripId)], s, _chat, _at(6, 23));
      expect(d.effectiveLevel, _L.critical);
      expect(d.decidedBy, ProtectionLayer.manualProfile);
      // Saved Sensitive + scheduled Sensitive: saved keeps attribution.
      final ProtectionLayerDiagnosis d2 = _diag(
          <SmartRule>[_apply('t', _tripId)],
          s.withActive('normal'),
          _chat,
          _at(6, 23));
      expect(d2.effectiveLevel, _L.sensitive);
      expect(d2.decidedBy, ProtectionLayer.savedLevel);
    });

    test('expiry falls back to the next strongest layer (manual Kids)', () {
      final SecurityProfileSet s =
          _set(active: 'kids', kids: const <String, _L>{_chat: _L.critical});
      final List<SmartRule> rules = <SmartRule>[_apply('w', 'guest')];
      expect(_diag(rules, s, _notes, _at(6, 23)).decidedBy,
          ProtectionLayer.scheduledProfile);
      final ProtectionLayerDiagnosis after = _diag(rules, s, _notes, _at(7, 7));
      expect(after.effectiveLevel, _L.standard);
      expect(after.decidedBy, ProtectionLayer.savedLevel);
      final ProtectionLayerDiagnosis chat = _diag(rules, s, _chat, _at(7, 7));
      expect(chat.effectiveLevel, _L.critical);
      expect(chat.decidedBy, ProtectionLayer.manualProfile);
    });

    test('unprotected app: no layer applies (diagnosis is empty)', () {
      final ProtectionLayerDiagnosis d =
          _diag(<SmartRule>[_apply('w', 'guest')], _set(), _maps, _at(6, 23));
      expect(d.effectiveLevel, isNull);
      expect(d.decidedBy, isNull);
    });

    test(
        'diagnosis == enforcement over a weekly grid for every scenario '
        '(the diagnostics never disagree with what is sent)', () {
      final List<(List<SmartRule>, SecurityProfileSet)> scenarios =
          <(List<SmartRule>, SecurityProfileSet)>[
        (<SmartRule>[_apply('w', 'guest')], _set()),
        (<SmartRule>[_apply('w', 'guest')], _set(active: 'guest')),
        (
          <SmartRule>[
            _apply('k', 'kids', days: SmartRuleDays.everyDay),
            _direct('d', _notes, _A.sensitive, days: const <int>[1, 2]),
            _apply('t', _tripId, time: const SmartRuleTime.allDay()),
          ],
          _set(
              active: 'work',
              trip: _trip(_L.sensitive),
              kids: const <String, _L>{_notes: _L.critical}),
        ),
        (<SmartRule>[_apply('m', _tripId)], _set()),
      ];
      for (final (List<SmartRule> rules, SecurityProfileSet s) in scenarios) {
        for (int day = 1; day <= 7; day++) {
          for (final int minute in <int>[0, 359, 360, 720, 1319, 1320, 1439]) {
            final DateTime t = _at(day, minute ~/ 60, minute % 60);
            for (final String pkg in <String>[_notes, _chat, _maps]) {
              expect(_diag(rules, s, pkg, t).effectiveLevel,
                  _effective(rules, s, pkg, t),
                  reason: '$pkg $t ${s.activeProfileId}');
            }
          }
        }
      }
    });
  });

  group('§7 expiry vs manual reduction', () {
    test(
        '(B) expiry is evaluation, not a change: the snapshot is identical '
        'at every instant, so nothing is relaxed and no proof or flag can '
        'be involved', () {
      final List<SmartRule> rules = <SmartRule>[_apply('w', 'guest')];
      final List<String> t1 = _t(
          SecurityProfilePolicy.combinedTransport(rules, _set(), _protected));
      final List<String> t2 = _t(
          SecurityProfilePolicy.combinedTransport(rules, _set(), _protected));
      expect(t1, t2);
      expect(_relaxed(rules, rules), isEmpty);
      expect(_effective(rules, _set(), _notes, _at(6, 23)), _L.critical);
      expect(_effective(rules, _set(), _notes, _at(7, 7)), _L.standard);
    });

    test('(A) adding / enabling / widening an activation relaxes nothing', () {
      final SmartRule w = _apply('w', 'guest');
      expect(_relaxed(const <SmartRule>[], <SmartRule>[w]), isEmpty);
      expect(
          _relaxed(<SmartRule>[_apply('w', 'guest', enabled: false)],
              <SmartRule>[w]),
          isEmpty);
      expect(
        _relaxed(<SmartRule>[
          w
        ], <SmartRule>[
          _apply('w', 'guest', days: SmartRuleDays.everyDay),
        ]),
        isEmpty,
      );
    });

    test(
        '(C) delete / disable / narrow / retarget to a weaker profile are '
        'reductions of exactly the affected protected apps', () {
      final SmartRule w = _apply('w', 'guest');
      final SecurityProfileSet s =
          _set(kids: const <String, _L>{_chat: _L.critical});
      for (final List<SmartRule> after in <List<SmartRule>>[
        const <SmartRule>[],
        <SmartRule>[_apply('w', 'guest', enabled: false)],
        <SmartRule>[
          _apply('w', 'guest', days: const <int>[6])
        ],
        <SmartRule>[_apply('w', 'home')],
      ]) {
        expect(_relaxed(<SmartRule>[w], after, before: s), _protected,
            reason: '$after');
      }
      // Guest → Kids(chat Critical): only notes loses protection.
      expect(
          _relaxed(<SmartRule>[w], <SmartRule>[_apply('w', 'kids')], before: s),
          <String>{_notes});
    });

    test(
        '(C) editing a REFERENCED profile weaker is a reduction; editing an '
        'unreferenced inactive profile changes nothing enforced', () {
      final List<SmartRule> rules = <SmartRule>[_apply('t', _tripId)];
      final SecurityProfileSet before = _set(trip: _trip(_L.critical));
      final SecurityProfileSet weaker = _set(trip: _trip(_L.sensitive));
      expect(
        profileChangeImpact(
          rules: rules,
          before: before,
          after: weaker,
          protectedPackages: _protected,
          now: _at(6, 12),
        ).relaxed,
        _protected,
        reason: 'Trip Critical → Sensitive lowers both (chat was Critical '
            'through Trip)',
      );
      expect(sameEnforcedPolicy(rules, before, weaker, _protected), isFalse);
      expect(
        sameEnforcedPolicy(const <SmartRule>[], before, weaker, _protected),
        isTrue,
        reason: 'unreferenced inactive custom profile',
      );
      expect(rulesReferencing(rules, _tripId), rules);
      expect(rulesReferencing(rules, 'guest'), isEmpty);
    });

    test(
        'a manual switch away from Guest is not a reduction while an '
        'all-week Guest activation still covers it (fallback, no PIN)', () {
      final List<SmartRule> rules = <SmartRule>[
        _apply('w', 'guest',
            days: SmartRuleDays.everyDay, time: const SmartRuleTime.allDay()),
      ];
      expect(
        profileChangeImpact(
          rules: rules,
          before: _set(active: 'guest'),
          after: _set(),
          protectedPackages: _protected,
          now: _at(1, 12),
        ).relaxed,
        isEmpty,
      );
      expect(
        profileChangeImpact(
          rules: const <SmartRule>[],
          before: _set(active: 'guest'),
          after: _set(),
          protectedPackages: _protected,
          now: _at(1, 12),
        ).relaxed,
        _protected,
      );
    });

    test('raisedAt reports only apps stricter right now', () {
      final List<SmartRule> after = <SmartRule>[_apply('w', 'guest')];
      expect(
        SecurityProfilePolicy.combinedRaisedAt(
          rulesBefore: const <SmartRule>[],
          rulesAfter: after,
          profilesBefore: _set(),
          profilesAfter: _set(),
          protectedPackages: _protected,
          localDateTime: _at(6, 23),
        ),
        _protected,
      );
      expect(
        SecurityProfilePolicy.combinedRaisedAt(
          rulesBefore: const <SmartRule>[],
          rulesAfter: after,
          profilesBefore: _set(),
          profilesAfter: _set(),
          protectedPackages: _protected,
          localDateTime: _at(6, 12),
        ),
        isEmpty,
      );
    });
  });
}
