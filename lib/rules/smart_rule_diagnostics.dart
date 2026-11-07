/// Phase 10 / M3 (PRD 10K): explainable, READ-ONLY Smart Rule diagnostics.
///
/// Answers, for one app at one local moment: which rules match and which do
/// not (and why), which matching rule decides the level after conflict
/// resolution (and which tie or are outranked), the saved level, the
/// CALCULATED effective level, and separately whether native protection
/// CONFIRMED the saved rules and whether the Dart engine currently uses
/// them.
///
/// Pure Dart: no I/O, no clock read, no writes, no native call, no
/// authorization, no challenge, ticket, session or grace access. The level
/// comes from the same functions enforcement uses
/// ([SmartRulePolicy.resolutionFor], [SmartRulePolicy.effectiveLevel]), so
/// a diagnosis cannot disagree with the Dart decision for the same inputs.
/// A calculated level is never a confirmation: [SmartRuleNativeState] is
/// derived only from a recorded native acknowledgement of the exact rule
/// set ([SmartRuleDiagnostics.nativeStateFor]).
library;

import '../data/models/app_security_level.dart';
import '../services/watcher_service.dart';
import 'smart_rule.dart';
import 'smart_rule_conflict.dart';
import 'smart_rule_evaluator.dart';
import 'smart_rule_policy.dart';

/// What one rule contributes for the diagnosed app right now. Declaration
/// order is the display order.
enum SmartRuleRole {
  /// Matches and decides the effective level (first sorted id among the
  /// strongest raising rules).
  decides,

  /// Matches and asks for the same level as the deciding rule.
  tied,

  /// Matches and raises, but a stricter matching rule decides.
  outranked,

  /// Matches and raises, but the saved level is already at least as strict.
  coveredBySaved,

  /// Matches, but its action adds no protection (Standard, or the reserved
  /// Unlocked).
  addsNothing,

  /// Matches, but the app is not protected, so no rule has an effect.
  appNotProtected,

  /// Does not match now; see [SmartRuleDiagnosticEntry.reason].
  notApplying,
}

/// What decided the calculated level.
enum SmartRuleDecision { savedLevel, rule, notProtected }

/// Whether the Dart engine currently uses the saved rules.
enum SmartRuleEngineState {
  /// The latest read succeeded and matches the saved rules.
  inUse,

  /// No rule read has succeeded yet in this process (startup).
  notLoaded,

  /// The latest rule read failed (corrupt, unsupported or unreadable).
  readFailed,

  /// The engine's copy differs from the saved rules (a save whose sync has
  /// not completed yet).
  behindSaved,
}

/// Native confirmation of the SAVED rules (never inferred from a
/// calculation).
enum SmartRuleNativeState {
  /// The latest native exchange applied exactly these rules.
  confirmed,

  /// The latest native exchange sent these rules, and native keeps earlier,
  /// stricter rule settings as well (an unconfirmed reduction).
  heldStricter,

  /// The latest exchange failed, sent no rules, was rejected, did not
  /// report, or was about a different rule set.
  notConfirmed,

  /// No native exchange about rules in this process yet.
  notReported,
}

/// One rule's diagnosis for one app. Condition flags are null when they
/// were not evaluated (invalid input, or [dayMatch] outside the window).
final class SmartRuleDiagnosticEntry {
  const SmartRuleDiagnosticEntry({
    required this.ruleId,
    required this.name,
    required this.enabled,
    required this.requested,
    required this.reason,
    required this.role,
    required this.evaluation,
  });

  final String ruleId;
  final String name;
  final bool enabled;

  /// The action the rule asks for.
  final SmartRuleAction requested;

  /// The evaluator's reason (first failing check, or `matched`).
  final SmartRuleReason reason;
  final SmartRuleRole role;

  /// The full evaluator record (weekday, minute, segment, owner day).
  final SmartRuleEvaluation evaluation;

  bool? get appMatch => evaluation.appTargeted;
  bool? get timeMatch => evaluation.inTimeWindow;
  bool? get dayMatch => evaluation.daySelected;
  bool get matches => evaluation.isMatch;

  /// Whether the rule sets the calculated level (alone or tied).
  bool get contributed =>
      role == SmartRuleRole.decides || role == SmartRuleRole.tied;

  @override
  String toString() => 'SmartRuleDiagnosticEntry($ruleId, ${role.name}, '
      '${reason.name}, ${requested.storageId})';
}

/// The diagnosis of one app at one moment.
final class SmartRuleAppDiagnosis {
  const SmartRuleAppDiagnosis({
    required this.packageName,
    required this.savedLevel,
    required this.at,
    required this.entries,
    required this.resolution,
    required this.calculatedLevel,
    required this.decidedBy,
    required this.engineState,
    required this.nativeState,
  });

  final String packageName;

  /// The app's saved (baseline) level; null = not protected.
  final AppSecurityLevel? savedLevel;

  /// The local instant diagnosed.
  final DateTime at;

  /// Every rule, in display order ([SmartRuleRole] order, then rule id).
  final List<SmartRuleDiagnosticEntry> entries;

  /// The conflict resolution enforcement uses for these inputs.
  final SmartRuleResolution resolution;

  /// stricter(saved, rule level); null when the app is not protected.
  /// CALCULATED from the saved rules, not a native confirmation.
  final AppSecurityLevel? calculatedLevel;
  final SmartRuleDecision decidedBy;
  final SmartRuleEngineState engineState;
  final SmartRuleNativeState nativeState;

  /// The rule that decides [calculatedLevel] (null unless [decidedBy] is
  /// [SmartRuleDecision.rule]).
  String? get decidingRuleId =>
      decidedBy == SmartRuleDecision.rule ? resolution.decidingRuleId : null;

  /// Rules tied with [decidingRuleId], sorted.
  List<String> get tiedRuleIds => decidedBy == SmartRuleDecision.rule
      ? resolution.tiedRuleIds
      : const <String>[];

  /// Whether Dart access decisions use Critical for this app right now
  /// because the rules are not currently known (Phase 10 / M2 R-A floor).
  bool get criticalFloorActive =>
      savedLevel != null &&
      (engineState == SmartRuleEngineState.notLoaded ||
          engineState == SmartRuleEngineState.readFailed);

  SmartRuleDiagnosticEntry? entryFor(String ruleId) {
    for (final SmartRuleDiagnosticEntry e in entries) {
      if (e.ruleId == ruleId) return e;
    }
    return null;
  }

  @override
  String toString() => 'SmartRuleAppDiagnosis($packageName, '
      'saved=${savedLevel?.storageId}, '
      'calculated=${calculatedLevel?.storageId}, ${decidedBy.name}, '
      'deciding=$decidingRuleId, tied=$tiedRuleIds, '
      'engine=${engineState.name}, native=${nativeState.name})';
}

abstract final class SmartRuleDiagnostics {
  static const SmartRuleEvaluator _evaluator = SmartRuleEvaluator();

  /// Diagnoses [packageName] at the local instant [at]. [savedLevel] null =
  /// the app is not protected. Pure: the same inputs give the same result.
  static SmartRuleAppDiagnosis diagnose({
    required Iterable<SmartRule> rules,
    required String packageName,
    required AppSecurityLevel? savedLevel,
    required DateTime at,
    SmartRuleEngineState engineState = SmartRuleEngineState.inUse,
    SmartRuleNativeState nativeState = SmartRuleNativeState.notReported,
  }) {
    final List<SmartRule> all = List<SmartRule>.of(rules);
    final SmartRuleResolution resolution =
        SmartRulePolicy.resolutionFor(all, packageName, at);
    final AppSecurityLevel? ruleLevel = resolution.ruleLevel;
    final SmartRuleDecision decidedBy;
    final AppSecurityLevel? calculated;
    if (savedLevel == null) {
      decidedBy = SmartRuleDecision.notProtected;
      calculated = null;
    } else {
      calculated = SmartRulePolicy.effectiveLevel(savedLevel, ruleLevel);
      decidedBy = ruleLevel != null && ruleLevel.isStricterThan(savedLevel)
          ? SmartRuleDecision.rule
          : SmartRuleDecision.savedLevel;
    }
    final String? deciding =
        decidedBy == SmartRuleDecision.rule ? resolution.decidingRuleId : null;

    final List<SmartRuleDiagnosticEntry> entries = <SmartRuleDiagnosticEntry>[
      for (final SmartRule rule in all)
        _entry(
          rule,
          _evaluator.evaluate(rule, packageName, at),
          savedLevel: savedLevel,
          ruleLevel: ruleLevel,
          decidingRuleId: deciding,
        ),
    ]..sort((SmartRuleDiagnosticEntry a, SmartRuleDiagnosticEntry b) {
        final int byRole = a.role.index.compareTo(b.role.index);
        return byRole != 0 ? byRole : a.ruleId.compareTo(b.ruleId);
      });

    return SmartRuleAppDiagnosis(
      packageName: packageName,
      savedLevel: savedLevel,
      at: at,
      entries: List<SmartRuleDiagnosticEntry>.unmodifiable(entries),
      resolution: resolution,
      calculatedLevel: calculated,
      decidedBy: decidedBy,
      engineState: engineState,
      nativeState: nativeState,
    );
  }

  static SmartRuleDiagnosticEntry _entry(
    SmartRule rule,
    SmartRuleEvaluation evaluation, {
    required AppSecurityLevel? savedLevel,
    required AppSecurityLevel? ruleLevel,
    required String? decidingRuleId,
  }) {
    final AppSecurityLevel? raises = rule.action.raisesTo;
    final SmartRuleRole role;
    if (!evaluation.isMatch) {
      role = SmartRuleRole.notApplying;
    } else if (savedLevel == null) {
      role = SmartRuleRole.appNotProtected;
    } else if (raises == null) {
      role = SmartRuleRole.addsNothing;
    } else if (!raises.isStricterThan(savedLevel)) {
      role = SmartRuleRole.coveredBySaved;
    } else if (ruleLevel != null && ruleLevel.isStricterThan(raises)) {
      role = SmartRuleRole.outranked;
    } else if (rule.id == decidingRuleId) {
      role = SmartRuleRole.decides;
    } else {
      role = SmartRuleRole.tied;
    }
    return SmartRuleDiagnosticEntry(
      ruleId: rule.id,
      name: rule.name,
      enabled: rule.enabled,
      requested: rule.action,
      reason: evaluation.reason,
      role: role,
      evaluation: evaluation,
    );
  }

  /// Native confirmation of [savedRules] from the latest recorded exchange.
  /// Confirmed or held ONLY when that exchange succeeded and sent exactly
  /// the transport of [savedRules]; anything else is not a confirmation.
  static SmartRuleNativeState nativeStateFor(
    Iterable<SmartRule> savedRules,
    SmartRuleNativeRecord? record,
  ) {
    if (record == null) return SmartRuleNativeState.notReported;
    final List<Map<String, Object?>>? sent = record.sentRules;
    if (record.failed || sent == null) return SmartRuleNativeState.notConfirmed;
    if (!sameTransport(SmartRulePolicy.nativeTransport(savedRules), sent)) {
      return SmartRuleNativeState.notConfirmed;
    }
    return switch (record.status) {
      SmartRuleSyncStatus.applied => SmartRuleNativeState.confirmed,
      SmartRuleSyncStatus.held => SmartRuleNativeState.heldStricter,
      SmartRuleSyncStatus.kept ||
      SmartRuleSyncStatus.invalid ||
      SmartRuleSyncStatus.unknown =>
        SmartRuleNativeState.notConfirmed,
    };
  }

  /// Whether the Dart engine's [cache] currently uses [savedRules].
  static SmartRuleEngineState engineStateFor(
    SmartRuleEnforcementCache cache,
    Iterable<SmartRule> savedRules,
  ) {
    if (!cache.loaded) return SmartRuleEngineState.notLoaded;
    if (!cache.current) return SmartRuleEngineState.readFailed;
    if (!sameTransport(
      SmartRulePolicy.nativeTransport(cache.rules),
      SmartRulePolicy.nativeTransport(savedRules),
    )) {
      return SmartRuleEngineState.behindSaved;
    }
    return SmartRuleEngineState.inUse;
  }

  /// Engine state when the saved rules themselves could not be read.
  static SmartRuleEngineState engineStateWithoutSaved(
    SmartRuleEnforcementCache cache,
  ) {
    if (!cache.loaded) return SmartRuleEngineState.notLoaded;
    if (!cache.current) return SmartRuleEngineState.readFailed;
    return SmartRuleEngineState.inUse;
  }

  /// Order-sensitive comparison of two canonical transports
  /// ([SmartRulePolicy.nativeTransport] sorts its output).
  static bool sameTransport(
    List<Map<String, Object?>> a,
    List<Map<String, Object?>> b,
  ) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].toString() != b[i].toString()) return false;
    }
    return true;
  }
}
