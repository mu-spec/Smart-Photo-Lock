import '../../../data/models/app_security_level.dart';
import '../../../rules/smart_rule.dart';
import '../apps/unprotect_gate.dart';
import 'smart_rule_change.dart';

/// Phase 10 / M2: user-facing wording for Smart Rules (one place, so tests
/// and docs reference the same strings). Wording describes configuration
/// and confirmed facts only; nothing here claims a rule is active now.
abstract final class SmartRuleText {
  static const String heading = 'Smart Rules';
  static const String intro =
      'Ask for a stricter security level for selected protected apps on the '
      'days and times you choose. A rule never lowers an app\'s saved level '
      'and never unlocks an app.';
  static const String create = 'Create Smart Rule';
  static const String emptyTitle = 'No Smart Rules yet';
  static const String emptyBody =
      'Create a rule to require Sensitive or Critical protection at set '
      'times, for example for banking apps on weekdays.';
  static const String loading = 'Loading Smart Rules';
  static const String loadFailed = 'Couldn\'t load your Smart Rules.';
  static const String corrupt =
      'Your saved Smart Rules can\'t be read. They are kept unchanged and '
      'can\'t be edited until this is resolved. Your apps keep at least '
      'their saved security levels.';
  static const String unsupported =
      'Your saved Smart Rules were created by a newer version of Smart App '
      'Lock. They are kept unchanged and can\'t be edited here. Your apps '
      'keep at least their saved security levels.';
  static const String retry = 'Retry';
  static const String heldNotice =
      'Some earlier, stricter rule settings still apply because the change '
      'that reduced them was not confirmed.';
  static const String heldConfirm = 'Confirm with PIN or pattern';
  static const String heldConfirmed = 'Confirmed. Your current rules apply.';
  static const String heldNotConfirmed =
      'Not confirmed. The earlier, stricter rule settings still apply.';
  static const String heldUnknown =
      'Couldn\'t confirm the change. Protection hasn\'t confirmed which rule '
      'settings apply. Try again.';

  // Editor.
  static const String newTitle = 'New Smart Rule';
  static const String editTitle = 'Edit Smart Rule';
  static const String nameLabel = 'Rule name';
  static const String appsTitle = 'Protected apps';
  static const String appsHelp =
      'Only apps you protect in Apps can be selected.';
  static const String noProtectedApps =
      'No protected apps yet. Protect an app in Apps first.';
  static const String appsLoadFailed = 'Couldn\'t load your protected apps.';
  static const String notProtectedNote = 'Not protected: no effect';
  static const String daysTitle = 'Days';
  static const String timeTitle = 'Time';
  static const String allDay = 'All day';
  static const String startLabel = 'Start';
  static const String endLabel = 'End';
  static const String levelTitle = 'Security level';
  static const String reviewTitle = 'Review';
  static const String save = 'Save rule';
  static const String delete = 'Delete rule';
  static const String deleteConfirmTitle = 'Delete this rule?';
  static const String deleteConfirmBody =
      'The rule is removed. Apps keep their saved security levels.';
  static const String cancel = 'Cancel';
  static const String discardTitle = 'Discard changes?';
  static const String discardBody = 'Your changes to this rule are not saved.';
  static const String discard = 'Discard changes';
  static const String keepEditing = 'Keep editing';

  // Validation.
  static const String nameRequired = 'Enter a name.';
  static const String nameTooLong = 'Use at most ${SmartRule.maxNameLength} '
      'characters.';
  static const String nameInvalid = 'Remove unsupported characters.';
  static const String appsRequired = 'Select at least one protected app.';
  static const String daysRequired = 'Select at least one day.';
  static const String windowInvalid =
      'Start and end can\'t be the same. Turn on All day for the whole day.';
  static const String levelRequired = 'Choose a security level.';

  // Outcomes.
  static const String savedEnforced = 'Saved. Protection confirmed the rule.';
  static const String savedUnchanged = 'Saved. Nothing changed.';
  static const String savedHeld =
      'Saved. The earlier, stricter rule settings still apply until the '
      'change is confirmed.';
  static const String savedUnconfirmed =
      'Saved, but protection hasn\'t confirmed the change yet. Apps keep at '
      'least their saved security levels.';
  static const String conflict =
      'This rule was changed elsewhere, so your changes were not saved. '
      'Reopen the rule to edit the latest version.';
  static const String saveFailed =
      'Couldn\'t save. Nothing was changed. Try again.';
  static const String deleted = 'Rule deleted.';
  static const String reductionRolledBack =
      'Couldn\'t apply the change. Your previous rule settings will be '
      'restored.';
  static const String reductionRollbackFailed =
      'Couldn\'t apply the change, and your previous rule settings couldn\'t '
      'be restored. Check your Smart Rules and try again.';

  static String denied(UnprotectDenial? denial) => switch (denial) {
        UnprotectDenial.noAppCredential =>
          'Not saved. Set up a PIN or pattern to confirm changes that reduce '
              'protection.',
        UnprotectDenial.credentialUnavailable =>
          'Not saved. Your PIN or pattern couldn\'t be checked. Try again.',
        _ => 'Not saved. Reducing rule protection needs your PIN or pattern.',
      };

  /// Message after a change that did not leave the editor or list as-is.
  static String outcome(SmartRuleChangeOutcome o, {bool deleting = false}) =>
      switch (o.status) {
        SmartRuleChangeStatus.enforced => deleting ? deleted : savedEnforced,
        SmartRuleChangeStatus.unchanged => savedUnchanged,
        SmartRuleChangeStatus.savedHeld => savedHeld,
        SmartRuleChangeStatus.savedUnconfirmed => savedUnconfirmed,
        SmartRuleChangeStatus.denied => denied(o.denial),
        SmartRuleChangeStatus.conflict => conflict,
        SmartRuleChangeStatus.failed => saveFailed,
        SmartRuleChangeStatus.reductionRolledBack => reductionRolledBack,
        SmartRuleChangeStatus.reductionRollbackFailed =>
          reductionRollbackFailed,
        SmartRuleChangeStatus.relaxationUnconfirmed => heldUnknown,
      };

  /// Level option description in the editor.
  static String actionDescription(SmartRuleAction action) => switch (action) {
        SmartRuleAction.standard =>
          'Adds no protection. Apps keep their saved level.',
        SmartRuleAction.sensitive =>
          'At least Sensitive during this time. Critical apps stay Critical.',
        SmartRuleAction.critical =>
          'Critical during this time: PIN or pattern each time you return.',
        SmartRuleAction.unlocked =>
          'Not available. Smart Rules can\'t unlock apps or lower protection.',
        SmartRuleAction.applyProfile =>
          'Adds a profile\'s extra protection during this time. Your '
              'selected profile stays as it is; nothing is ever lowered.',
      };

  /// Short level summary for the list.
  static String actionSummary(SmartRuleAction action) => switch (action) {
        SmartRuleAction.standard => 'Standard · adds no protection',
        SmartRuleAction.sensitive => 'At least Sensitive',
        SmartRuleAction.critical => 'Critical',
        SmartRuleAction.unlocked => 'Unlocked · not available, no effect',
        SmartRuleAction.applyProfile => 'Applies a profile',
      };

  // ---- Phase 11 / M3: "Apply profile" rules ------------------------------

  static const String profileTitle = 'Profile to apply';
  static const String profileRequired = 'Choose a profile.';
  static const String profileMissing =
      'The profile this rule used no longer exists. Until you choose another '
      'profile or delete the rule, every protected app is Critical while it '
      'applies.';
  static const String profilesUnavailable =
      'Profiles could not be loaded. Try again.';
  static const String profileAppsNote =
      'The profile decides which protected apps get extra protection. '
      'Unprotected apps are never added.';
  static const String profileNoEffect =
      'Normal adds no protection, so this rule has no effect.';

  /// The apps line of a profile rule in the list.
  static String profileApps(String? profileName) => profileName == null
      ? 'Apps: profile missing'
      : 'Apps from the $profileName profile';

  /// The action line of a profile rule in the list.
  static String profileSummary(String? profileName) => profileName == null
      ? 'Profile missing · treated as Critical'
      : 'Applies $profileName · in addition to your selected profile';

  /// The "scheduled now" line of the profile card (calculated, not a native
  /// confirmation).
  static String scheduledNow(List<String> names) =>
      'Scheduled now: ${names.join(', ')}, in addition to your selected '
      'profile. Applies the next time you open or return to an app.';

  /// Why [action] does nothing for an app whose saved level is [baseline],
  /// or null when it can raise it.
  static String? noEffectReason(
    SmartRuleAction action,
    AppSecurityLevel baseline,
  ) {
    final AppSecurityLevel? raisesTo = action.raisesTo;
    if (raisesTo == null) return 'no change (stays ${baseline.label})';
    if (!raisesTo.isStricterThan(baseline)) {
      return 'already ${baseline.label}, no change';
    }
    return null;
  }

  static const List<String> _dayShort = <String>[
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun', //
  ];
  static const List<String> _dayLong = <String>[
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
    'Sunday', //
  ];

  static String dayShort(int day) => _dayShort[day - 1];
  static String dayLong(int day) => _dayLong[day - 1];

  static String days(List<int> days) {
    final List<int> sorted = <int>[...days]..sort();
    String key(List<int> d) => d.join(',');
    if (key(sorted) == key(SmartRuleDays.everyDay)) return 'Every day';
    if (key(sorted) == key(SmartRuleDays.weekdays)) return 'Weekdays';
    if (key(sorted) == key(SmartRuleDays.weekend)) return 'Weekends';
    return sorted.map(dayShort).join(', ');
  }

  static String minute(int m) => '${(m ~/ 60).toString().padLeft(2, '0')}:'
      '${(m % 60).toString().padLeft(2, '0')}';

  static String time(SmartRuleTime time) => switch (time) {
        SmartRuleAllDay() => allDay,
        SmartRuleWindow(:final int startMinute, :final int endMinute) =>
          startMinute < endMinute
              ? '${minute(startMinute)}–${minute(endMinute)}'
              : '${minute(startMinute)}–${minute(endMinute)} (next day)',
      };
}
