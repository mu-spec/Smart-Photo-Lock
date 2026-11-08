/// Phase 11 / M2: switching the active profile and managing profiles.
///
/// Every change goes through [applyProfileChange] with the profile set the
/// screen showed ([ProfileChange.expected]) and the set the user asked for
/// ([ProfileChange.requested]). The comparison is made over the ENFORCED
/// result: saved Smart Rules + the active profile's overlay, for every
/// protected app, every weekday and every window boundary.
///
///  * Nothing changes for the active overlay (an inactive profile was
///    created, edited, duplicated or deleted): the document is written with
///    compare-and-swap and native is NOT contacted. No proof is created.
///  * Stronger or equal (nothing relaxed): no confirmation. The document is
///    written first, sessions of apps that become stricter right now are
///    revoked, then the state is sent; "Applied" only on an `applied` ack.
///  * Weaker or mixed (anything relaxed): the CR-2 PIN/pattern gate with
///    [UnprotectIntent.profileChange] for exactly the relaxed apps. Then the
///    bound protocol (`ProtectionBootstrap.applyBoundRelaxation`): storage
///    must still hold [ProfileChange.expected]; native must hold exactly the
///    expected-before state (probe); only then is the requested state sent
///    with the relaxation flag, and the document is committed ONLY after
///    native applied it. Any failure re-sends the stricter state.
///
/// A profile change never unlocks an app, grants a session or grace, clears
/// a challenge, resets lockout, authorizes another package, enrols an app,
/// or changes a saved security level or Smart Rule.
library;

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
import '../../../rules/smart_rule_policy.dart';
import '../../../security/credentials/credential_manager.dart';
import '../../../services/watcher_service.dart';
import '../../../utilities/result.dart';
import '../apps/unprotect_gate.dart';

/// What kind of profile change the user asked for (copy and diagnostics;
/// the security decision is made from the sets, never from this label).
enum ProfileChangeKind {
  /// Make another profile active.
  switchProfile,

  /// Create, duplicate, rename or edit a profile.
  save,

  /// Delete a custom profile.
  delete,
}

/// A requested profile change.
final class ProfileChange {
  const ProfileChange({
    required this.kind,
    required this.expected,
    required this.requested,
  });

  final ProfileChangeKind kind;

  /// The profile set the screen showed (compare-and-swap expectation).
  final SecurityProfileSet expected;

  /// The full profile set after the change.
  final SecurityProfileSet requested;
}

/// The result of [applyProfileChange].
enum ProfileChangeStatus {
  /// Native acknowledged the new state (`applied`). The profile is active.
  enforced,

  /// The document was saved; the active overlay did not change, so native
  /// was not contacted (inactive profile edit / create / delete).
  saved,

  /// Nothing differs from what is stored.
  unchanged,

  /// Saved; native kept stricter earlier protection (`held`).
  savedHeld,

  /// Saved; native did not confirm (failure / unknown). Stricter Dart
  /// floor applies; the next sync retries.
  savedUnconfirmed,

  /// The confirmation was cancelled or failed. Nothing written or sent.
  denied,

  /// The saved profiles (or rules / apps) changed since they were shown.
  /// Nothing written; reload and retry.
  conflict,

  /// The change could not be saved, or storage could not be read. Nothing
  /// changed (no success is claimed).
  failed,

  /// The new state is not valid (limits, names). Nothing written.
  invalid,

  /// A lowering change was refused because native still holds other,
  /// stricter protection. The profile was not changed; nothing relaxed.
  blocked,

  /// A lowering change failed after confirmation; the previous, stricter
  /// state was re-sent and acknowledged. The profile was not changed.
  notApplied,

  /// A lowering change failed and the recovery could not be confirmed.
  /// The previous profile is still saved; never claimed as applied.
  unknown,
}

/// The outcome of a profile change.
final class ProfileChangeOutcome {
  const ProfileChangeOutcome(this.status, {this.error, this.denial});

  final ProfileChangeStatus status;
  final Object? error;
  final UnprotectDenial? denial;

  /// Whether the requested set is now the saved one.
  bool get saved => switch (status) {
        ProfileChangeStatus.enforced ||
        ProfileChangeStatus.saved ||
        ProfileChangeStatus.unchanged ||
        ProfileChangeStatus.savedHeld ||
        ProfileChangeStatus.savedUnconfirmed =>
          true,
        _ => false,
      };

  @override
  String toString() => 'ProfileChangeOutcome(${status.name})';
}

/// How a change compares with the current enforced state.
final class ProfileChangeImpact {
  const ProfileChangeImpact({required this.relaxed, required this.raisedNow});

  /// Protected apps that get LESS protection at some weekly minute.
  final Set<String> relaxed;

  /// Apps whose level rises right now (their sessions are revoked).
  final Set<String> raisedNow;

  /// Whether a confirmation is needed.
  bool get lowers => relaxed.isNotEmpty;
}

/// Compares the active overlays of [before] and [after] over the saved
/// [rules] for the protected apps (full weekly schedule).
ProfileChangeImpact profileChangeImpact({
  required List<SmartRule> rules,
  required SecurityProfileSet before,
  required SecurityProfileSet after,
  required Set<String> protectedPackages,
  required DateTime now,
}) {
  final List<SmartRule> was = <SmartRule>[
    ...rules,
    ...SecurityProfilePolicy.overlayRules(before.active, protectedPackages),
  ];
  final List<SmartRule> next = <SmartRule>[
    ...rules,
    ...SecurityProfilePolicy.overlayRules(after.active, protectedPackages),
  ];
  return ProfileChangeImpact(
    relaxed: SmartRulePolicy.relaxedPackages(was, next),
    raisedNow: SmartRulePolicy.raisedAt(was, next, now),
  );
}

/// Whether the ACTIVE overlay compiles identically in [a] and [b] (same
/// native transport). Ids and names are not part of the transport.
bool sameActiveOverlay(
  SecurityProfileSet a,
  SecurityProfileSet b,
  Set<String> protectedPackages,
) {
  final List<Map<String, Object?>> x = SmartRulePolicy.nativeTransport(
    SecurityProfilePolicy.overlayRules(a.active, protectedPackages),
  );
  final List<Map<String, Object?>> y = SmartRulePolicy.nativeTransport(
    SecurityProfilePolicy.overlayRules(b.active, protectedPackages),
  );
  return x.toString() == y.toString();
}

/// Applies [change]; see the library documentation for the contract.
/// [navigator] must be captured by the caller before any await. [clock] is
/// a test seam.
Future<ProfileChangeOutcome> applyProfileChange({
  required ProfileChange change,
  required NavigatorState navigator,
  required SecurityProfileRepository profiles,
  required SmartRuleRepository rules,
  required ProtectedAppsRepository protectedApps,
  required CredentialManager credentials,
  required AccessController accessController,
  required ProtectionBootstrap bootstrap,
  DateTime Function()? clock,
}) async {
  final DateTime Function() now = clock ?? DateTime.now;
  final SecurityProfileSet expected = change.expected;
  final SecurityProfileSet requested = change.requested;

  final Result<SecurityProfileSet> stored = await profiles.getProfiles();
  if (stored.isFailure || stored.valueOrNull == null) {
    return ProfileChangeOutcome(
      ProfileChangeStatus.failed,
      error: stored.errorOrNull,
    );
  }
  if (stored.valueOrNull != expected) {
    return const ProfileChangeOutcome(ProfileChangeStatus.conflict);
  }
  if (requested == expected) {
    return const ProfileChangeOutcome(ProfileChangeStatus.unchanged);
  }
  final Result<List<SmartRule>> ruleRead = await rules.getRules();
  final Result<List<ProtectedApp>> appRead =
      await protectedApps.getProtectedApps();
  final List<SmartRule>? savedRules = ruleRead.valueOrNull;
  final List<ProtectedApp>? apps = appRead.valueOrNull;
  if (savedRules == null || apps == null) {
    // Unknown rules or apps: the comparison cannot be made. Fail closed.
    return ProfileChangeOutcome(
      ProfileChangeStatus.failed,
      error: ruleRead.errorOrNull ?? appRead.errorOrNull,
    );
  }
  final Set<String> protectedPackages =
      apps.map((ProtectedApp a) => a.packageName).toSet();

  Future<Result<void>> commit() =>
      profiles.saveProfiles(requested, expected: expected);

  // Inactive edits: the enforced state is identical. Native is never
  // contacted and no proof is created or consumed.
  if (requested.activeProfileId == expected.activeProfileId &&
      sameActiveOverlay(expected, requested, protectedPackages)) {
    return _written(await commit()) ?? //
        const ProfileChangeOutcome(ProfileChangeStatus.saved);
  }

  final ProfileChangeImpact impact = profileChangeImpact(
    rules: savedRules,
    before: expected,
    after: requested,
    protectedPackages: protectedPackages,
    now: now(),
  );

  if (!impact.lowers) {
    // Stronger or equal: persist, revoke what is stricter now, then send.
    final ProfileChangeOutcome? failed = _written(await commit());
    if (failed != null) return failed;
    for (final String pkg in impact.raisedNow) {
      await accessController.revokeImmediately(pkg);
    }
    final Result<ProtectionBootstrapResult> sync =
        await bootstrap.synchronize();
    return ProfileChangeOutcome(
      switch (sync.valueOrNull?.policyAck.ruleStatus) {
        SmartRuleSyncStatus.applied => ProfileChangeStatus.enforced,
        SmartRuleSyncStatus.held => ProfileChangeStatus.savedHeld,
        _ => ProfileChangeStatus.savedUnconfirmed,
      },
      error: sync.errorOrNull,
    );
  }

  // Weaker or mixed: the app's own PIN/pattern, for exactly these apps.
  final UnprotectRequestResult request = await requestUnprotectAuthorization(
    navigator: navigator,
    credentials: credentials,
    packages: impact.relaxed,
    clock: clock,
    title: profileChangeConfirmTitle,
    intent: UnprotectIntent.profileChange,
  );
  final UnprotectAuthorization? authorization = request.authorization;
  if (authorization == null) {
    return ProfileChangeOutcome(
      ProfileChangeStatus.denied,
      denial: request.denial,
    );
  }
  // A mixed change also makes some apps stricter right now.
  for (final String pkg in impact.raisedNow) {
    await accessController.revokeImmediately(pkg);
  }
  final BoundRelaxationResult bound = await bootstrap.applyBoundRelaxation(
    intent: BoundRelaxationIntent.profileChange,
    authorize: (Set<String> packages) => consumeBoundRelaxation(
      authorization,
      packages,
      BoundRelaxationIntent.profileChange,
      clock: clock,
    ),
    rulesBefore: savedRules,
    rulesAfter: savedRules,
    profilesBefore: expected,
    profilesAfter: requested,
    commit: commit,
  );
  return ProfileChangeOutcome(
    switch (bound.status) {
      BoundRelaxationStatus.applied => ProfileChangeStatus.enforced,
      BoundRelaxationStatus.held => ProfileChangeStatus.savedHeld,
      BoundRelaxationStatus.unconfirmed => ProfileChangeStatus.savedUnconfirmed,
      BoundRelaxationStatus.conflict => ProfileChangeStatus.conflict,
      BoundRelaxationStatus.denied => ProfileChangeStatus.denied,
      BoundRelaxationStatus.unavailable => ProfileChangeStatus.failed,
      BoundRelaxationStatus.blocked => ProfileChangeStatus.blocked,
      BoundRelaxationStatus.notApplied => ProfileChangeStatus.notApplied,
      BoundRelaxationStatus.unknown => ProfileChangeStatus.unknown,
    },
    error: bound.error,
  );
}

/// Null when [written] succeeded; otherwise the failure outcome.
ProfileChangeOutcome? _written(Result<void> written) {
  if (written.isSuccess) return null;
  final Object? error = written.errorOrNull;
  if (error is SecurityProfileStoreException &&
      error.kind == SecurityProfileStoreErrorKind.conflict) {
    return const ProfileChangeOutcome(ProfileChangeStatus.conflict);
  }
  return ProfileChangeOutcome(ProfileChangeStatus.failed, error: error);
}

/// Builds the requested set for a switch to [id]; null when [id] is
/// unknown (stale screen).
SecurityProfileSet? switchedTo(SecurityProfileSet current, String id) {
  if (current.byId(id) == null) return null;
  return current.withActive(id);
}
