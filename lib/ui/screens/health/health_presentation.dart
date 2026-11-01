import '../../../app/router.dart';
import '../../../design_system/design_system.dart';
import '../../../protection/health/protection_health_engine.dart';
import '../../../services/watcher_service.dart';

/// Phase 7 / M2 — wording and repair plans for the Protection Health
/// dashboard.
///
/// This is presentation only. Every decision comes from the Phase 7 / M1
/// [ProtectionHealthReport]: the overall state, the issue `code`, `cause`,
/// derived `category` and repair `action`. Nothing here classifies health
/// a second time, and nothing here can make a report look SECURE.
///
/// Copy rules: no absolute claims ("100% secure", "unhackable", "impossible
/// to bypass"), no technical secrets or raw native error text, and setup or
/// a user's own choice is never worded as a system failure.

/// How the dashboard presents the overall status.
class HealthStatusView {
  const HealthStatusView({
    required this.title,
    required this.message,
    required this.level,
  });

  /// Headline: one of the three PRD states, or a "no report" placeholder.
  final String title;
  final String message;
  final SecurityLevel level;
}

/// What a repair button does. The dashboard executes it only on a tap.
enum HealthRepairKind {
  /// Switch to a main tab (Security or Apps) to use an existing flow.
  openTab,

  /// Push an existing in-app setup screen (disclose → settings → recheck).
  openSetupScreen,

  /// Open one allowlisted Android Settings screen.
  openSystemSettings,

  /// Re-run the existing protection synchronization once.
  restartProtection,

  /// Collect fresh health signals.
  checkAgain,

  /// No safe direct action exists: guidance text only.
  guidanceOnly,
}

/// A user-initiated repair for one issue.
class HealthRepairPlan {
  const HealthRepairPlan({
    required this.kind,
    this.label,
    this.guidance,
    this.tab,
    this.route,
    this.settingsTarget,
  });

  final HealthRepairKind kind;

  /// Button label; null for [HealthRepairKind.guidanceOnly].
  final String? label;

  /// Extra manual steps (for example OEM battery controls).
  final String? guidance;

  /// Main-shell tab index for [HealthRepairKind.openTab].
  final int? tab;

  /// Named route for [HealthRepairKind.openSetupScreen].
  final String? route;

  /// Settings screen for [HealthRepairKind.openSystemSettings].
  final ProtectionSettingsTarget? settingsTarget;

  bool get hasAction => kind != HealthRepairKind.guidanceOnly;
}

/// How one issue is presented.
class HealthIssueView {
  const HealthIssueView({
    required this.title,
    required this.explanation,
    required this.categoryLabel,
    required this.tone,
    required this.repair,
  });

  final String title;
  final String explanation;
  final String categoryLabel;
  final DsTone tone;
  final HealthRepairPlan repair;
}

abstract final class HealthPresentation {
  /// Main-shell tab indices (see `MainShell`).
  static const int appsTab = 1;
  static const int securityTab = 3;

  static const String secureTitle = 'SECURE';
  static const String attentionTitle = 'ATTENTION REQUIRED';
  static const String offlineTitle = 'PROTECTION OFFLINE';
  static const String checkingTitle = 'Checking protection…';
  static const String unavailableTitle = 'Status unavailable';

  /// Shown wherever SECURE is explained: an honest scope statement.
  static const String secureScope =
      'SECURE means every check Smart App Lock can run passed on the last '
      'check. It is not a guarantee against every possible bypass, and some '
      'phone controls (such as manufacturer battery managers) cannot be '
      'checked.';

  /// Overall status. [report] null means no usable observation exists.
  static HealthStatusView status(
    ProtectionHealthReport? report, {
    bool checking = false,
    bool failed = false,
  }) {
    if (report == null) {
      if (failed) {
        return const HealthStatusView(
          title: unavailableTitle,
          message: 'Smart App Lock could not check protection. This does not '
              'mean protection is working. Try checking again.',
          level: SecurityLevel.atRisk,
        );
      }
      return HealthStatusView(
        title: checking ? checkingTitle : unavailableTitle,
        message: checking
            ? 'Reading the current protection signals.'
            : 'Protection has not been checked yet.',
        level: SecurityLevel.notSet,
      );
    }
    final HealthIssue? top = report.issues.isEmpty ? null : report.issues.first;
    switch (report.state) {
      case ProtectionHealthState.secure:
        return const HealthStatusView(
          title: secureTitle,
          message: 'All protection checks passed on the last check.',
          level: SecurityLevel.secured,
        );
      case ProtectionHealthState.attentionRequired:
        final bool onlyStale = report.issues
            .where(
                (HealthIssue i) => i.severity != HealthIssueSeverity.advisory)
            .every(
              (HealthIssue i) => i.code == HealthIssueCode.healthSnapshotStale,
            );
        return HealthStatusView(
          title: attentionTitle,
          message: onlyStale
              ? 'The last check is out of date, so protection cannot be '
                  'confirmed. Check again.'
              : 'Something needs your review. Protection may be limited '
                  'until it is resolved.',
          level: SecurityLevel.atRisk,
        );
      case ProtectionHealthState.protectionOffline:
        final HealthIssueCategory? category = top?.category;
        if (category == HealthIssueCategory.setup &&
            top?.code == HealthIssueCode.protectionNotConfigured) {
          return const HealthStatusView(
            title: offlineTitle,
            message: 'Setup is not finished yet. Create an unlock PIN or '
                'pattern and choose apps to start protecting them.',
            level: SecurityLevel.notSet,
          );
        }
        if (category == HealthIssueCategory.userChoice) {
          return const HealthStatusView(
            title: offlineTitle,
            message: 'No apps are protected right now. Choose apps whenever '
                'you are ready.',
            level: SecurityLevel.notSet,
          );
        }
        if (category == HealthIssueCategory.setup) {
          return const HealthStatusView(
            title: offlineTitle,
            message: 'A permission protection needs has not been allowed '
                'yet. Protected apps can open without a lock until it is.',
            level: SecurityLevel.vulnerable,
          );
        }
        return const HealthStatusView(
          title: offlineTitle,
          message: 'Protection is not working right now. Protected apps can '
              'open without a lock until this is fixed.',
          level: SecurityLevel.vulnerable,
        );
    }
  }

  /// Wording for one M1 issue.
  static HealthIssueView issue(HealthIssue issue) {
    final ({String title, String explanation}) copy = _copy(issue);
    return HealthIssueView(
      title: copy.title,
      explanation: copy.explanation,
      categoryLabel: categoryLabel(issue.category),
      tone: _tone(issue),
      repair: repair(issue),
    );
  }

  static String categoryLabel(HealthIssueCategory category) =>
      switch (category) {
        HealthIssueCategory.setup => 'Setup needed',
        HealthIssueCategory.userChoice => 'Your choice',
        HealthIssueCategory.revoked => 'Permission turned off',
        HealthIssueCategory.interrupted => 'Stopped',
        HealthIssueCategory.restricted => 'Restricted by Android',
        HealthIssueCategory.uncertain => 'Cannot confirm',
        HealthIssueCategory.advisory => 'Advisory',
      };

  static DsTone _tone(HealthIssue issue) {
    if (issue.severity == HealthIssueSeverity.advisory ||
        issue.category == HealthIssueCategory.userChoice) {
      return DsTone.neutral;
    }
    if (issue.code == HealthIssueCode.protectionNotConfigured) {
      return DsTone.info;
    }
    return issue.severity == HealthIssueSeverity.offline
        ? DsTone.danger
        : DsTone.warning;
  }

  static String componentName(HealthComponent component) => switch (component) {
        HealthComponent.protectionConfiguration => 'protection settings',
        HealthComponent.nativeEnforcement => 'the protection switch',
        HealthComponent.overlay => 'display over other apps',
        HealthComponent.accessibilityDetection => 'the Accessibility service',
        HealthComponent.usageAccessDetection => 'Usage Access',
        HealthComponent.watcher => 'the protection service',
        HealthComponent.shield => 'the lock screen cover',
        HealthComponent.notifications => 'notifications',
        HealthComponent.backgroundRestriction => 'background activity',
        HealthComponent.oemBackgroundControls => 'phone battery controls',
        HealthComponent.batterySaver => 'Battery Saver',
        HealthComponent.biometric => 'fingerprint unlock',
        HealthComponent.nativeHealth => 'the protection engine',
      };

  static ({String title, String explanation}) _copy(HealthIssue issue) {
    final bool revoked = issue.cause == HealthCause.revoked;
    switch (issue.code) {
      case HealthIssueCode.protectionNotConfigured:
        return switch (issue.cause) {
          HealthCause.setupIncomplete => (
              title: 'Finish setting up protection',
              explanation: 'Create an unlock PIN or pattern, then choose the '
                  'apps you want to protect.',
            ),
          HealthCause.noProtectedApps => (
              title: 'No apps are protected',
              explanation: 'You have not chosen any apps to lock. Add apps '
                  'whenever you are ready.',
            ),
          _ => (
              title: 'Protection is not set up',
              explanation: 'No apps are being protected.',
            ),
        };
      case HealthIssueCode.enforcementNotArmed:
        return (
          title: 'Protection is not active on this phone',
          explanation: 'Your settings are saved, but the lock service has '
              'not switched on. Restarting protection usually fixes this.',
        );
      case HealthIssueCode.overlayUnavailable:
        return (
          title: revoked
              ? 'Display over other apps was turned off'
              : 'Display over other apps is not allowed yet',
          explanation: revoked
              ? 'It was allowed before and is now off. Smart App Lock needs '
                  'it to cover protected apps with the lock screen.'
              : 'Smart App Lock needs it to cover protected apps with the '
                  'lock screen.',
        );
      case HealthIssueCode.detectionOffline:
        return (
          title: 'Smart App Lock cannot see which app is open',
          explanation: switch (issue.cause) {
            HealthCause.notGranted => 'Neither the Accessibility service nor '
                'Usage Access has been allowed yet, so protected apps cannot '
                'be detected.',
            HealthCause.revoked => 'Access used to detect protected apps was '
                'turned off, so protected apps cannot be detected.',
            _ => 'The services that detect protected apps have stopped, so '
                'protected apps cannot be detected.',
          },
        );
      case HealthIssueCode.accessibilityUnavailable:
        return (
          title: revoked
              ? 'Accessibility service was turned off'
              : 'Accessibility service is not turned on',
          explanation: revoked
              ? 'It was on before. Without it, detection relies on the '
                  'slower Usage Access backup.'
              : 'It is the fastest way to detect protected apps. Until it is '
                  'on, detection relies on the slower Usage Access backup.',
        );
      case HealthIssueCode.accessibilityNotRunning:
        return (
          title: 'Accessibility service is not running',
          explanation: 'Android shows it as on, but it is not connected. '
              'Turning it off and on again in Accessibility settings usually '
              'reconnects it.',
        );
      case HealthIssueCode.usageAccessUnavailable:
        return (
          title: revoked
              ? 'Usage Access was turned off'
              : 'Usage Access is not allowed yet',
          explanation: 'Usage Access is the backup way to detect protected '
              'apps if the Accessibility service stops.',
        );
      case HealthIssueCode.watcherNotRunning:
        return (
          title: 'Protection service stopped',
          explanation: 'The background service that keeps protection running '
              'is not running. Android or the phone battery manager may have '
              'stopped it.',
        );
      case HealthIssueCode.shieldNotArmed:
        return (
          title: 'Lock screen cover is not ready',
          explanation: 'The cover that hides a protected app until the lock '
              'appears is not ready.',
        );
      case HealthIssueCode.notificationsDisabled:
        return (
          title: 'Notifications are off',
          explanation: 'The protection service shows a status notification. '
              'With notifications off it is hidden, so you may not notice if '
              'protection stops.',
        );
      case HealthIssueCode.backgroundRestricted:
        return (
          title: 'Android restricts Smart App Lock in the background',
          explanation: 'Android may stop protection while Smart App Lock is '
              'not on screen.',
        );
      case HealthIssueCode.signalUnknown:
        return (
          title: 'Could not confirm ${componentName(issue.component)}',
          explanation: 'This check could not be read, so Smart App Lock '
              'cannot confirm that protection is working.',
        );
      case HealthIssueCode.healthSnapshotStale:
        return (
          title: 'Status is out of date',
          explanation: 'The last check is too old to rely on.',
        );
      case HealthIssueCode.batterySaverOn:
        return (
          title: 'Battery Saver is on',
          explanation: 'Some phones limit background apps more while Battery '
              'Saver is on. This does not change the status above.',
        );
      case HealthIssueCode.biometricUnavailable:
        return (
          title: switch (issue.cause) {
            HealthCause.notEnrolled => 'No fingerprint is enrolled',
            HealthCause.unsupported =>
              'Fingerprint unlock is not available on this phone',
            _ => 'Could not check fingerprint unlock',
          },
          explanation: 'Fingerprint unlock is optional. Your PIN or pattern '
              'still unlocks protected apps.',
        );
    }
  }

  /// The repair for an issue, from its M1 `action` hint.
  static HealthRepairPlan repair(HealthIssue issue) {
    switch (issue.action) {
      case HealthRepairAction.configureProtection:
        return const HealthRepairPlan(
          kind: HealthRepairKind.openTab,
          label: 'Set up PIN or pattern',
          tab: securityTab,
        );
      case HealthRepairAction.chooseProtectedApps:
        return const HealthRepairPlan(
          kind: HealthRepairKind.openTab,
          label: 'Choose apps',
          tab: appsTab,
        );
      case HealthRepairAction.openOverlaySettings:
        return const HealthRepairPlan(
          kind: HealthRepairKind.openSetupScreen,
          label: 'Allow display over apps',
          route: RouteNames.overlaySetup,
        );
      case HealthRepairAction.openAccessibilitySettings:
        return const HealthRepairPlan(
          kind: HealthRepairKind.openSetupScreen,
          label: 'Open Accessibility setup',
          route: RouteNames.accessibilitySetup,
        );
      case HealthRepairAction.openUsageAccessSettings:
        return const HealthRepairPlan(
          kind: HealthRepairKind.openSetupScreen,
          label: 'Open Usage Access setup',
          route: RouteNames.usageAccess,
        );
      case HealthRepairAction.openNotificationSettings:
        return const HealthRepairPlan(
          kind: HealthRepairKind.openSystemSettings,
          label: 'Open notification settings',
          settingsTarget: ProtectionSettingsTarget.notifications,
          guidance: 'Allow notifications for Smart App Lock, then come back '
              'and check again.',
        );
      case HealthRepairAction.openAppBatterySettings:
        return const HealthRepairPlan(
          kind: HealthRepairKind.openSystemSettings,
          label: 'Open app settings',
          settingsTarget: ProtectionSettingsTarget.appDetails,
          guidance: 'In App info, open Battery and allow background activity. '
              'Some phones (for example ColorOS) have extra battery or '
              'auto-start controls that Smart App Lock cannot check; their '
              'names vary by phone.',
        );
      case HealthRepairAction.openBatterySaverSettings:
        return const HealthRepairPlan(
          kind: HealthRepairKind.openSystemSettings,
          label: 'Battery Saver settings',
          settingsTarget: ProtectionSettingsTarget.batterySaver,
          guidance: 'Optional. No action is needed for protection.',
        );
      case HealthRepairAction.openBiometricSettings:
        // Advisory only: the app never launches biometric enrollment.
        return const HealthRepairPlan(
          kind: HealthRepairKind.guidanceOnly,
          guidance: 'No action is needed. To use fingerprint unlock, enroll '
              'a fingerprint in Android Settings, then turn it on in '
              'Security.',
        );
      case HealthRepairAction.openSmartAppLock:
        return const HealthRepairPlan(
          kind: HealthRepairKind.restartProtection,
          label: 'Restart protection',
          guidance: 'If it stops again, check background and battery '
              'restrictions for Smart App Lock.',
        );
      case HealthRepairAction.refresh:
        return const HealthRepairPlan(
          kind: HealthRepairKind.checkAgain,
          label: 'Check again',
        );
      case null:
        return const HealthRepairPlan(
          kind: HealthRepairKind.guidanceOnly,
          guidance: 'There is no direct fix for this from Smart App Lock.',
        );
    }
  }
}
