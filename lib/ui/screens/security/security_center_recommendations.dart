import '../../../data/models/app_security_level.dart';
import '../../../data/models/protected_app.dart';
import '../../../data/models/security_recommendation.dart';
import '../../../protection/health/protection_health_engine.dart';
import '../../../protection/security_level_policy.dart';
import '../health/health_presentation.dart';
import 'security_score.dart';

/// Phase 9 / M3 (PRD "Recommendations") — Security Center recommendations.
///
/// ONE pure, deterministic and read-only function over the SAME inputs as
/// the Security Score ([SecurityScoreInputs]: the saved apps with their
/// native-confirmed levels, the re-lock grace and the Phase 7 report), plus
/// the dismissed-suggestion set of the existing Phase 8 preference.
///
/// It is not a second classifier or a second score:
///  * health items are the Phase 7 report's own issues (codes, titles,
///    explanations and repair kinds from [HealthPresentation]);
///  * security-level items come from the Phase 8 exact-package catalog
///    ([SecurityRecommendations.forApp]) with the Apps tab's rule;
///  * the re-lock item comes from [SecurityLevelPolicy.graceFor] over the
///    score's credited levels ([SecurityScore.creditedLevel]).
///
/// Order: protection problems, then attention items, then setup steps,
/// then optional improvements. Advisories (Battery Saver, fingerprint) are
/// never recommended, so nothing pushes optional capabilities.
///
/// Boundary: nothing here writes a level, setting or protection record,
/// authorizes, unlocks, creates grace, touches a challenge or ticket, or
/// resets lockout. Every change still happens in the existing flows.
abstract final class SecurityCenterRecommendations {
  // -- stable ids -----------------------------------------------------------

  static const String setupCredentialId = 'setup.credential';
  static const String setupAppsId = 'setup.apps';
  static const String levelsId = 'improve.levels';
  static const String relockId = 'improve.relock';
  static String healthId(HealthIssue issue) =>
      'health.${issue.code.id}.${issue.component.id}';

  /// Dismissal key of the re-lock item, bound to the current setting (in
  /// the existing dismissed-suggestion preference; `#` never occurs in a
  /// package name, so it cannot collide with a `package@level` key).
  static String relockDismissalKey(Duration grace) =>
      '#relock@${grace.inSeconds}';

  /// The Re-lock choices of the Security tab, shortest first. A test pins
  /// this to `SecurityScreen.graceOptions`.
  static const List<Duration> relockChoices = <Duration>[
    Duration.zero,
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 5),
  ];

  // -- wording (titles/reasons of non-health items) -------------------------

  static const String setupCredentialTitle = 'Set up a PIN or pattern';
  static const String setupCredentialReason =
      'Protected apps ask for it when they open. Protection starts after '
      'setup is finished.';
  static const String setupAppsTitle = 'Choose apps to protect';
  static const String setupAppsReason =
      'No apps are protected yet. Add the apps you want Smart App Lock to '
      'lock whenever you are ready.';

  static String levelsTitle(int n) => n == 1
      ? 'A stricter level is suggested for 1 app'
      : 'Stricter levels are suggested for $n apps';
  static const String levelsReason =
      'These apps are on a short reviewed list of apps that usually hold '
      'money, passwords, sign-in codes or private messages. Nothing changes '
      'unless you choose a new level in Apps.';

  static const String relockTitle = 'Re-lock apps sooner after you leave';
  static String relockReason({
    required int apps,
    required Duration longestNow,
    required Duration longestAfter,
  }) =>
      '${apps == 1 ? '1 protected app' : '$apps protected apps'} can stay '
      'open for up to ${durationLabel(longestNow)} after you leave '
      '${apps == 1 ? 'it' : 'them'}. A shorter grace period would make this '
      '${longestAfter == Duration.zero ? 'immediate' : 'at most ${durationLabel(longestAfter)}'}. '
      'This is optional.';

  /// Re-lock labels, matching the Security tab's options.
  static String durationLabel(Duration d) {
    if (d <= Duration.zero) return 'Immediate';
    if (d.inSeconds < 60) {
      return d.inSeconds == 1 ? '1 second' : '${d.inSeconds} seconds';
    }
    if (d.inSeconds % 60 == 0) {
      final int m = d.inMinutes;
      return m == 1 ? '1 minute' : '$m minutes';
    }
    return '${d.inSeconds} seconds';
  }

  // -- assessment -----------------------------------------------------------

  /// Assesses [inputs]. The first matching status rule wins (spec §2).
  static RecommendationsAssessment assess(RecommendationInputs inputs) {
    final SecurityScoreInputs base = inputs.base;
    if (base.appsState == ScoreSourceState.failed) {
      return const RecommendationsAssessment._unavailable(
        RecommendationsUnavailableReason.appsUnreadable,
      );
    }
    if (base.appsState == ScoreSourceState.loading) {
      return const RecommendationsAssessment._assessing();
    }
    if (base.graceState == ScoreSourceState.failed ||
        (base.graceState == ScoreSourceState.loaded && base.grace == null)) {
      return const RecommendationsAssessment._unavailable(
        RecommendationsUnavailableReason.settingsUnreadable,
      );
    }
    if (base.graceState == ScoreSourceState.loading) {
      return const RecommendationsAssessment._assessing();
    }
    final ProtectionHealthReport? report = base.health;
    if (report == null) {
      if (base.healthChecking) {
        return const RecommendationsAssessment._assessing();
      }
      return RecommendationsAssessment._unavailable(
        base.healthFailed
            ? RecommendationsUnavailableReason.healthFailed
            : RecommendationsUnavailableReason.healthNotChecked,
      );
    }

    final List<_AppLevels> apps = _AppLevels.of(base);
    final List<SecurityCenterRecommendation> items =
        <SecurityCenterRecommendation>[];

    // B. Health: the report's own issues (a stale report only says so).
    bool setupIncomplete = apps.isEmpty;
    bool credentialMissing = false;
    for (final HealthIssue issue in report.issues) {
      if (issue.severity == HealthIssueSeverity.advisory) continue;
      if (report.stale && issue.code != HealthIssueCode.healthSnapshotStale) {
        continue;
      }
      if (issue.code == HealthIssueCode.protectionNotConfigured) {
        setupIncomplete = true;
        if (issue.cause == HealthCause.setupIncomplete) {
          credentialMissing = true;
        }
        continue;
      }
      items.add(_healthItem(issue));
    }

    // A. Setup steps (never worded as a failure).
    if (credentialMissing) {
      items.add(
        const SecurityCenterRecommendation._(
          id: setupCredentialId,
          kind: RecommendationKind.setupCredential,
          priority: RecommendationPriority.setup,
          source: 'health:protection_not_configured/setup_incomplete',
          title: setupCredentialTitle,
          reason: setupCredentialReason,
          action: RecommendationAction.showAuthentication,
        ),
      );
    }
    if (apps.isEmpty) {
      items.add(
        const SecurityCenterRecommendation._(
          id: setupAppsId,
          kind: RecommendationKind.setupApps,
          priority: RecommendationPriority.setup,
          source: 'apps:none_protected',
          title: setupAppsTitle,
          reason: setupAppsReason,
          action: RecommendationAction.openApps,
        ),
      );
    }

    // C–D. Optional improvements: only once setup is complete, and only
    // when the user's dismissals are known.
    final Set<String>? dismissed = inputs.dismissed;
    final bool optionalUnavailable = !setupIncomplete && dismissed == null;
    if (!setupIncomplete && dismissed != null) {
      final SecurityCenterRecommendation? levels = _levelsItem(apps, dismissed);
      if (levels != null) items.add(levels);
      final SecurityCenterRecommendation? relock =
          _relockItem(apps, base.grace!, dismissed);
      if (relock != null) items.add(relock);
    }

    // Stable order: priority, then the order added (Phase 7 order for
    // health; levels before re-lock).
    final List<int> order = List<int>.generate(items.length, (int i) => i)
      ..sort((int a, int b) {
        final int p =
            items[a].priority.index.compareTo(items[b].priority.index);
        return p != 0 ? p : a.compareTo(b);
      });
    return RecommendationsAssessment._ready(
      items: List<SecurityCenterRecommendation>.unmodifiable(
        order.map((int i) => items[i]),
      ),
      healthStale: report.stale,
      optionalUnavailable: optionalUnavailable,
    );
  }

  static SecurityCenterRecommendation _healthItem(HealthIssue issue) {
    final HealthIssueView view = HealthPresentation.issue(issue);
    final bool checkAgain = view.repair.kind == HealthRepairKind.checkAgain;
    return SecurityCenterRecommendation._(
      id: healthId(issue),
      kind: RecommendationKind.health,
      priority: issue.severity == HealthIssueSeverity.offline
          ? RecommendationPriority.protection
          : RecommendationPriority.attention,
      source: 'health:${issue.code.id}/${issue.cause.id}',
      title: view.title,
      reason: view.explanation,
      categoryLabel: view.categoryLabel,
      action: checkAgain
          ? RecommendationAction.checkAgain
          : RecommendationAction.openHealthDetails,
      healthIssue: issue,
    );
  }

  static SecurityCenterRecommendation? _levelsItem(
    List<_AppLevels> apps,
    Set<String> dismissed,
  ) {
    final List<LevelSuggestion> suggestions = <LevelSuggestion>[];
    for (final _AppLevels app in apps) {
      final SecurityRecommendation? s = SecurityRecommendations.forApp(
        app.packageName,
        app.enforced,
        dismissed: dismissed,
      );
      if (s == null) continue;
      suggestions.add(
        LevelSuggestion._(
          packageName: app.packageName,
          label: app.label,
          current: app.saved,
          suggested: s.level,
          reason: s.reason,
          dismissalKey: s.dismissalKey,
        ),
      );
    }
    if (suggestions.isEmpty) return null;
    return SecurityCenterRecommendation._(
      id: levelsId,
      kind: RecommendationKind.levels,
      priority: RecommendationPriority.optional,
      source: 'catalog:phase8_exact_packages',
      title: levelsTitle(suggestions.length),
      reason: levelsReason,
      action: RecommendationAction.openApps,
      levels: List<LevelSuggestion>.unmodifiable(suggestions),
      dismissalKeys: List<String>.unmodifiable(
        suggestions.map((LevelSuggestion s) => s.dismissalKey),
      ),
    );
  }

  static SecurityCenterRecommendation? _relockItem(
    List<_AppLevels> apps,
    Duration configured,
    Set<String> dismissed,
  ) {
    final Duration grace = configured.isNegative ? Duration.zero : configured;
    if (grace == Duration.zero) return null;
    if (dismissed.contains(relockDismissalKey(grace))) return null;
    Duration longestNow = Duration.zero;
    int affected = 0;
    for (final _AppLevels app in apps) {
      final Duration effective =
          SecurityLevelPolicy.graceFor(app.credited, grace);
      if (effective > Duration.zero) affected++;
      if (effective > longestNow) longestNow = effective;
    }
    if (affected == 0) return null;
    // The longest shorter choice that actually shortens some app's grace.
    Duration? proposed;
    Duration longestAfter = Duration.zero;
    for (final Duration choice in relockChoices.reversed) {
      if (choice >= grace) continue;
      bool shortens = false;
      Duration longest = Duration.zero;
      for (final _AppLevels app in apps) {
        final Duration now = SecurityLevelPolicy.graceFor(app.credited, grace);
        final Duration after =
            SecurityLevelPolicy.graceFor(app.credited, choice);
        if (after < now) shortens = true;
        if (after > longest) longest = after;
      }
      if (shortens) {
        proposed = choice;
        longestAfter = longest;
        break;
      }
    }
    if (proposed == null) return null;
    return SecurityCenterRecommendation._(
      id: relockId,
      kind: RecommendationKind.relock,
      priority: RecommendationPriority.optional,
      source: 'settings:grace_period=${grace.inSeconds}s',
      title: relockTitle,
      reason: relockReason(
        apps: affected,
        longestNow: longestNow,
        longestAfter: longestAfter,
      ),
      action: RecommendationAction.showRelock,
      relock: RelockSuggestion._(
        current: grace,
        suggested: proposed,
        affectedApps: affected,
        longestNow: longestNow,
        longestAfter: longestAfter,
      ),
      dismissalKeys: <String>[relockDismissalKey(grace)],
    );
  }
}

/// Everything [SecurityCenterRecommendations.assess] reads.
class RecommendationInputs {
  const RecommendationInputs({required this.base, required this.dismissed});

  /// The Security Score's inputs (the same reads).
  final SecurityScoreInputs base;

  /// Dismissed `package@level` / re-lock keys; null when unreadable.
  final Set<String>? dismissed;
}

enum RecommendationsStatus { assessing, unavailable, ready }

enum RecommendationsUnavailableReason {
  appsUnreadable,
  settingsUnreadable,
  healthFailed,
  healthNotChecked,
}

/// Priority, grounded in severity: protection problems (Phase 7 offline
/// severity), then items needing attention, then setup steps, then
/// optional improvements.
enum RecommendationPriority { protection, attention, setup, optional }

enum RecommendationKind { health, setupCredential, setupApps, levels, relock }

/// What the item's button does. Every target is an existing screen or
/// control; nothing here changes a setting by itself.
enum RecommendationAction {
  /// The existing `/protection/health` route (it runs every Phase 7 repair).
  openHealthDetails,

  /// A Phase 7 health refresh (out-of-date or unconfirmed status).
  checkAgain,

  /// The Apps tab (protect apps or change a level there).
  openApps,

  /// Scroll to the Security tab's Authentication section.
  showAuthentication,

  /// Scroll to the Security tab's Re-lock "Grace period" control.
  showRelock,
}

class LevelSuggestion {
  const LevelSuggestion._({
    required this.packageName,
    required this.label,
    required this.current,
    required this.suggested,
    required this.reason,
    required this.dismissalKey,
  });

  final String packageName;
  final String label;

  /// The saved level.
  final AppSecurityLevel current;
  final AppSecurityLevel suggested;
  final String reason;
  final String dismissalKey;
}

class RelockSuggestion {
  const RelockSuggestion._({
    required this.current,
    required this.suggested,
    required this.affectedApps,
    required this.longestNow,
    required this.longestAfter,
  });

  final Duration current;
  final Duration suggested;
  final int affectedApps;
  final Duration longestNow;
  final Duration longestAfter;
}

class SecurityCenterRecommendation {
  const SecurityCenterRecommendation._({
    required this.id,
    required this.kind,
    required this.priority,
    required this.source,
    required this.title,
    required this.reason,
    required this.action,
    this.categoryLabel,
    this.healthIssue,
    this.levels = const <LevelSuggestion>[],
    this.relock,
    this.dismissalKeys = const <String>[],
  });

  /// Stable identifier (see the `*Id` constants).
  final String id;
  final RecommendationKind kind;
  final RecommendationPriority priority;

  /// The signal or saved configuration it is based on.
  final String source;
  final String title;
  final String reason;
  final RecommendationAction action;

  /// Phase 7 category label of a health item (for example "Setup needed").
  final String? categoryLabel;
  final HealthIssue? healthIssue;
  final List<LevelSuggestion> levels;
  final RelockSuggestion? relock;

  /// Keys written by "Don't suggest again" (optional items only).
  final List<String> dismissalKeys;

  bool get dismissible => dismissalKeys.isNotEmpty;
}

class RecommendationsAssessment {
  const RecommendationsAssessment._assessing()
      : status = RecommendationsStatus.assessing,
        reason = null,
        items = const <SecurityCenterRecommendation>[],
        healthStale = false,
        optionalUnavailable = false;

  const RecommendationsAssessment._unavailable(
    RecommendationsUnavailableReason this.reason,
  )   : status = RecommendationsStatus.unavailable,
        items = const <SecurityCenterRecommendation>[],
        healthStale = false,
        optionalUnavailable = false;

  const RecommendationsAssessment._ready({
    required this.items,
    required this.healthStale,
    required this.optionalUnavailable,
  })  : status = RecommendationsStatus.ready,
        reason = null;

  final RecommendationsStatus status;
  final RecommendationsUnavailableReason? reason;
  final List<SecurityCenterRecommendation> items;

  /// The health report is out of date (only "Check again" is listed).
  final bool healthStale;

  /// Optional suggestions could not be evaluated (dismissals unreadable).
  final bool optionalUnavailable;

  /// The calm "nothing to suggest" state: everything was readable, the
  /// health check is fresh and there is nothing to list.
  bool get allClear =>
      status == RecommendationsStatus.ready &&
      items.isEmpty &&
      !healthStale &&
      !optionalUnavailable;
}

/// One protected app (the M1 summary's dedup rules: first record per
/// package wins; blank package names are ignored).
class _AppLevels {
  const _AppLevels({
    required this.packageName,
    required this.label,
    required this.saved,
    required this.enforced,
    required this.credited,
  });

  final String packageName;
  final String label;
  final AppSecurityLevel saved;

  /// The stricter of saved and native (the Apps tab's suggestion basis).
  final AppSecurityLevel enforced;

  /// The score's conservative credited level.
  final AppSecurityLevel credited;

  static List<_AppLevels> of(SecurityScoreInputs base) {
    final Set<String> seen = <String>{};
    final List<_AppLevels> apps = <_AppLevels>[];
    for (final ProtectedApp app in base.apps) {
      final String pkg = app.packageName.trim();
      if (pkg.isEmpty || !seen.add(pkg)) continue;
      final AppSecurityLevel saved = app.securityLevel;
      final AppSecurityLevel? native = base.nativeLevelFor?.call(pkg);
      apps.add(
        _AppLevels(
          packageName: pkg,
          label: app.label.trim().isEmpty ? pkg : app.label,
          saved: saved,
          enforced: native == null
              ? saved
              : SecurityLevelPolicy.stricter(saved, native),
          credited: SecurityScore.creditedLevel(saved, native),
        ),
      );
    }
    return apps;
  }
}
