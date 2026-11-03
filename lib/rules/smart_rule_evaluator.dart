import 'smart_rule.dart';

/// Phase 10 / M1 (PRD 10B): the overall answer.
enum SmartRuleOutcome {
  /// Every condition holds (enabled AND app AND time AND day).
  match,

  /// The inputs were valid and at least one condition does not hold.
  noMatch,

  /// The inputs could not be evaluated. Callers must treat this exactly like
  /// [noMatch]: an invalid input never makes a rule apply and never allows
  /// access.
  invalidInput,
}

/// Why the evaluator answered as it did (diagnostics and tests). For a
/// non-match it is the FIRST failing check in this fixed order: input
/// checks, enabled, app, time, day.
enum SmartRuleReason {
  matched,
  ruleDisabled,
  appNotTargeted,
  outsideTimeWindow,
  dayNotSelected,

  /// The app package is blank or not a well-formed package name.
  invalidAppPackage,

  /// A UTC [DateTime] was supplied; rules use local wall-clock time only.
  nonLocalTime,
}

/// Which part of the time condition the evaluation instant fell into.
enum SmartRuleTimeSegment {
  /// Outside the window (or not evaluated).
  none,

  /// An explicit all-day rule; the owner day is the current day.
  allDay,

  /// A same-day window (start < end); the owner day is the current day.
  sameDay,

  /// A cross-midnight window, before midnight; owner day = current day.
  overnightBeforeMidnight,

  /// A cross-midnight window, after midnight; owner day = the PREVIOUS day,
  /// the day the window started (Monday's previous day is Sunday).
  overnightAfterMidnight,
}

/// Immutable evaluation record. Condition flags are `null` when the inputs
/// were invalid (nothing was evaluated). [daySelected] is `null` when the
/// instant was outside the time window: an owner day exists only inside a
/// window.
final class SmartRuleEvaluation {
  const SmartRuleEvaluation({
    required this.ruleId,
    required this.appPackage,
    required this.outcome,
    required this.reason,
    this.weekday,
    this.minuteOfDay,
    this.segment = SmartRuleTimeSegment.none,
    this.ownerDay,
    this.enabled,
    this.appTargeted,
    this.inTimeWindow,
    this.daySelected,
  });

  final String ruleId;
  final String appPackage;
  final SmartRuleOutcome outcome;
  final SmartRuleReason reason;

  /// Weekday of the evaluation instant (Monday = 1).
  final int? weekday;

  /// Local minute of day of the evaluation instant (seconds and
  /// milliseconds are truncated; boundaries are whole minutes).
  final int? minuteOfDay;

  final SmartRuleTimeSegment segment;

  /// The day whose window contains the instant.
  final int? ownerDay;

  final bool? enabled;
  final bool? appTargeted;
  final bool? inTimeWindow;
  final bool? daySelected;

  bool get isMatch => outcome == SmartRuleOutcome.match;

  @override
  bool operator ==(Object other) =>
      other is SmartRuleEvaluation &&
      other.ruleId == ruleId &&
      other.appPackage == appPackage &&
      other.outcome == outcome &&
      other.reason == reason &&
      other.weekday == weekday &&
      other.minuteOfDay == minuteOfDay &&
      other.segment == segment &&
      other.ownerDay == ownerDay &&
      other.enabled == enabled &&
      other.appTargeted == appTargeted &&
      other.inTimeWindow == inTimeWindow &&
      other.daySelected == daySelected;

  @override
  int get hashCode => Object.hash(
        ruleId,
        appPackage,
        outcome,
        reason,
        weekday,
        minuteOfDay,
        segment,
        ownerDay,
        enabled,
        appTargeted,
        inTimeWindow,
        daySelected,
      );

  @override
  String toString() => 'SmartRuleEvaluation($ruleId, $appPackage: '
      '${outcome.name}/${reason.name}, day=$weekday, minute=$minuteOfDay, '
      '${segment.name}, owner=$ownerDay)';
}

/// Phase 10 / M1 (PRD 10B): one pure, deterministic condition evaluator.
///
/// `evaluate(rule, appPackage, localDateTime)` applies a logical AND of the
/// rule's enabled state, exact target app (10E), time window (10C) and
/// selected day (10D, using the window's owner day).
///
/// No I/O, no clock reads, no timers, no state. It decides nothing about
/// protection: it never changes a level, grants authorization, or touches
/// a challenge, ticket or grace session. Nothing in the app calls it yet;
/// rule actions arrive in Phase 10 / M2.
///
/// Time-zone policy: [localDateTime] must be a LOCAL [DateTime] (the
/// caller's device wall clock, e.g. `DateTime.now()` at the call site). Its
/// weekday, hour and minute are read as-is; nothing is converted. A UTC
/// value is rejected ([SmartRuleReason.nonLocalTime]) rather than silently
/// shifted.
final class SmartRuleEvaluator {
  const SmartRuleEvaluator();

  SmartRuleEvaluation evaluate(
    SmartRule rule,
    String appPackage,
    DateTime localDateTime,
  ) {
    if (!SmartRule.isValidPackageName(appPackage)) {
      return SmartRuleEvaluation(
        ruleId: rule.id,
        appPackage: appPackage,
        outcome: SmartRuleOutcome.invalidInput,
        reason: SmartRuleReason.invalidAppPackage,
      );
    }
    if (localDateTime.isUtc) {
      return SmartRuleEvaluation(
        ruleId: rule.id,
        appPackage: appPackage,
        outcome: SmartRuleOutcome.invalidInput,
        reason: SmartRuleReason.nonLocalTime,
      );
    }

    final int weekday = localDateTime.weekday;
    final int minute = localDateTime.hour * 60 + localDateTime.minute;
    final bool appTargeted = rule.targets(appPackage);
    final SmartRuleTimeSegment segment = _segment(rule.time, minute);
    final int? ownerDay = switch (segment) {
      SmartRuleTimeSegment.none => null,
      SmartRuleTimeSegment.overnightAfterMidnight =>
        SmartRuleDays.previous(weekday),
      _ => weekday,
    };
    final bool inWindow = segment != SmartRuleTimeSegment.none;
    final bool? daySelected =
        ownerDay == null ? null : rule.days.contains(ownerDay);

    final SmartRuleReason reason;
    if (!rule.enabled) {
      reason = SmartRuleReason.ruleDisabled;
    } else if (!appTargeted) {
      reason = SmartRuleReason.appNotTargeted;
    } else if (!inWindow) {
      reason = SmartRuleReason.outsideTimeWindow;
    } else if (daySelected != true) {
      reason = SmartRuleReason.dayNotSelected;
    } else {
      reason = SmartRuleReason.matched;
    }

    return SmartRuleEvaluation(
      ruleId: rule.id,
      appPackage: appPackage,
      outcome: reason == SmartRuleReason.matched
          ? SmartRuleOutcome.match
          : SmartRuleOutcome.noMatch,
      reason: reason,
      weekday: weekday,
      minuteOfDay: minute,
      segment: segment,
      ownerDay: ownerDay,
      enabled: rule.enabled,
      appTargeted: appTargeted,
      inTimeWindow: inWindow,
      daySelected: daySelected,
    );
  }

  /// Start inclusive, end exclusive.
  static SmartRuleTimeSegment _segment(SmartRuleTime time, int minute) {
    switch (time) {
      case SmartRuleAllDay():
        return SmartRuleTimeSegment.allDay;
      case SmartRuleWindow(:final int startMinute, :final int endMinute):
        if (startMinute < endMinute) {
          return minute >= startMinute && minute < endMinute
              ? SmartRuleTimeSegment.sameDay
              : SmartRuleTimeSegment.none;
        }
        if (minute >= startMinute) {
          return SmartRuleTimeSegment.overnightBeforeMidnight;
        }
        if (minute < endMinute) {
          return SmartRuleTimeSegment.overnightAfterMidnight;
        }
        return SmartRuleTimeSegment.none;
    }
  }
}
