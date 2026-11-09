/// Phase 10 / M3 (PRD 10J): the ONE conflict-resolution policy for Smart
/// Rules that match the same app at the same moment.
///
/// Pure Dart, no I/O, no clock read. Every Dart enforcement path
/// (`SmartRulePolicy.ruleLevelFor`, `SmartRulePolicy.levelAt`, the CR-2
/// relaxation check built on `levelAt`) and the read-only diagnostics go
/// through [SmartRuleConflictPolicy.resolve]. Native `SmartRulePolicy.kt`
/// implements the same precedence over the rules it receives (only raising
/// rules are sent); shared test vectors check both (`docs/architecture.md`,
/// Phase 10 / M3).
///
/// Locked priority: Critical > Sensitive > Standard > Unlocked.
///  * The strongest matching action wins. Rule list order never changes the
///    outcome (no first-match or last-match semantics).
///  * Only Critical and Sensitive can RAISE a level. Standard adds nothing
///    (every protected app is at least Standard) and Unlocked is reserved
///    and never operational, so neither can weaken a stronger rule or the
///    saved level.
///  * Equal strongest actions tie. The tie changes nothing about the level;
///    for diagnostics the tied rule ids are sorted (ordinal string order) and
///    the first one is reported as the deciding rule.
///  * The saved (baseline) level is applied afterwards by
///    `SmartRulePolicy.effectiveLevel`: effective = stricter(saved, rule).
library;

import '../data/models/app_security_level.dart';
import 'smart_rule.dart';

/// The result of resolving the rules that match one app at one moment.
final class SmartRuleResolution {
  const SmartRuleResolution._({
    required this.strongestAction,
    required this.strongestRuleIds,
    required this.matchingRuleIds,
  });

  /// No matching rule.
  static const SmartRuleResolution none = SmartRuleResolution._(
    strongestAction: null,
    strongestRuleIds: <String>[],
    matchingRuleIds: <String>[],
  );

  /// The highest-priority action among the matching rules (null when no
  /// rule matches).
  final SmartRuleAction? strongestAction;

  /// Ids of the matching rules with [strongestAction], sorted.
  final List<String> strongestRuleIds;

  /// Ids of every matching rule, sorted.
  final List<String> matchingRuleIds;

  /// The level the rules raise the app to, or null when the strongest
  /// matching action cannot raise anything (Standard, Unlocked) or nothing
  /// matches.
  AppSecurityLevel? get ruleLevel => strongestAction?.raisesTo;

  /// The deciding rule among the matching ones: the first sorted id of the
  /// strongest raising rules, or null when no matching rule raises.
  String? get decidingRuleId =>
      ruleLevel == null ? null : strongestRuleIds.first;

  /// Other rules that requested the same strongest raising level.
  List<String> get tiedRuleIds => ruleLevel == null
      ? const <String>[]
      : List<String>.unmodifiable(strongestRuleIds.skip(1));

  @override
  String toString() => 'SmartRuleResolution(${strongestAction?.storageId}, '
      'strongest=$strongestRuleIds, matching=$matchingRuleIds)';
}

abstract final class SmartRuleConflictPolicy {
  /// The locked priority, strongest first (PRD 10J).
  static const List<SmartRuleAction> priority = <SmartRuleAction>[
    SmartRuleAction.critical,
    SmartRuleAction.sensitive,
    SmartRuleAction.standard,
    SmartRuleAction.unlocked,
  ];

  /// Higher = stronger. Critical 3, Sensitive 2, Standard 1, Unlocked 0.
  static int rank(SmartRuleAction action) => switch (action) {
        SmartRuleAction.critical => 3,
        SmartRuleAction.sensitive => 2,
        SmartRuleAction.standard => 1,
        SmartRuleAction.unlocked => 0,
        // Phase 11 / M3: never matches an app directly (no targets); its
        // profile is compiled into ordinary raising rules instead.
        SmartRuleAction.applyProfile => -1,
      };

  /// Resolves the rules for which [matches] holds (the caller's evaluator
  /// decides enabled + app + time + day). Independent of the order of
  /// [rules].
  static SmartRuleResolution resolve(
    Iterable<SmartRule> rules,
    bool Function(SmartRule rule) matches,
  ) {
    SmartRuleAction? strongest;
    final List<String> strongestIds = <String>[];
    final List<String> matchingIds = <String>[];
    for (final SmartRule rule in rules) {
      if (!matches(rule)) continue;
      matchingIds.add(rule.id);
      final SmartRuleAction action = rule.action;
      if (strongest == null || rank(action) > rank(strongest)) {
        strongest = action;
        strongestIds
          ..clear()
          ..add(rule.id);
      } else if (rank(action) == rank(strongest)) {
        strongestIds.add(rule.id);
      }
    }
    if (strongest == null) return SmartRuleResolution.none;
    strongestIds.sort();
    matchingIds.sort();
    return SmartRuleResolution._(
      strongestAction: strongest,
      strongestRuleIds: List<String>.unmodifiable(strongestIds),
      matchingRuleIds: List<String>.unmodifiable(matchingIds),
    );
  }
}
