/// Phase 11 / M2: user-facing text and status for Security Profiles.
library;

import '../../../data/models/app_security_level.dart';
import '../../../data/repositories/security_profile_repository.dart';
import '../../../profiles/security_profile.dart';
import '../../../profiles/security_profile_policy.dart';
import '../../../rules/smart_rule.dart';
import '../../../rules/smart_rule_policy.dart';
import '../../../services/watcher_service.dart';
import '../apps/unprotect_gate.dart';
import 'profile_change.dart';

/// What native last confirmed about the ACTIVE profile.
enum ProfileNativeStatus {
  /// Native applied a transport containing exactly the saved active
  /// profile's overlay (`applied` ack).
  applied,

  /// Native kept stricter, earlier protection (`held`). The active
  /// profile's protection is in force, plus more.
  held,

  /// Saved, but native did not confirm it (failure, unknown, or the last
  /// state sent is not the saved one).
  unconfirmed,

  /// The saved profiles could not be read. The strict fallback applies.
  unavailable,

  /// Nothing was sent yet in this session.
  notChecked,
}

/// Derives [ProfileNativeStatus] from the saved set and the last exchange.
/// "Applied" is never derived from Dart state alone.
///
/// Phase 11 / M3: with [rules], the overlays of "Apply profile" rules last
/// sent must also equal what [saved] and [rules] compile to now (an edit of
/// a referenced profile is "Applied" only once THAT snapshot was applied).
ProfileNativeStatus profileNativeStatus({
  required SecurityProfileSet? saved,
  required SmartRuleNativeRecord? record,
  required Set<String> protectedPackages,
  List<SmartRule>? rules,
}) {
  if (saved == null) return ProfileNativeStatus.unavailable;
  if (record == null) return ProfileNativeStatus.notChecked;
  final List<Map<String, Object?>> expected = SmartRulePolicy.nativeTransport(
    SecurityProfilePolicy.overlayRules(saved.active, protectedPackages),
  );
  final List<Map<String, Object?>>? sent = record.sentProfileOverlay;
  if (record.failed || sent == null || sent.toString() != expected.toString()) {
    return ProfileNativeStatus.unconfirmed;
  }
  if (rules != null) {
    final List<Map<String, Object?>> expectedActivation =
        SmartRulePolicy.nativeTransport(
      SecurityProfilePolicy.activationRules(rules, saved, protectedPackages),
    );
    final List<Map<String, Object?>> sentActivation =
        record.sentActivationOverlay ?? const <Map<String, Object?>>[];
    if (sentActivation.toString() != expectedActivation.toString()) {
      return ProfileNativeStatus.unconfirmed;
    }
  }
  return switch (record.status) {
    SmartRuleSyncStatus.applied => ProfileNativeStatus.applied,
    SmartRuleSyncStatus.held => ProfileNativeStatus.held,
    _ => ProfileNativeStatus.unconfirmed,
  };
}

/// Copy for the profile UI.
abstract final class ProfileText {
  static const String heading = 'Security profile';
  static const String manageTitle = 'Security profiles';
  static const String intro =
      'A profile adds extra protection on top of your saved app levels and '
      'Smart Rules. It never removes protection.';
  static const String change = 'Change profile';

  /// Phase 11 / M3: delete refused while a Smart Rule references the profile.
  static const String inUse =
      'A Smart Rule uses this profile. Edit or delete that rule first. '
      'Nothing was changed.';

  /// Phase 11 / M3: editing a profile that scheduled rules apply.
  static String usedByRules(int count) => count == 1
      ? 'Used by 1 Smart Rule. Changes apply whenever that rule applies; '
          'lowering protection needs your PIN or pattern.'
      : 'Used by $count Smart Rules. Changes apply whenever those rules '
          'apply; lowering protection needs your PIN or pattern.';
  static const String create = 'New profile';
  static const String loading = 'Loading profiles';
  static const String retry = 'Retry';
  static const String active = 'Active';
  static const String preset = 'Preset';
  static const String custom = 'Custom';
  static const String edit = 'Edit';
  static const String duplicate = 'Duplicate';
  static const String delete = 'Delete';
  static const String makeActive = 'Use this profile';
  static const String loadFailed =
      'Profiles could not be loaded. Every protected app stays at Critical '
      'until they can be read.';
  static const String corrupt =
      'Saved profiles are damaged and cannot be used. Every protected app '
      'stays at Critical. Nothing was overwritten.';
  static const String unsupported =
      'Saved profiles come from a newer version of the app and cannot be '
      'changed here. Every protected app stays at Critical.';
  static const String limitReached =
      'You have the maximum of ${SecurityProfileSet.maxCustomProfiles} '
      'custom profiles.';
  static const String noProtectedApps =
      'Protect apps first. A profile can only add protection to apps that '
      'are already protected.';

  // Editor.
  static const String editorNewTitle = 'New profile';
  static const String editorEditTitle = 'Edit profile';
  static const String nameLabel = 'Name';
  static const String allLabel = 'All protected apps';
  static const String appsLabel = 'Extra protection per app';
  static const String noExtra = 'No extra';
  static const String save = 'Save';
  static const String discardTitle = 'Discard changes?';
  static const String discardBody =
      'Your changes to this profile are not saved.';
  static const String discard = 'Discard changes';
  static const String keepEditing = 'Keep editing';
  static const String nameTaken = 'Another profile already has this name.';
  static const String deleteTitle = 'Delete profile?';
  static const String deleteActiveBody =
      'This profile is active. Deleting it switches to Normal.';
  static const String deleteBody = 'This profile will be removed.';
  static const String cancel = 'Cancel';
  static const String suggestionNote =
      'Tip: you may also want to protect Settings, Play Store or payment '
      'apps. Profiles never add apps to protection for you.';

  static String levelName(AppSecurityLevel? level) => switch (level) {
        AppSecurityLevel.critical => 'Critical',
        AppSecurityLevel.sensitive => 'Sensitive',
        AppSecurityLevel.standard => 'Standard',
        null => noExtra,
      };

  /// What the profile is for.
  static String explanation(SecurityProfile p) => switch (p.kind) {
        SecurityProfileKind.normal =>
          'Your saved protection only. No extra protection.',
        SecurityProfileKind.home => 'Extra protection you choose for home.',
        SecurityProfileKind.work =>
          'Extra protection you choose for work. In this app only; not an '
              'Android work profile.',
        SecurityProfileKind.guest =>
          'For handing your phone to someone: every protected app needs '
              'Critical unlock.',
        SecurityProfileKind.kids => 'Extra protection for the apps you choose.',
        null => 'Your own profile.',
      };

  /// What extra protection it adds.
  static String summary(SecurityProfile p) {
    final AppSecurityLevel? all = p.allProtectedLevel;
    final int apps = p.appLevels.length;
    if (all == null && apps == 0) return 'No extra protection';
    final List<String> parts = <String>[
      if (all != null) 'All protected apps: ${levelName(all)}',
      if (apps > 0) '$apps app${apps == 1 ? '' : 's'} raised',
    ];
    return parts.join(' · ');
  }

  static String nativeStatus(ProfileNativeStatus s) => switch (s) {
        ProfileNativeStatus.applied => 'Applied',
        ProfileNativeStatus.held =>
          'Applied, with stricter earlier protection still in force',
        ProfileNativeStatus.unconfirmed => 'Saved, not confirmed yet',
        ProfileNativeStatus.unavailable => 'Unavailable',
        ProfileNativeStatus.notChecked => 'Not checked yet',
      };

  static String loadError(Object? error) {
    final SecurityProfileStoreErrorKind? kind =
        error is SecurityProfileStoreException ? error.kind : null;
    return switch (kind) {
      SecurityProfileStoreErrorKind.corrupt => corrupt,
      SecurityProfileStoreErrorKind.unsupportedVersion => unsupported,
      _ => loadFailed,
    };
  }

  static String denied(UnprotectDenial? denial) => switch (denial) {
        UnprotectDenial.noAppCredential =>
          'Set up a PIN or pattern to lower profile protection.',
        UnprotectDenial.credentialUnavailable =>
          'Your PIN or pattern could not be checked. Nothing was changed.',
        _ => 'Not confirmed. Nothing was changed.',
      };

  /// Feedback after a change. [name] is the affected profile's name.
  static String outcome(ProfileChangeOutcome o, {required String name}) =>
      switch (o.status) {
        ProfileChangeStatus.enforced => '$name is active.',
        ProfileChangeStatus.saved => 'Saved.',
        ProfileChangeStatus.unchanged => 'No changes to save.',
        ProfileChangeStatus.savedHeld =>
          'Saved. Stricter earlier protection is still in force.',
        ProfileChangeStatus.savedUnconfirmed =>
          'Saved, but protection has not confirmed it yet. Stricter '
              'protection stays until it does.',
        ProfileChangeStatus.denied => denied(o.denial),
        ProfileChangeStatus.conflict =>
          'Profiles changed since this screen was opened. Nothing was '
              'saved. Reload and try again.',
        ProfileChangeStatus.failed =>
          "Couldn't save the profile change. Nothing was changed.",
        ProfileChangeStatus.invalid => 'Check the profile and try again.',
        ProfileChangeStatus.inUse => inUse,
        ProfileChangeStatus.blocked =>
          "Couldn't lower protection now: stricter earlier protection is "
              'still in force. Your profile was not changed.',
        ProfileChangeStatus.notApplied =>
          "Couldn't apply the change. Your previous profile is still active.",
        ProfileChangeStatus.unknown =>
          "Couldn't confirm the change. Your previous profile is still saved "
              'and will be applied again.',
      };
}
