/// Phase 10 / M2 (PRD 10F): what a Smart Rule action does to enforcement.
///
/// Pure Dart, no I/O, no clock read (every function takes the instant).
/// Mirrors native `SmartRulePolicy.kt`, which is the final gate and applies
/// the same rules from its own persisted copy at each foreground decision.
///
/// Raise-only contract (see `docs/architecture.md`, Phase 10 / M2):
///  * effective level = the stricter of the app's SAVED (baseline) level and
///    the strictest raising action of the enabled rules matching it now;
///  * it is never below the baseline: Standard and the reserved Unlocked
///    action never take part, and no rule can lower a level, remove
///    protection, create grace or authorize access;
///  * several matching rules → the strictest raising action, resolved by
///    the one Phase 10 / M3 conflict policy ([SmartRuleConflictPolicy],
///    PRD 10J: Critical > Sensitive > Standard > Unlocked, order-independent).
library;

import '../data/models/app_security_level.dart';
import 'smart_rule.dart';
import 'smart_rule_conflict.dart';
import 'smart_rule_evaluator.dart';

abstract final class SmartRulePolicy {
  /// Native transport version for `smartRules` (`smartRulesVersion`).
  static const int transportVersion = 1;

  static const SmartRuleEvaluator _evaluator = SmartRuleEvaluator();

  /// The strictest level that the enabled rules in [rules] RAISE
  /// [appPackage] to at [localDateTime], or null when none does (no match,
  /// only non-raising actions, invalid package or a UTC instant).
  static AppSecurityLevel? ruleLevelFor(
    Iterable<SmartRule> rules,
    String appPackage,
    DateTime localDateTime,
  ) =>
      resolutionFor(rules, appPackage, localDateTime).ruleLevel;

  /// Phase 10 / M3 (10J): the full conflict resolution behind
  /// [ruleLevelFor] (strongest action, tied and matching rule ids).
  static SmartRuleResolution resolutionFor(
    Iterable<SmartRule> rules,
    String appPackage,
    DateTime localDateTime,
  ) =>
      SmartRuleConflictPolicy.resolve(
        rules,
        (SmartRule rule) =>
            _evaluator.evaluate(rule, appPackage, localDateTime).isMatch,
      );

  /// Baseline floor: the stricter of [baseline] and [ruleLevel]. Never
  /// below [baseline].
  static AppSecurityLevel effectiveLevel(
    AppSecurityLevel baseline,
    AppSecurityLevel? ruleLevel,
  ) =>
      ruleLevel != null && ruleLevel.isStricterThan(baseline)
          ? ruleLevel
          : baseline;

  /// Like [ruleLevelFor] for an explicit ISO weekday and minute of day.
  static AppSecurityLevel? levelAt(
    Iterable<SmartRule> rules,
    String appPackage,
    int weekday,
    int minuteOfDay,
  ) =>
      SmartRuleConflictPolicy.resolve(
        rules,
        (SmartRule rule) => SmartRuleEvaluator.matchesAt(
          rule,
          appPackage,
          weekday,
          minuteOfDay,
        ),
      ).ruleLevel;

  /// Packages for which [after] gives LESS rule strictness than [before] at
  /// some (weekday, minute) of the week: a disabled, deleted, narrowed or
  /// lowered raising rule. Such a change needs the CR-2 credential gate and
  /// the native `authorizedRuleRelaxation` flag. Empty = [after] keeps or
  /// adds strictness everywhere.
  ///
  /// Exact over the whole week: the rule level is constant between
  /// consecutive boundaries (minute 0 and every window start and end), so
  /// checking each boundary minute of each day is sufficient.
  static Set<String> relaxedPackages(
    Iterable<SmartRule> before,
    Iterable<SmartRule> after,
  ) {
    final List<SmartRule> old = _raising(before);
    if (old.isEmpty) return const <String>{};
    final List<SmartRule> next = _raising(after);
    final Set<int> boundaries = <int>{0};
    for (final SmartRule r in <SmartRule>[...old, ...next]) {
      final SmartRuleTime t = r.time;
      if (t is SmartRuleWindow) {
        boundaries
          ..add(t.startMinute)
          ..add(t.endMinute);
      }
    }
    final Set<String> packages = <String>{
      for (final SmartRule r in old) ...r.targetPackages,
    };
    final Set<String> relaxed = <String>{};
    for (final String pkg in packages) {
      search:
      for (int day = DateTime.monday; day <= DateTime.sunday; day++) {
        for (final int minute in boundaries) {
          final AppSecurityLevel? was = levelAt(old, pkg, day, minute);
          if (was == null) continue;
          final AppSecurityLevel? now = levelAt(next, pkg, day, minute);
          if (now == null || was.isStricterThan(now)) {
            relaxed.add(pkg);
            break search;
          }
        }
      }
    }
    return relaxed;
  }

  /// Packages whose rule level at [localDateTime] is stricter under
  /// [after] than under [before] (their open sessions must not outlive the
  /// change).
  static Set<String> raisedAt(
    Iterable<SmartRule> before,
    Iterable<SmartRule> after,
    DateTime localDateTime,
  ) {
    final Set<String> packages = <String>{
      for (final SmartRule r in _raising(after)) ...r.targetPackages,
    };
    return <String>{
      for (final String pkg in packages)
        if (_stricter(
          ruleLevelFor(after, pkg, localDateTime),
          ruleLevelFor(before, pkg, localDateTime),
        ))
          pkg,
    };
  }

  /// The rules native enforcement needs: enabled rules with a raising
  /// action only (Standard and Unlocked are never sent), in a canonical
  /// order. Each entry: `level`, `days`, `allDay`, `start`, `end`,
  /// `targets`.
  static List<Map<String, Object?>> nativeTransport(Iterable<SmartRule> rules) {
    final List<Map<String, Object?>> out = <Map<String, Object?>>[
      for (final SmartRule r in _raising(rules))
        <String, Object?>{
          'level': r.action.raisesTo!.storageId,
          'days': List<int>.of(r.days),
          'allDay': r.time is SmartRuleAllDay,
          'start': switch (r.time) {
            SmartRuleWindow(:final int startMinute) => startMinute,
            SmartRuleAllDay() => 0,
          },
          'end': switch (r.time) {
            SmartRuleWindow(:final int endMinute) => endMinute,
            SmartRuleAllDay() => 0,
          },
          'targets': List<String>.of(r.targetPackages),
        },
    ];
    out.sort((Map<String, Object?> a, Map<String, Object?> b) =>
        a.toString().compareTo(b.toString()));
    return out;
  }

  static List<SmartRule> _raising(Iterable<SmartRule> rules) => <SmartRule>[
        for (final SmartRule r in rules)
          if (r.enabled && r.action.canRaise) r,
      ];

  static bool _stricter(AppSecurityLevel? a, AppSecurityLevel? b) =>
      a != null && (b == null || a.isStricterThan(b));
}

/// Phase 10 / M2: the Dart engine's in-memory copy of the saved rules,
/// refreshed only from a SUCCESSFUL repository read (`ProtectionBootstrap`).
///
/// A failed, corrupt or unsupported read leaves the last good copy in place
/// (never an empty list). Because every rule can only raise protection, a
/// stale copy can only be stricter than intended, never weaker than the
/// saved baseline. Native enforcement keeps its own persisted copy and is
/// the final gate.
///
/// Phase 10 / M2 (R-A startup safety): the copy is [current] only while the
/// LATEST read succeeded. Before the first successful read (cold start) and
/// after any failed read, the access controller treats every protected app
/// as Critical, because the saved rules (which may be stricter than native's
/// persisted copy after an unconfirmed reduction) are not known.
class SmartRuleEnforcementCache {
  List<SmartRule> _rules = const <SmartRule>[];
  bool _loaded = false;
  bool _readFailed = false;

  /// The cached rules (empty before the first successful read).
  List<SmartRule> get rules => _rules;

  /// Whether at least one read succeeded in this process.
  bool get loaded => _loaded;

  /// Whether the latest read succeeded (false before any read).
  bool get current => _loaded && !_readFailed;

  /// Replaces the copy with a successfully read rule set.
  void update(List<SmartRule> rules) {
    _rules = List<SmartRule>.unmodifiable(rules);
    _loaded = true;
    _readFailed = false;
  }

  /// Records a failed, corrupt or unsupported read. The last good copy is
  /// kept, but [current] is false until the next successful read.
  void markReadFailed() {
    _readFailed = true;
  }

  /// The extra level the cached rules require for [packageName] at [now].
  AppSecurityLevel? levelFor(String packageName, DateTime now) =>
      SmartRulePolicy.ruleLevelFor(_rules, packageName, now);
}
