import 'package:flutter/widgets.dart';

import '../../../data/models/protected_app.dart';
import '../../../data/repositories/protected_apps_repository.dart';
import '../../../data/repositories/security_profile_repository.dart';
import '../../../data/repositories/smart_rule_repository.dart';
import '../../../profiles/security_profile.dart';
import '../../../profiles/security_profile_policy.dart';
import '../../../protection/access_controller.dart';
import '../../../protection/bound_relaxation.dart';
import '../../../protection/protection_bootstrap.dart';
import '../../../rules/smart_rule.dart';
import '../../../rules/smart_rule_document.dart';
import '../../../security/credentials/credential_manager.dart';
import '../../../services/watcher_service.dart';
import '../../../utilities/result.dart';
import '../apps/unprotect_gate.dart';

/// Phase 10 / M2 (PRD 10G–10I): the one path through which the Smart Rules
/// UI changes a rule (create, edit, enable/disable, delete).
///
///  1. Reads the CURRENT stored rules (never the screen's copy) and refuses
///     a stale form: the stored rule must still equal the one the screen
///     showed (`conflict`, nothing written).
///  2. If the change REDUCES rule protection for any app
///     ([SmartRulePolicy.relaxedPackages]), the CR-2 app-credential gate is
///     required first; cancel or failure changes nothing.
///  3. Writes with compare-and-swap ([SmartRuleRepository]); a failed write
///     is reported as such, never as saved.
///  4. Ends any open session or grace of an app the change makes stricter
///     right now, then sends ONE snapshot to native (with the relaxation
///     flag only after step 2 succeeded).
///  5. Reports [SmartRuleChangeStatus.enforced] ONLY when native
///     acknowledged THIS snapshot's rules as applied (a durable ack: the
///     channel reports `persisted=false` as a failure).
///  6. Phase 10 / M2 native persistence gate (Option A): when a
///     PIN-confirmed REDUCTION is not acknowledged as applied, the native
///     store may still hold the weaker rules on disk even though it
///     reported a failure. The previous rules are restored in app storage
///     (whole-list compare-and-swap) and re-sent without the relaxation
///     flag, so every later sync (including after a restart) sends the
///     stricter rules. The reduction is never reported as saved
///     ([SmartRuleChangeStatus.reductionRolledBack]); a restore that could
///     not be stored is reported as such
///     ([SmartRuleChangeStatus.reductionRollbackFailed]).
///
/// Never grants a session, extends grace, clears a challenge or resets
/// lockout. Raising rule protection needs no confirmation.
///
/// Phase 11 / M3: steps 2 and 4 compare the COMBINED policy (rules + manual
/// profile overlay + overlays activated by "Apply profile" rules) for the
/// protected apps over the whole week, so disabling, deleting or narrowing
/// a profile-activation rule needs the PIN like any other reduction. The
/// profile set is read here and bound to the operation (a concurrent
/// profile change is a conflict), so a rule proof never carries a profile
/// reduction. A profile rule that references a profile which no longer
/// exists is refused (stale form).
sealed class SmartRuleChange {
  const SmartRuleChange();

  /// The rule the change is about (the new version for saves).
  SmartRule get rule;
}

/// Creates [rule]; fails with a conflict when its id already exists.
final class SmartRuleCreate extends SmartRuleChange {
  const SmartRuleCreate(this.rule);

  @override
  final SmartRule rule;
}

/// Replaces [expected] (the version the form was opened with) by [rule].
final class SmartRuleEdit extends SmartRuleChange {
  const SmartRuleEdit({required this.expected, required this.rule});

  final SmartRule expected;

  @override
  final SmartRule rule;
}

/// Turns [rule] (as shown) on or off.
final class SmartRuleToggle extends SmartRuleChange {
  const SmartRuleToggle({required this.rule, required this.enabled});

  @override
  final SmartRule rule;
  final bool enabled;
}

/// Deletes [rule] (as shown).
final class SmartRuleDelete extends SmartRuleChange {
  const SmartRuleDelete(this.rule);

  @override
  final SmartRule rule;
}

enum SmartRuleChangeStatus {
  /// Saved and native confirmed it enforces the new rules.
  enforced,

  /// Saved; the stored rules already matched (nothing to write).
  unchanged,

  /// Saved; native still enforces the previous, stricter rule coverage
  /// (the change reduced protection and native held it).
  savedHeld,

  /// Saved; native did not confirm the change (yet). Nothing stronger than
  /// the saved levels is claimed.
  savedUnconfirmed,

  /// The CR-2 confirmation was cancelled or failed: nothing changed.
  denied,

  /// The rule changed since the screen showed it: nothing changed.
  conflict,

  /// Reading or writing failed: nothing changed.
  failed,

  /// Phase 10 / M2: a PIN-confirmed reduction was stored but native did not
  /// durably acknowledge it, so the previous rules were restored in app
  /// storage and re-sent. The reduction is NOT saved; retry is possible.
  reductionRolledBack,

  /// Phase 10 / M2: as [reductionRolledBack], but restoring the previous
  /// rules in app storage failed (or they changed meanwhile). The stored
  /// rules may be the reduced ones; nothing is claimed as restored.
  reductionRollbackFailed,

  /// Phase 10 / M2: [confirmHeldRuleRelaxation] was not acknowledged and
  /// the follow-up re-sync could not confirm which rules native keeps.
  /// Neither the current nor the earlier rules are claimed to apply.
  relaxationUnconfirmed,
}

class SmartRuleChangeOutcome {
  const SmartRuleChangeOutcome(
    this.status, {
    this.denial,
    this.error,
    this.restoreAcknowledged = false,
  });

  final SmartRuleChangeStatus status;

  /// Why the CR-2 confirmation did not authorize ([SmartRuleChangeStatus.denied]).
  final UnprotectDenial? denial;

  /// The storage error ([SmartRuleChangeStatus.failed]).
  final Object? error;

  /// [SmartRuleChangeStatus.reductionRolledBack] only: native acknowledged
  /// the restored (previous) rules as applied. Diagnostic; the UI wording
  /// is the same either way ("will be restored").
  final bool restoreAcknowledged;

  /// Whether the change is durably stored.
  bool get saved => switch (status) {
        SmartRuleChangeStatus.enforced ||
        SmartRuleChangeStatus.unchanged ||
        SmartRuleChangeStatus.savedHeld ||
        SmartRuleChangeStatus.savedUnconfirmed =>
          true,
        _ => false,
      };
}

/// Applies [change]; see [SmartRuleChange] for the contract. [navigator]
/// must be captured by the caller before any await. [clock] is a test seam.
Future<SmartRuleChangeOutcome> applySmartRuleChange({
  required SmartRuleChange change,
  required NavigatorState navigator,
  required SmartRuleRepository repository,
  required SecurityProfileRepository profiles,
  required ProtectedAppsRepository protectedApps,
  required CredentialManager credentials,
  required AccessController accessController,
  required ProtectionBootstrap bootstrap,
  DateTime Function()? clock,
}) async {
  final DateTime Function() now = clock ?? DateTime.now;
  final Result<List<SmartRule>> read = await repository.getRules();
  final List<SmartRule>? before = read.valueOrNull;
  if (read.isFailure || before == null) {
    return SmartRuleChangeOutcome(
      SmartRuleChangeStatus.failed,
      error: read.errorOrNull,
    );
  }
  final List<SmartRule>? after = _apply(before, change);
  if (after == null) {
    return const SmartRuleChangeOutcome(SmartRuleChangeStatus.conflict);
  }
  if (_sameRules(before, after)) {
    return const SmartRuleChangeOutcome(SmartRuleChangeStatus.unchanged);
  }
  if (SmartRuleDocument.limitProblem(after) != null) {
    return const SmartRuleChangeOutcome(SmartRuleChangeStatus.failed);
  }
  // Phase 11 / M3: the combined comparison needs the profiles and the
  // protected apps. Unknown → fail closed (nothing written or sent).
  final Result<SecurityProfileSet> profileRead = await profiles.getProfiles();
  final Result<List<ProtectedApp>> appRead =
      await protectedApps.getProtectedApps();
  final SecurityProfileSet? profileSet = profileRead.valueOrNull;
  final List<ProtectedApp>? apps = appRead.valueOrNull;
  if (profileSet == null || apps == null) {
    return SmartRuleChangeOutcome(
      SmartRuleChangeStatus.failed,
      error: profileRead.errorOrNull ?? appRead.errorOrNull,
    );
  }
  // The chosen profile was deleted since the form opened: an ENABLED rule
  // may not be saved (or re-enabled) pointing at it. Disabling or deleting
  // such a rule stays possible (a CR-2 reduction: it compiles to Critical).
  final String changedId = change.rule.id;
  for (final SmartRule r in after) {
    if (r.id == changedId &&
        r.enabled &&
        SecurityProfilePolicy.referencesMissingProfile(r, profileSet)) {
      return const SmartRuleChangeOutcome(SmartRuleChangeStatus.conflict);
    }
  }
  final Set<String> protectedPackages =
      apps.map((ProtectedApp a) => a.packageName).toSet();

  final Set<String> relaxed = SecurityProfilePolicy.combinedRelaxedPackages(
    rulesBefore: before,
    rulesAfter: after,
    profilesBefore: profileSet,
    profilesAfter: profileSet,
    protectedPackages: protectedPackages,
  );
  UnprotectAuthorization? authorization;
  if (relaxed.isNotEmpty) {
    final UnprotectRequestResult request = await requestUnprotectAuthorization(
      navigator: navigator,
      credentials: credentials,
      packages: relaxed,
      clock: clock,
      title: relaxRuleConfirmTitle,
    );
    authorization = request.authorization;
    if (authorization == null) {
      return SmartRuleChangeOutcome(
        SmartRuleChangeStatus.denied,
        denial: request.denial,
      );
    }
  }

  Future<Result<void>> write() => switch (change) {
        SmartRuleCreate(:final SmartRule rule) =>
          repository.saveRule(rule, mustBeNew: true),
        SmartRuleEdit(:final SmartRule expected, :final SmartRule rule) =>
          repository.saveRule(rule, expected: expected),
        SmartRuleToggle(:final SmartRule rule, :final bool enabled) =>
          repository.setRuleEnabled(rule.id, enabled: enabled, expected: rule),
        SmartRuleDelete(:final SmartRule rule) =>
          repository.deleteRule(rule.id, expected: rule),
      };
  final Result<void> written = authorization == null
      ? await write()
      : await relaxSmartRulesWith<void>(
          authorization,
          relaxed,
          write,
          clock: clock,
        );
  if (written.isFailure) {
    final Object? error = written.errorOrNull;
    if (error is SmartRuleStoreException &&
        (error.kind == SmartRuleStoreErrorKind.conflict ||
            error.kind == SmartRuleStoreErrorKind.notFound)) {
      return const SmartRuleChangeOutcome(SmartRuleChangeStatus.conflict);
    }
    return SmartRuleChangeOutcome(SmartRuleChangeStatus.failed, error: error);
  }

  // An older unlock window never outlives a change that makes an app
  // stricter right now (the access controller and native also revoke it
  // on their own when the level rises; this is the immediate path).
  for (final String pkg in SecurityProfilePolicy.combinedRaisedAt(
    rulesBefore: before,
    rulesAfter: after,
    profilesBefore: profileSet,
    profilesAfter: profileSet,
    protectedPackages: protectedPackages,
    localDateTime: now(),
  )) {
    await accessController.revokeImmediately(pkg);
  }
  if (authorization != null) {
    // Phase 11 / M2: the relaxation flag is bound to THIS change. The
    // bootstrap re-reads storage (must hold [after]), probes that native
    // holds exactly [before] (+ the stored profile), consumes this proof's
    // rule-write packages, and only then sends [after] with the flag. A
    // held profile reduction (or anything else) is never released here.
    final UnprotectAuthorization proof = authorization;
    final BoundRelaxationResult bound = await bootstrap.applyBoundRelaxation(
      intent: BoundRelaxationIntent.ruleReduction,
      authorize: (Set<String> packages) => consumeBoundRelaxation(
        proof,
        packages,
        BoundRelaxationIntent.ruleReduction,
        clock: clock,
      ),
      rulesBefore: before,
      rulesAfter: after,
      // Phase 11 / M3: bound to the profile set this decision used.
      profilesBefore: profileSet,
      profilesAfter: profileSet,
      storageHoldsAfter: true,
    );
    if (bound.status != BoundRelaxationStatus.applied) {
      return _rollBackReduction(
        repository: repository,
        bootstrap: bootstrap,
        previous: before,
        attempted: after,
      );
    }
    return const SmartRuleChangeOutcome(SmartRuleChangeStatus.enforced);
  }
  final Result<ProtectionBootstrapResult> sync = await bootstrap.synchronize();
  final SmartRuleSyncStatus? ruleStatus =
      sync.valueOrNull?.policyAck.ruleStatus;
  return SmartRuleChangeOutcome(switch (ruleStatus) {
    SmartRuleSyncStatus.applied => SmartRuleChangeStatus.enforced,
    SmartRuleSyncStatus.held => SmartRuleChangeStatus.savedHeld,
    _ => SmartRuleChangeStatus.savedUnconfirmed,
  });
}

/// Option A: restores [previous] (the rules before a PIN-confirmed
/// reduction) when native did not durably acknowledge [attempted]. Raising
/// back needs no confirmation; the snapshot is sent WITHOUT the relaxation
/// flag. Never grants, extends grace, clears a challenge or resets lockout.
Future<SmartRuleChangeOutcome> _rollBackReduction({
  required SmartRuleRepository repository,
  required ProtectionBootstrap bootstrap,
  required List<SmartRule> previous,
  required List<SmartRule> attempted,
}) async {
  final Result<void> restored =
      await repository.replaceRules(previous, expected: attempted);
  if (restored.isFailure) {
    // Native still enforces at least the previous rules in this process
    // (union on failure); app storage may hold the reduced rules.
    return SmartRuleChangeOutcome(
      SmartRuleChangeStatus.reductionRollbackFailed,
      error: restored.errorOrNull,
    );
  }
  final Result<ProtectionBootstrapResult> resync =
      await bootstrap.synchronize();
  return SmartRuleChangeOutcome(
    SmartRuleChangeStatus.reductionRolledBack,
    restoreAcknowledged:
        resync.valueOrNull?.policyAck.ruleStatus == SmartRuleSyncStatus.applied,
  );
}

/// Phase 10 / M2: after native reported [SmartRuleSyncStatus.held] (it
/// still enforces earlier, stricter rule coverage because a reduction was
/// not confirmed), lets the user confirm the CURRENT saved rules with the
/// CR-2 gate. The proof covers every protected package ([packages]; a rule
/// can only affect protected apps) and is consumed before the snapshot is
/// sent with the relaxation flag. Enforced only on an `applied` ack.
///
/// Durability: a flagged write that is not acknowledged may still have
/// reached native storage. The same saved rules are then re-sent WITHOUT the
/// flag, so native re-persists the stricter rules it still holds in memory
/// (`held` = earlier rules plus current ones) or reports that the current
/// rules are already in force (`applied`). Any other result is
/// [SmartRuleChangeStatus.relaxationUnconfirmed]: neither outcome is claimed.
///
/// Phase 11 / M2: the proof has its own intent
/// ([UnprotectIntent.confirmSaved]) and the flag is sent only through
/// `ProtectionBootstrap.applyBoundRelaxation`, bound to [expectedRules] (the
/// rules on screen) and the stored profile: a change made since the screen
/// loaded yields [SmartRuleChangeStatus.conflict] and nothing is sent.
Future<SmartRuleChangeOutcome> confirmHeldRuleRelaxation({
  required NavigatorState navigator,
  required CredentialManager credentials,
  required ProtectionBootstrap bootstrap,
  required Set<String> packages,
  List<SmartRule>? expectedRules,
  DateTime Function()? clock,
}) async {
  if (packages.isEmpty) {
    return const SmartRuleChangeOutcome(SmartRuleChangeStatus.failed);
  }
  final UnprotectRequestResult request = await requestUnprotectAuthorization(
    navigator: navigator,
    credentials: credentials,
    packages: packages,
    clock: clock,
    title: relaxRuleConfirmTitle,
    intent: UnprotectIntent.confirmSaved,
  );
  final UnprotectAuthorization? authorization = request.authorization;
  if (authorization == null) {
    return SmartRuleChangeOutcome(
      SmartRuleChangeStatus.denied,
      denial: request.denial,
    );
  }
  // Phase 11 / M2: bound to the saved configuration (the displayed rules
  // when given, plus the stored profile) and to its own intent.
  final BoundRelaxationResult bound = await bootstrap.applyBoundRelaxation(
    intent: BoundRelaxationIntent.confirmSaved,
    authorize: (Set<String> scope) => consumeBoundRelaxation(
      authorization,
      scope,
      BoundRelaxationIntent.confirmSaved,
      clock: clock,
    ),
    rulesBefore: expectedRules,
    rulesAfter: expectedRules,
    storageHoldsAfter: true,
  );
  if (bound.status == BoundRelaxationStatus.applied) {
    return const SmartRuleChangeOutcome(SmartRuleChangeStatus.enforced);
  }
  if (bound.status == BoundRelaxationStatus.conflict ||
      bound.status == BoundRelaxationStatus.denied) {
    return const SmartRuleChangeOutcome(SmartRuleChangeStatus.conflict);
  }
  final Result<ProtectionBootstrapResult> resync =
      await bootstrap.synchronize();
  return SmartRuleChangeOutcome(
    switch (resync.valueOrNull?.policyAck.ruleStatus) {
      SmartRuleSyncStatus.applied => SmartRuleChangeStatus.enforced,
      SmartRuleSyncStatus.held => SmartRuleChangeStatus.savedHeld,
      _ => SmartRuleChangeStatus.relaxationUnconfirmed,
    },
  );
}

/// The rule list after [change], or null when the stored rules no longer
/// match what the screen showed (stale form / concurrent change).
List<SmartRule>? _apply(List<SmartRule> before, SmartRuleChange change) {
  final String id = change.rule.id;
  final int index = before.indexWhere((SmartRule r) => r.id == id);
  final SmartRule? current = index < 0 ? null : before[index];
  List<SmartRule> replaced(SmartRule next) =>
      <SmartRule>[...before]..[index] = next;
  switch (change) {
    case SmartRuleCreate(:final SmartRule rule):
      return current != null ? null : <SmartRule>[...before, rule];
    case SmartRuleEdit(:final SmartRule expected, :final SmartRule rule):
      return current != expected ? null : replaced(rule);
    case SmartRuleToggle(:final SmartRule rule, :final bool enabled):
      return current != rule ? null : replaced(rule.copyWith(enabled: enabled));
    case SmartRuleDelete(:final SmartRule rule):
      return current != rule ? null : (<SmartRule>[...before]..removeAt(index));
  }
}

bool _sameRules(List<SmartRule> a, List<SmartRule> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
