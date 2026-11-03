// Phase 10 / M1 (PRD 10B–10E): the pure Smart Rule evaluator.
//
// Production SmartRuleEvaluator over production SmartRule values. Local
// DateTimes are built from fields, so results do not depend on the test
// machine's time zone. 2026-11-02 is a Monday; 2026-11-08 a Sunday.

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/rules/smart_rule_evaluator.dart';

typedef _O = SmartRuleOutcome;
typedef _R = SmartRuleReason;
typedef _S = SmartRuleTimeSegment;

const SmartRuleEvaluator _engine = SmartRuleEvaluator();
const String _mail = 'com.example.mail';
const String _bank = 'com.example.bank';

/// Day of week (1 = Monday) in the week of 2026-11-02, at hh:mm[:ss.ms].
DateTime _at(int weekday, int hour, int minute,
        [int second = 0, int millisecond = 0]) =>
    DateTime(2026, 11, 1 + weekday, hour, minute, second, millisecond);

SmartRuleTime _w(int sh, int sm, int eh, int em) =>
    SmartRuleTime.window(startMinute: sh * 60 + sm, endMinute: eh * 60 + em);

SmartRule _rule({
  Iterable<String> targets = const <String>[_mail],
  Iterable<int> days = SmartRuleDays.weekdays,
  SmartRuleTime? time,
  bool enabled = true,
}) =>
    SmartRule(
      id: 'r1',
      name: 'Rule',
      targetPackages: targets,
      days: days,
      time: time ?? _w(9, 0, 17, 0),
      enabled: enabled,
    );

SmartRuleEvaluation _eval(SmartRule rule, DateTime t, [String app = _mail]) =>
    _engine.evaluate(rule, app, t);

void _expect(
  SmartRule rule,
  DateTime t,
  _R reason, {
  String app = _mail,
  _S? segment,
  int? owner,
}) {
  final SmartRuleEvaluation e = _eval(rule, t, app);
  expect(e.reason, reason, reason: '$t → $e');
  expect(
    e.outcome,
    reason == _R.matched ? _O.match : _O.noMatch,
    reason: '$t → $e',
  );
  expect(e.isMatch, reason == _R.matched);
  if (segment != null) expect(e.segment, segment, reason: '$t → $e');
  if (owner != null) expect(e.ownerDay, owner, reason: '$t → $e');
}

void main() {
  test('time-zone independence: the fixture weekdays are as documented', () {
    expect(_at(1, 0, 0).weekday, DateTime.monday);
    expect(_at(7, 23, 59).weekday, DateTime.sunday);
    expect(_at(1, 0, 0).isUtc, isFalse);
  });

  group('11. enabled matching rule', () {
    test('match with full diagnostics', () {
      final SmartRuleEvaluation e = _eval(_rule(), _at(3, 10, 30));
      expect(e.outcome, _O.match);
      expect(e.reason, _R.matched);
      expect(e.isMatch, isTrue);
      expect(e.ruleId, 'r1');
      expect(e.appPackage, _mail);
      expect(e.weekday, 3);
      expect(e.minuteOfDay, 630);
      expect(e.segment, _S.sameDay);
      expect(e.ownerDay, 3);
      expect(e.enabled, isTrue);
      expect(e.appTargeted, isTrue);
      expect(e.inTimeWindow, isTrue);
      expect(e.daySelected, isTrue);
    });
  });

  group('12. disabled rule', () {
    test('never matches, even when every condition holds', () {
      final SmartRuleEvaluation e =
          _eval(_rule(enabled: false), _at(3, 10, 30));
      expect(e.outcome, _O.noMatch);
      expect(e.reason, _R.ruleDisabled);
      expect(e.isMatch, isFalse);
      // The other conditions are still reported for diagnostics.
      expect(e.enabled, isFalse);
      expect(e.appTargeted, isTrue);
      expect(e.inTimeWindow, isTrue);
      expect(e.daySelected, isTrue);
    });

    test('disabled is reported before any other failing condition', () {
      _expect(_rule(enabled: false), _at(6, 3, 0), _R.ruleDisabled, app: _bank);
    });
  });

  group('13. app condition (exact match)', () {
    test('a non-target app does not match', () {
      final SmartRuleEvaluation e = _eval(_rule(), _at(3, 10, 0), _bank);
      expect(e.reason, _R.appNotTargeted);
      expect(e.outcome, _O.noMatch);
      expect(e.appTargeted, isFalse);
    });

    test('no substring, prefix, suffix or case-insensitive matching', () {
      for (final String other in <String>[
        'com.example.mail2',
        'com.example.mai',
        'com.example',
        'org.com.example.mail',
        'com.example.mail.debug',
        'com.Example.mail',
        'COM.EXAMPLE.MAIL',
      ]) {
        _expect(_rule(), _at(3, 10, 0), _R.appNotTargeted, app: other);
      }
    });

    test('multiple targets: each matches, others do not', () {
      final SmartRule r = _rule(targets: <String>[_mail, _bank]);
      _expect(r, _at(3, 10, 0), _R.matched);
      _expect(r, _at(3, 10, 0), _R.matched, app: _bank);
      _expect(r, _at(3, 10, 0), _R.appNotTargeted, app: 'com.example.chat');
    });
  });

  group('14. invalid evaluation input', () {
    test('blank or malformed package → invalidInput, no condition checked', () {
      for (final String bad in <String>['', ' ', 'mail', 'com..mail', '*']) {
        final SmartRuleEvaluation e = _eval(_rule(), _at(3, 10, 0), bad);
        expect(e.outcome, _O.invalidInput, reason: bad);
        expect(e.reason, _R.invalidAppPackage);
        expect(e.isMatch, isFalse);
        expect(e.appTargeted, isNull);
        expect(e.inTimeWindow, isNull);
        expect(e.daySelected, isNull);
        expect(e.weekday, isNull);
      }
    });

    test('a UTC instant is rejected, never shifted', () {
      final SmartRuleEvaluation e =
          _eval(_rule(), DateTime.utc(2026, 11, 4, 10, 0));
      expect(e.outcome, _O.invalidInput);
      expect(e.reason, _R.nonLocalTime);
      expect(e.isMatch, isFalse);
    });

    test('invalid input is distinct from a legitimate no-match', () {
      final SmartRuleEvaluation invalid = _eval(_rule(), _at(3, 10, 0), '');
      final SmartRuleEvaluation other = _eval(_rule(), _at(3, 10, 0), _bank);
      expect(invalid.outcome, isNot(other.outcome));
    });

    test('a disabled rule with invalid input still reports the input', () {
      expect(
        _eval(_rule(enabled: false), _at(3, 10, 0), '').reason,
        _R.invalidAppPackage,
      );
    });
  });

  group('15–17. same-day window 09:00–17:00 (start inclusive, end exclusive)',
      () {
    final SmartRule r = _rule();
    test('15. exact start matches; one minute / millisecond before does not',
        () {
      _expect(r, _at(3, 9, 0), _R.matched, segment: _S.sameDay);
      _expect(r, _at(3, 8, 59, 59, 999), _R.outsideTimeWindow,
          segment: _S.none);
    });

    test('16. exact end does not match; 16:59:59.999 does', () {
      _expect(r, _at(3, 16, 59), _R.matched);
      _expect(r, _at(3, 16, 59, 59, 999), _R.matched);
      _expect(r, _at(3, 17, 0), _R.outsideTimeWindow);
      _expect(r, _at(3, 17, 0, 0, 1), _R.outsideTimeWindow);
    });

    test('17. inside and outside the window; midnight', () {
      _expect(r, _at(3, 12, 0), _R.matched);
      _expect(r, _at(3, 0, 0), _R.outsideTimeWindow);
      _expect(r, _at(3, 23, 59), _R.outsideTimeWindow);
      final SmartRuleEvaluation e = _eval(r, _at(3, 20, 0));
      expect(e.inTimeWindow, isFalse);
      expect(e.daySelected, isNull); // no owner day outside a window
    });

    test('a window starting at midnight and one ending at 23:59', () {
      final SmartRule early = _rule(time: _w(0, 0, 6, 0));
      _expect(early, _at(3, 0, 0), _R.matched);
      _expect(early, _at(3, 6, 0), _R.outsideTimeWindow);
      final SmartRule late = _rule(time: _w(18, 0, 23, 59));
      _expect(late, _at(3, 23, 58, 59, 999), _R.matched);
      _expect(late, _at(3, 23, 59), _R.outsideTimeWindow);
    });
  });

  group('18–19. cross-midnight 22:00–06:00 (owner day = start day)', () {
    final SmartRule mon = _rule(days: <int>[1], time: _w(22, 0, 6, 0));

    test('18. both sides of midnight are inside; the ends are exact', () {
      _expect(mon, _at(1, 22, 0), _R.matched,
          segment: _S.overnightBeforeMidnight, owner: 1);
      _expect(mon, _at(1, 21, 59, 59, 999), _R.outsideTimeWindow);
      _expect(mon, _at(1, 23, 59, 59, 999), _R.matched);
      _expect(mon, _at(2, 0, 0), _R.matched,
          segment: _S.overnightAfterMidnight, owner: 1);
      _expect(mon, _at(2, 5, 59, 59, 999), _R.matched);
      _expect(mon, _at(2, 6, 0), _R.outsideTimeWindow, segment: _S.none);
      _expect(mon, _at(2, 12, 0), _R.outsideTimeWindow);
    });

    test('19. PRD example: Monday-only overnight window', () {
      // Monday 23:00 matches.
      _expect(mon, _at(1, 23, 0), _R.matched, owner: 1);
      // Tuesday 02:00 matches as part of Monday's window.
      final SmartRuleEvaluation tue2 = _eval(mon, _at(2, 2, 0));
      expect(tue2.isMatch, isTrue);
      expect(tue2.weekday, 2);
      expect(tue2.ownerDay, 1);
      // Tuesday 06:00 does not match.
      _expect(mon, _at(2, 6, 0), _R.outsideTimeWindow);
      // Tuesday 23:00 does not match: Tuesday is not selected.
      _expect(mon, _at(2, 23, 0), _R.dayNotSelected, owner: 2);
      // Monday 02:00 belongs to SUNDAY's window: not selected.
      _expect(mon, _at(1, 2, 0), _R.dayNotSelected,
          segment: _S.overnightAfterMidnight, owner: 7);
    });

    test('Tuesday-only: only the Tuesday-night part matches', () {
      final SmartRule tue = _rule(days: <int>[2], time: _w(22, 0, 6, 0));
      _expect(tue, _at(2, 2, 0), _R.dayNotSelected, owner: 1);
      _expect(tue, _at(2, 22, 30), _R.matched, owner: 2);
      _expect(tue, _at(3, 5, 0), _R.matched, owner: 2);
    });

    test('23:59–00:00 is a one-minute overnight window', () {
      final SmartRule r =
          _rule(days: SmartRuleDays.everyDay, time: _w(23, 59, 0, 0));
      _expect(r, _at(3, 23, 59, 30), _R.matched);
      _expect(r, _at(4, 0, 0), _R.outsideTimeWindow);
      _expect(r, _at(3, 23, 58, 59, 999), _R.outsideTimeWindow);
    });
  });

  group('20. Sunday → Monday rollover', () {
    test('Sunday overnight window continues into Monday morning', () {
      final SmartRule sun = _rule(days: <int>[7], time: _w(22, 0, 6, 0));
      _expect(sun, _at(7, 23, 0), _R.matched, owner: 7);
      // Monday 2026-11-09, 01:00: owned by Sunday 2026-11-08.
      final DateTime monNext = DateTime(2026, 11, 9, 1, 0);
      expect(monNext.weekday, DateTime.monday);
      _expect(sun, monNext, _R.matched,
          segment: _S.overnightAfterMidnight, owner: 7);
      _expect(sun, DateTime(2026, 11, 9, 6, 0), _R.outsideTimeWindow);
      // The Monday morning BEFORE that Sunday is owned by the previous
      // Sunday too (a recurring weekly rule).
      _expect(sun, _at(1, 1, 0), _R.matched, owner: 7);
      _expect(sun, _at(1, 23, 0), _R.dayNotSelected, owner: 1);
    });

    test('Monday-only overnight never borrows from Sunday', () {
      final SmartRule mon = _rule(days: <int>[1], time: _w(22, 0, 6, 0));
      _expect(mon, DateTime(2026, 11, 9, 1, 0), _R.dayNotSelected, owner: 7);
    });

    test('across a month and year boundary', () {
      final SmartRule r = _rule(
          days: <int>[DateTime(2026, 12, 31).weekday], time: _w(22, 0, 6, 0));
      _expect(r, DateTime(2027, 1, 1, 3, 0), _R.matched,
          owner: DateTime(2026, 12, 31).weekday);
    });
  });

  group('21. multiple selected days', () {
    test('weekdays vs weekend', () {
      final SmartRule weekdays = _rule();
      final SmartRule weekend = _rule(days: SmartRuleDays.weekend);
      for (int d = 1; d <= 7; d++) {
        final bool isWeekday = d <= 5;
        _expect(weekdays, _at(d, 10, 0),
            isWeekday ? _R.matched : _R.dayNotSelected);
        _expect(
            weekend, _at(d, 10, 0), isWeekday ? _R.dayNotSelected : _R.matched);
      }
    });

    test('a non-contiguous selection', () {
      final SmartRule r = _rule(days: <int>[1, 3, 5]);
      for (int d = 1; d <= 7; d++) {
        _expect(r, _at(d, 10, 0),
            d.isOdd && d <= 5 ? _R.matched : _R.dayNotSelected);
      }
    });

    test('Friday overnight continues into Saturday on a weekday rule', () {
      final SmartRule r = _rule(time: _w(22, 0, 6, 0)); // Mon–Fri
      _expect(r, _at(6, 3, 0), _R.matched, owner: 5); // Sat 03:00 ← Fri
      _expect(r, _at(1, 3, 0), _R.dayNotSelected, owner: 7); // Mon ← Sun
    });
  });

  group('22. explicit all day', () {
    test('the whole selected day, midnight to midnight', () {
      final SmartRule r =
          _rule(days: <int>[3], time: const SmartRuleTime.allDay());
      _expect(r, _at(3, 0, 0), _R.matched, segment: _S.allDay, owner: 3);
      _expect(r, _at(3, 23, 59, 59, 999), _R.matched);
      _expect(r, _at(4, 0, 0), _R.dayNotSelected, owner: 4);
      _expect(r, _at(2, 23, 59, 59, 999), _R.dayNotSelected, owner: 2);
    });

    test('all day still needs the app and the enabled state', () {
      final SmartRule r = _rule(time: const SmartRuleTime.allDay());
      _expect(r, _at(3, 3, 0), _R.appNotTargeted, app: _bank);
      _expect(r.copyWith(enabled: false), _at(3, 3, 0), _R.ruleDisabled);
    });
  });

  group('23. zero-length interval', () {
    test('cannot be constructed, so it can never act as all day', () {
      expect(
        () => _w(9, 0, 9, 0),
        throwsA(isA<SmartRuleFormatException>()),
      );
      expect(
        () => _rule(time: _w(0, 0, 0, 0)),
        throwsA(isA<SmartRuleFormatException>()),
      );
    });

    test('a one-minute window matches that minute only', () {
      final SmartRule r = _rule(time: _w(9, 0, 9, 1));
      _expect(r, _at(3, 9, 0, 59, 999), _R.matched);
      _expect(r, _at(3, 9, 1), _R.outsideTimeWindow);
      _expect(r, _at(3, 8, 59), _R.outsideTimeWindow);
    });
  });

  group('24. determinism', () {
    test('the same inputs always give an equal result', () {
      final SmartRule r = _rule(time: _w(22, 0, 6, 0));
      final List<DateTime> times = <DateTime>[
        for (int d = 1; d <= 7; d++)
          for (int h = 0; h < 24; h += 3) _at(d, h, 17, 5, 9),
      ];
      for (final DateTime t in times) {
        final SmartRuleEvaluation a = _eval(r, t);
        for (int i = 0; i < 5; i++) {
          final SmartRuleEvaluation b = _eval(r, t);
          expect(b, a);
          expect(b.hashCode, a.hashCode);
        }
        expect(const SmartRuleEvaluator().evaluate(r, _mail, t), a);
      }
    });

    test('exhaustive minute sweep equals an independent reference', () {
      final List<SmartRule> rules = <SmartRule>[
        _rule(days: <int>[1, 4], time: _w(22, 30, 5, 15)),
        _rule(days: <int>[7], time: _w(9, 0, 17, 0)),
        _rule(days: <int>[2, 7], time: const SmartRuleTime.allDay()),
      ];
      for (final SmartRule r in rules) {
        for (int d = 1; d <= 7; d++) {
          for (int m = 0; m < 1440; m++) {
            final DateTime t = _at(d, m ~/ 60, m % 60, 30);
            expect(_eval(r, t).isMatch, _reference(r, d, m),
                reason: '$r at day $d minute $m');
          }
        }
      }
    });
  });

  group('25. no I/O or side effects', () {
    test('the rule and inputs are unchanged; results are values', () {
      final SmartRule r = _rule(targets: <String>[_mail, _bank]);
      final SmartRule copy = SmartRule.fromJson(r.toJson());
      final DateTime t = _at(3, 10, 0);
      final DateTime tCopy = DateTime.fromMicrosecondsSinceEpoch(
        t.microsecondsSinceEpoch,
      );
      _eval(r, t);
      _eval(r, t, _bank);
      _eval(r, t, '');
      expect(r, copy);
      expect(t, tCopy);
    });

    test('evaluation reads only the supplied time, never the clock', () {
      // A time years away from "now" evaluates by its own fields.
      final SmartRule r = _rule(days: <int>[3]);
      _expect(r, DateTime(1999, 12, 1, 10, 0), _R.matched); // a Wednesday
      _expect(r, DateTime(2099, 12, 2, 10, 0), _R.matched); // a Wednesday
    });
  });
}

/// Independent reference (not the production code path): a minute m on day
/// d is covered when some selected day s has an occurrence of the window
/// [start, end) — shifted by a day for the overnight part — containing it.
bool _reference(SmartRule r, int d, int m) {
  if (!r.enabled) return false;
  final SmartRuleTime time = r.time;
  for (final int s in r.days) {
    final int dayOffset = (d - s) % 7; // 0 = same day, 1 = next day
    final int absolute = dayOffset * 1440 + m;
    final int start;
    final int end;
    if (time is SmartRuleWindow) {
      start = time.startMinute;
      end = time.crossesMidnight ? time.endMinute + 1440 : time.endMinute;
    } else {
      start = 0;
      end = 1440;
    }
    if (absolute >= start && absolute < end) return true;
  }
  return false;
}
