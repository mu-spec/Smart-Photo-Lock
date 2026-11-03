import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_container.dart';
import '../../../app/app_scope.dart';
import '../../../app/router.dart';
import '../../../data/models/app_security_level.dart';
import '../../../data/models/protected_app.dart';
import '../../../data/models/security_recommendation.dart';
import '../../../design_system/design_system.dart';
import '../../../protection/health/protection_health_engine.dart';
import '../../../protection/health/protection_health_monitor.dart';
import '../../../services/capability_monitor.dart';
import '../../../utilities/result.dart';
import '../health/health_presentation.dart';
import '../health/health_resume_trigger.dart';
import '../health/protection_health_controller.dart';
import 'security_center_recommendations.dart';
import 'security_center_summary.dart';
import 'security_recommendations_card.dart';
import 'security_score.dart';
import 'security_score_card.dart';

/// Phase 9 / M1 — Security Center (PRD 9A–9D), shown at the top of the
/// Security tab.
///
/// Read-only overview:
///  * **Protection Health (9D):** the ONE shared Phase 7 monitor through a
///    [ProtectionHealthController] (staleness re-applied on every read, a
///    failed refresh shows "Status unavailable", an after-change refresh
///    hides an old SECURE while checking). Wording comes from
///    [HealthPresentation]; Health Details and Fix protection reuse the
///    existing `/protection/health` route.
///  * **Protected apps (9B):** counts per saved level from
///    `ProtectedAppsRepository.getProtectedApps()` ([ProtectedAppsSummary]).
///    A read failure shows "unavailable", never zero.
///  * **Critical apps (9C):** the saved Critical assignment, kept separate
///    from whether protection is working now ([CriticalProtectionStatus]).
///  * **Security score (Phase 9 / M2, PRD 9E/9F):** [SecurityScore.assess]
///    over the SAME inputs: the health report above, the saved apps from
///    the same read (with native-confirmed levels captured at that moment)
///    and the re-lock grace (`LockSettingsRepository.getGracePeriod`, read
///    together with the apps). It is recomputed on every build, so it can
///    never disagree with the cards. A failed read clears its inputs.
///  * **Recommended improvements (Phase 9 / M3):**
///    [SecurityCenterRecommendations.assess] over the SAME score inputs plus
///    the dismissed-suggestion set (read in the same guarded load). Its
///    buttons open existing screens (Health Details, Apps) or ask the
///    Security tab to show an existing control ([onShowSetting]); "Don't
///    suggest again" writes only the existing dismissal preference.
///
/// Refresh is event driven only (no polling): when the Security tab first
/// becomes visible, when it becomes visible again, when the app returns to
/// the foreground while it is visible, when the Security tab's route becomes
/// the top route again (return from Health Details or a setup screen), and
/// on "Check again" / "Try again". Concurrent health requests share one
/// probe in the monitor.
///
/// Security boundary: it never writes a level or protection record,
/// authorizes, creates grace, touches a challenge or ticket, resets
/// lockout, or starts the watcher. Changes happen only in the existing
/// Apps tab and health repair flows.
class SecurityCenterSection extends StatefulWidget {
  const SecurityCenterSection({
    super.key,
    this.isActive = true,
    this.onNavigate,
    this.healthMonitor,
    this.settingsRevision = 0,
    this.onShowSetting,
  });

  /// Whether the Security tab is the visible tab.
  final bool isActive;

  /// Main-shell tab switch (Apps tab for "Manage apps").
  final ValueChanged<int>? onNavigate;

  /// Health source override (tests only, e.g. a monitor with a test
  /// clock). Production uses the shared `AppContainer.protectionHealth`.
  @visibleForTesting
  final ProtectionHealthMonitor? healthMonitor;

  /// Bumped by the Security tab after its re-lock grace setting changes,
  /// so the score's settings input is read again (event driven, no
  /// polling).
  final int settingsRevision;

  /// Phase 9 / M3: asks the Security tab to scroll to one of its existing
  /// controls (nothing is changed).
  final ValueChanged<SecurityCenterTarget>? onShowSetting;

  static const String title = 'Security Center';
  static const String intro =
      'What Smart App Lock protects, and whether protection is working on '
      'the last check.';
  static const String healthHeading = 'PROTECTION HEALTH';
  static const String viewDetailsLabel = 'View details';
  static const String fixProtectionLabel = 'Fix protection';
  static const String checkAgainLabel = 'Check again';
  static const String checkingLabel = 'Checking…';

  static const String appsHeading = 'Protected apps';
  static String totalLabel(int n) =>
      n == 1 ? '1 app protected' : '$n apps protected';
  static const String loadingAppsLabel = 'Loading protected apps…';
  static const String appsUnavailableTitle = 'Protected apps unavailable';
  static const String appsUnavailableMessage =
      'The saved list could not be read, so no counts are shown. This does '
      'not mean that no apps are protected.';
  static const String retryLabel = 'Try again';
  static const String emptyTitle = 'No apps are protected yet';
  static const String emptyMessage =
      'Choose the apps you want Smart App Lock to lock.';
  static const String chooseAppsLabel = 'Choose apps';
  static const String manageAppsLabel = 'Manage apps';
  static String heldStricterLabel(int n) => n == 1
      ? '1 app still re-locks at a stricter level until its lower level is '
          'confirmed.'
      : '$n apps still re-lock at a stricter level until their lower levels '
          'are confirmed.';

  static const String criticalHeading = 'Critical apps';
  static String criticalAssignedLabel(int n) =>
      n == 1 ? '1 app assigned Critical' : '$n apps assigned Critical';
  static const String criticalNoneMessage =
      'No apps are assigned Critical. Critical asks for your PIN or pattern '
      'every time you return to the app.';
  static const String assignedRowLabel = 'Assigned level';
  static const String enforcementRowLabel = 'Working now';
  static const String assignmentNote =
      'The assigned level is a saved setting. It only takes effect while '
      'protection is working.';

  /// Short status shown next to "Working now".
  static String criticalStatusLabel(CriticalProtectionStatus s) => switch (s) {
        CriticalProtectionStatus.none => '',
        CriticalProtectionStatus.checksPassed => 'Checks passed',
        CriticalProtectionStatus.attention => 'Needs attention',
        CriticalProtectionStatus.offline => 'Not working',
        CriticalProtectionStatus.unconfirmed => 'Not confirmed',
      };

  static String criticalStatusMessage(CriticalProtectionStatus s) =>
      switch (s) {
        CriticalProtectionStatus.none => '',
        CriticalProtectionStatus.checksPassed =>
          'Protection checks passed on the last check. Critical apps ask for '
              'your PIN or pattern on every return that Android reports.',
        CriticalProtectionStatus.attention =>
          'Protection needs attention, so Critical locking may be limited '
              'until it is resolved.',
        CriticalProtectionStatus.offline => HealthPresentation.offlineMessage,
        CriticalProtectionStatus.unconfirmed =>
          'Protection has not been confirmed, so Critical locking cannot be '
              'confirmed either.',
      };

  @override
  State<SecurityCenterSection> createState() => _SecurityCenterSectionState();
}

enum _AppsLoad { loading, loaded, failed }

class _SecurityCenterSectionState extends State<SecurityCenterSection>
    with AutomaticKeepAliveClientMixin {
  ProtectionHealthController? _health;
  late final HealthResumeTrigger _resume =
      HealthResumeTrigger(onResumed: _onAppResumed);

  _AppsLoad _appsLoad = _AppsLoad.loading;
  ProtectedAppsSummary? _summary;

  /// Phase 9 / M2 score inputs from the same read as [_summary]: the
  /// records, the native-confirmed levels at that moment, and the grace.
  List<ProtectedApp> _apps = const <ProtectedApp>[];
  Map<String, AppSecurityLevel> _nativeLevels =
      const <String, AppSecurityLevel>{};
  _AppsLoad _graceLoad = _AppsLoad.loading;
  Duration? _grace;

  /// Phase 9 / M3: dismissed suggestions (null = unreadable), plus the ones
  /// whose dismissal was SAVED here this session (so an older read that
  /// completes later cannot bring them back). Unsaved ones are never added.
  Set<String>? _dismissed;
  final Set<String> _sessionDismissed = <String>{};

  /// Recommendation ids whose dismissal is being saved (no double taps).
  final Set<String> _dismissing = <String>{};
  int _summaryGeneration = 0;
  bool _wasCurrent = true;
  bool _disposed = false;
  StreamSubscription<CapabilityChange>? _revocations;

  @override
  bool get wantKeepAlive => true;

  bool get _isCurrentRoute => ModalRoute.isCurrentOf(context) ?? true;

  /// Visible = the active tab AND the top route (not covered by Health
  /// Details, a setup screen or a lock challenge).
  bool get _visible => mounted && widget.isActive && _isCurrentRoute;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool current = _isCurrentRoute;
    if (_health == null) {
      _health = ProtectionHealthController(
        widget.healthMonitor ?? AppScope.read(context)?.protectionHealth,
      )..addListener(_onHealthChanged);
      _resume.attach();
      // Phase 4F parity: a permission revoked while this tab is visible is
      // re-checked at once (one event per transition, not polling).
      _revocations = AppScope.read(context)?.capabilityMonitor.changes.listen(
        (CapabilityChange change) {
          if (change.state == CapabilityState.revoked && _visible) {
            unawaited(_health?.refresh(afterChange: true));
          }
        },
      );
      _wasCurrent = current;
      if (widget.isActive && current) _refreshAll(afterChange: false);
      return;
    }
    // Back on top (Health Details, a setup or PIN screen, a challenge
    // closed): something may have changed while covered.
    if (!_wasCurrent && current && widget.isActive) {
      _refreshAll(afterChange: true);
    }
    _wasCurrent = current;
  }

  @override
  void didUpdateWidget(SecurityCenterSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive && _isCurrentRoute) {
      // Apps, PIN or permissions may have changed on another tab.
      _refreshAll(afterChange: true);
    } else if (widget.settingsRevision != oldWidget.settingsRevision &&
        _visible) {
      // The re-lock setting changed below: re-read the score inputs only.
      unawaited(_loadSummary());
    }
  }

  void _onAppResumed({required bool returned}) {
    if (!_visible) return;
    _refreshAll(afterChange: returned);
  }

  void _refreshAll({required bool afterChange}) {
    unawaited(_health?.refresh(afterChange: afterChange));
    unawaited(_loadSummary());
  }

  /// Reads the saved protected apps and (Phase 9 / M2) the re-lock grace
  /// (both read-only, concurrently). Only the newest read updates the
  /// view; a failure discards the earlier values of that input.
  Future<void> _loadSummary() async {
    final AppContainer? container = AppScope.read(context);
    final int generation = ++_summaryGeneration;
    if (container == null) {
      setState(() {
        _summary = null;
        _apps = const <ProtectedApp>[];
        _appsLoad = _AppsLoad.failed;
        _grace = null;
        _graceLoad = _AppsLoad.failed;
        _dismissed = null;
      });
      return;
    }
    if (_summary == null && _appsLoad != _AppsLoad.loading) {
      setState(() => _appsLoad = _AppsLoad.loading);
    }
    if (_grace == null && _graceLoad != _AppsLoad.loading) {
      setState(() => _graceLoad = _AppsLoad.loading);
    }
    final Future<Result<Duration>> graceRead = _readGrace(container);
    final Future<Set<String>?> dismissedRead = _readDismissed(container);
    Result<List<ProtectedApp>> result;
    try {
      result = await container.protectedApps.getProtectedApps();
    } catch (e) {
      result = Result.failure(e);
    }
    final Result<Duration> grace = await graceRead;
    final Set<String>? dismissed = await dismissedRead;
    if (_disposed || generation != _summaryGeneration) return;
    final List<ProtectedApp>? apps = result.valueOrNull;
    setState(() {
      if (result.isFailure || apps == null) {
        _summary = null;
        _apps = const <ProtectedApp>[];
        _nativeLevels = const <String, AppSecurityLevel>{};
        _appsLoad = _AppsLoad.failed;
      } else {
        _summary = ProtectedAppsSummary.fromApps(
          apps,
          nativeLevelFor: container.protectionBootstrap.nativeLevelFor,
        );
        _apps = List<ProtectedApp>.unmodifiable(apps);
        _nativeLevels = _nativeSnapshot(container, apps);
        _appsLoad = _AppsLoad.loaded;
      }
      final Duration? period = grace.valueOrNull;
      if (grace.isFailure || period == null) {
        _grace = null;
        _graceLoad = _AppsLoad.failed;
      } else {
        _grace = period;
        _graceLoad = _AppsLoad.loaded;
      }
      _dismissed = dismissed;
    });
  }

  /// The native-confirmed levels at the moment of the read (read-only).
  static Map<String, AppSecurityLevel> _nativeSnapshot(
    AppContainer container,
    List<ProtectedApp> apps,
  ) {
    final Map<String, AppSecurityLevel> levels = <String, AppSecurityLevel>{};
    for (final ProtectedApp app in apps) {
      final String pkg = app.packageName.trim();
      final AppSecurityLevel? native =
          container.protectionBootstrap.nativeLevelFor(pkg);
      if (native != null) levels[pkg] = native;
    }
    return Map<String, AppSecurityLevel>.unmodifiable(levels);
  }

  static Future<Result<Duration>> _readGrace(AppContainer container) async {
    try {
      return await container.lockSettings.getGracePeriod();
    } catch (e) {
      return Result.failure(e);
    }
  }

  /// Phase 9 / M3: the existing Phase 8 dismissal preference (advisory
  /// state only); null when it cannot be read.
  static Future<Set<String>?> _readDismissed(AppContainer container) async {
    try {
      return await container.preferences.getDismissedSecurityRecommendations();
    } catch (_) {
      return null;
    }
  }

  static ScoreSourceState _source(_AppsLoad load) => switch (load) {
        _AppsLoad.loading => ScoreSourceState.loading,
        _AppsLoad.loaded => ScoreSourceState.loaded,
        _AppsLoad.failed => ScoreSourceState.failed,
      };

  /// The Phase 9 / M2 assessment of the inputs shown right now.
  SecurityScoreAssessment _assessment(ProtectionHealthController? health) =>
      SecurityScore.assess(_scoreInputs(health));

  /// Phase 9 / M3: recommendations over exactly the score's inputs.
  RecommendationsAssessment _recommendations(
    ProtectionHealthController? health,
  ) {
    final Set<String>? dismissed = _dismissed;
    return SecurityCenterRecommendations.assess(
      RecommendationInputs(
        base: _scoreInputs(health),
        dismissed: dismissed == null
            ? null
            : <String>{...dismissed, ..._sessionDismissed},
      ),
    );
  }

  SecurityScoreInputs _scoreInputs(ProtectionHealthController? health) =>
      SecurityScoreInputs(
        appsState: _source(_appsLoad),
        apps: _apps,
        nativeLevelFor: (String pkg) => _nativeLevels[pkg],
        graceState: _source(_graceLoad),
        grace: _grace,
        health: health?.report,
        healthChecking: health?.checking ?? false,
        healthFailed: health?.failed ?? false,
      );

  void _onHealthChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openDetails() async {
    final int? tab =
        await Navigator.of(context).pushNamed<int>(RouteNames.protectionHealth);
    if (!mounted) return;
    // The refresh after closing runs when this route is on top again
    // (didChangeDependencies), so it is not repeated here.
    if (tab != null) widget.onNavigate?.call(tab);
  }

  void _openApps() => widget.onNavigate?.call(HealthPresentation.appsTab);

  /// Phase 9 / M3: a recommendation's button. Navigation, a health refresh
  /// or scrolling only; nothing is changed here.
  void _onRecommendation(SecurityCenterRecommendation r) {
    switch (r.action) {
      case RecommendationAction.openHealthDetails:
        unawaited(_openDetails());
      case RecommendationAction.checkAgain:
        unawaited(_health?.refresh(afterChange: true));
      case RecommendationAction.openApps:
        _openApps();
      case RecommendationAction.showAuthentication:
        widget.onShowSetting?.call(SecurityCenterTarget.authentication);
      case RecommendationAction.showRelock:
        widget.onShowSetting?.call(SecurityCenterTarget.relock);
    }
  }

  /// Phase 9 / M3: "Don't suggest again" (optional items only), through the
  /// existing advisory preference shared with the Apps tab.
  ///
  /// Not optimistic: a suggestion is hidden only after its key is saved, so
  /// what is hidden stays hidden after a restart. If a save fails, the
  /// suggestion stays visible (keys saved before the failure stay hidden)
  /// and a message says so, with Try again. Dismissals are not a score
  /// input and never touch a level, a setting or native enforcement.
  Future<void> _dismissRecommendation(SecurityCenterRecommendation r) async {
    if (_disposed || !r.dismissible || !_dismissing.add(r.id)) return;
    final AppContainer? container = AppScope.read(context);
    final ScaffoldMessengerState? messenger =
        ScaffoldMessenger.maybeOf(context);
    final List<String> saved = <String>[];
    bool failed = container == null;
    if (container != null) {
      for (final String key in r.dismissalKeys) {
        try {
          await container.preferences.dismissSecurityRecommendation(key);
          saved.add(key);
        } catch (_) {
          failed = true;
          break;
        }
      }
    }
    _dismissing.remove(r.id);
    if (_disposed) return;
    if (saved.isNotEmpty) setState(() => _sessionDismissed.addAll(saved));
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        failed
            ? SnackBar(
                content: const Text(
                  SecurityRecommendations.dismissNotSavedMessage,
                ),
                action: SnackBarAction(
                  label: SecurityRecommendations.dismissRetryLabel,
                  onPressed: () => unawaited(_dismissRecommendation(r)),
                ),
              )
            : const SnackBar(
                content: Text(SecurityRecommendationsCard.dismissedMessage),
              ),
      );
  }

  @override
  void dispose() {
    _disposed = true;
    _summaryGeneration++;
    _resume.detach();
    unawaited(_revocations?.cancel());
    _health?.removeListener(_onHealthChanged);
    _health?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    final ProtectionHealthController? health = _health;
    final ProtectionHealthReport? report = health?.report;
    return Column(
      key: const Key('security_center'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Semantics(
          header: true,
          child: Text(
            SecurityCenterSection.title,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: DsSpacing.xs),
        Text(
          SecurityCenterSection.intro,
          style: theme.textTheme.bodySmall?.copyWith(
            color: palette.textSecondary,
          ),
        ),
        const SizedBox(height: DsSpacing.lg),
        _HealthCard(
          controller: health,
          report: report,
          onOpenDetails: _openDetails,
        ),
        const SizedBox(height: DsSpacing.lg),
        SecurityScoreCard(
          assessment: _assessment(health),
          onOpenDetails: (health?.available ?? false) ? _openDetails : null,
          onCheckAgain: (health?.available ?? false)
              ? () => unawaited(health!.refresh(afterChange: true))
              : null,
          onRetry: () => unawaited(_loadSummary()),
          onManageApps: widget.onNavigate == null ? null : _openApps,
        ),
        const SizedBox(height: DsSpacing.lg),
        _AppsCard(
          load: _appsLoad,
          summary: _summary,
          onManageApps: widget.onNavigate == null ? null : _openApps,
          onRetry: () => unawaited(_loadSummary()),
        ),
        if (_appsLoad == _AppsLoad.loaded && _summary != null) ...<Widget>[
          const SizedBox(height: DsSpacing.lg),
          _CriticalCard(
            summary: _summary!,
            status: CriticalProtectionStatus.of(_summary!.critical, report),
            onManageApps: widget.onNavigate == null ? null : _openApps,
            onOpenDetails: (health?.available ?? false) ? _openDetails : null,
          ),
        ],
        const SizedBox(height: DsSpacing.lg),
        SecurityRecommendationsCard(
          assessment: _recommendations(health),
          onAction: _onRecommendation,
          onDismiss: (SecurityCenterRecommendation r) =>
              unawaited(_dismissRecommendation(r)),
          onRetry: () => unawaited(_loadSummary()),
          onCheckAgain: (health?.available ?? false)
              ? () => unawaited(health!.refresh(afterChange: true))
              : null,
        ),
      ],
    );
  }
}

/// Phase 9 / M3: existing Security tab controls a recommendation can show.
enum SecurityCenterTarget { authentication, relock }

/// Phase 7 status banner, the same rules as Home's PROTECTION STATUS card.
class _HealthCard extends StatelessWidget {
  const _HealthCard({
    required this.controller,
    required this.report,
    required this.onOpenDetails,
  });

  final ProtectionHealthController? controller;
  final ProtectionHealthReport? report;
  final VoidCallback onOpenDetails;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    final ProtectionHealthController? health = controller;
    final bool checking = health?.checking ?? false;
    final HealthStatusView status = HealthPresentation.status(
      report,
      checking: checking,
      failed: health?.failed ?? false,
    );
    final List<HealthIssue> problems = (report?.issues ?? const <HealthIssue>[])
        .where((HealthIssue i) => i.severity != HealthIssueSeverity.advisory)
        .toList();
    final bool available = health?.available ?? false;
    final String? actionLabel = !available
        ? null
        : (report == null || report!.state == ProtectionHealthState.secure)
            ? SecurityCenterSection.viewDetailsLabel
            : SecurityCenterSection.fixProtectionLabel;
    return Column(
      key: const Key('security_center_health'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          SecurityCenterSection.healthHeading,
          style: theme.textTheme.labelMedium?.copyWith(
            color: palette.textSecondary,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        Semantics(
          container: true,
          label: 'Protection health: ${status.title}',
          child: SecurityStatusBanner(
            key: const Key('sc_health_banner'),
            level: status.level,
            title: status.title,
            message: status.message,
            footer: problems.isEmpty
                ? null
                : Text(
                    problems.length == 1
                        ? HealthPresentation.issue(problems.first).title
                        : '${HealthPresentation.issue(problems.first).title} '
                            '(+${problems.length - 1} more)',
                    key: const Key('sc_top_issue'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ),
        // Actions sit below the banner in a Wrap so that large text on a
        // narrow screen wraps instead of overflowing.
        if (available)
          Wrap(
            alignment: WrapAlignment.end,
            spacing: DsSpacing.sm,
            children: <Widget>[
              if (actionLabel != null)
                TextButton(
                  key: const Key('sc_health_action'),
                  onPressed: onOpenDetails,
                  child: Text(actionLabel),
                ),
              TextButton.icon(
                key: const Key('sc_check_again'),
                onPressed: checking
                    ? null
                    : () => unawaited(health!.refresh(afterChange: true)),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(
                  checking
                      ? SecurityCenterSection.checkingLabel
                      : SecurityCenterSection.checkAgainLabel,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// 9B: total and level distribution of the saved protected apps.
class _AppsCard extends StatelessWidget {
  const _AppsCard({
    required this.load,
    required this.summary,
    required this.onManageApps,
    required this.onRetry,
  });

  final _AppsLoad load;
  final ProtectedAppsSummary? summary;
  final VoidCallback? onManageApps;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    final ProtectedAppsSummary? s = summary;
    final List<Widget> body;
    if (load == _AppsLoad.failed || (load == _AppsLoad.loaded && s == null)) {
      body = <Widget>[
        Text(
          SecurityCenterSection.appsUnavailableTitle,
          key: const Key('sc_apps_unavailable'),
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: DsSpacing.xs),
        Text(
          SecurityCenterSection.appsUnavailableMessage,
          style: theme.textTheme.bodySmall?.copyWith(
            color: palette.textSecondary,
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            key: const Key('sc_retry_apps'),
            onPressed: onRetry,
            child: const Text(SecurityCenterSection.retryLabel),
          ),
        ),
      ];
    } else if (s == null) {
      body = <Widget>[
        Text(
          SecurityCenterSection.loadingAppsLabel,
          key: const Key('sc_apps_loading'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: palette.textSecondary,
          ),
        ),
      ];
    } else if (s.isEmpty) {
      body = <Widget>[
        Text(
          SecurityCenterSection.emptyTitle,
          key: const Key('sc_apps_empty'),
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: DsSpacing.xs),
        Text(
          SecurityCenterSection.emptyMessage,
          style: theme.textTheme.bodySmall?.copyWith(
            color: palette.textSecondary,
          ),
        ),
        if (onManageApps != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const Key('sc_choose_apps'),
              onPressed: onManageApps,
              child: const Text(SecurityCenterSection.chooseAppsLabel),
            ),
          ),
      ];
    } else {
      body = <Widget>[
        Text(
          SecurityCenterSection.totalLabel(s.total),
          key: const Key('sc_total'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        for (final AppSecurityLevel level in AppSecurityLevel.values)
          _CountRow(
            key: Key('sc_count_${level.storageId}'),
            label: level.label,
            count: s.countOf(level),
          ),
        if (s.heldStricter > 0) ...<Widget>[
          const SizedBox(height: DsSpacing.xs),
          Text(
            SecurityCenterSection.heldStricterLabel(s.heldStricter),
            key: const Key('sc_held_stricter'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.textSecondary,
            ),
          ),
        ],
        if (onManageApps != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const Key('sc_manage_apps'),
              onPressed: onManageApps,
              child: const Text(SecurityCenterSection.manageAppsLabel),
            ),
          ),
      ];
    }
    return Semantics(
      container: true,
      child: DsCard(
        key: const Key('security_center_apps'),
        margin: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Semantics(
              header: true,
              child: Text(
                SecurityCenterSection.appsHeading,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: palette.textSecondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: DsSpacing.sm),
            ...body,
          ],
        ),
      ),
    );
  }
}

/// One "Level: count" row, read as a single phrase by screen readers.
class _CountRow extends StatelessWidget {
  const _CountRow({super.key, required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return MergeSemantics(
      child: Semantics(
        label: '$label: $count',
        excludeSemantics: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: DsSpacing.xxs),
          child: Row(
            children: <Widget>[
              Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
              Text(
                '$count',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 9C: the saved Critical assignment, separate from whether protection is
/// working now.
class _CriticalCard extends StatelessWidget {
  const _CriticalCard({
    required this.summary,
    required this.status,
    required this.onManageApps,
    required this.onOpenDetails,
  });

  final ProtectedAppsSummary summary;
  final CriticalProtectionStatus status;
  final VoidCallback? onManageApps;
  final VoidCallback? onOpenDetails;

  DsTone get _tone => switch (status) {
        CriticalProtectionStatus.checksPassed => DsTone.success,
        CriticalProtectionStatus.attention => DsTone.warning,
        CriticalProtectionStatus.offline => DsTone.danger,
        CriticalProtectionStatus.unconfirmed ||
        CriticalProtectionStatus.none =>
          DsTone.neutral,
      };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    final bool none = status == CriticalProtectionStatus.none;
    final List<String> names = summary.criticalLabels;
    final String? namesLine = names.isEmpty
        ? null
        : names.length <= 3
            ? names.join(', ')
            : '${names.take(3).join(', ')} +${names.length - 3} more';
    final bool showFix = !none &&
        status != CriticalProtectionStatus.checksPassed &&
        onOpenDetails != null;
    return Semantics(
      container: true,
      child: DsCard(
        key: const Key('security_center_critical'),
        margin: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Semantics(
              header: true,
              child: Text(
                SecurityCenterSection.criticalHeading,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: palette.textSecondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: DsSpacing.sm),
            if (none)
              Text(
                SecurityCenterSection.criticalNoneMessage,
                key: const Key('sc_critical_none'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.textSecondary,
                ),
              )
            else ...<Widget>[
              Text(
                SecurityCenterSection.assignedRowLabel,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: palette.textSecondary,
                ),
              ),
              Text(
                SecurityCenterSection.criticalAssignedLabel(summary.critical),
                key: const Key('sc_critical_assigned'),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (namesLine != null)
                Text(
                  namesLine,
                  key: const Key('sc_critical_names'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.textSecondary,
                  ),
                ),
              const SizedBox(height: DsSpacing.md),
              Wrap(
                spacing: DsSpacing.sm,
                runSpacing: DsSpacing.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Text(
                    SecurityCenterSection.enforcementRowLabel,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: palette.textSecondary,
                    ),
                  ),
                  _StatusTag(
                    key: const Key('sc_critical_status'),
                    label: SecurityCenterSection.criticalStatusLabel(status),
                    tone: _tone,
                  ),
                ],
              ),
              const SizedBox(height: DsSpacing.xs),
              Text(
                SecurityCenterSection.criticalStatusMessage(status),
                key: const Key('sc_critical_message'),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: DsSpacing.sm),
              Text(
                SecurityCenterSection.assignmentNote,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.textSecondary,
                ),
              ),
            ],
            Wrap(
              alignment: WrapAlignment.end,
              spacing: DsSpacing.sm,
              children: <Widget>[
                if (showFix)
                  TextButton(
                    key: const Key('sc_critical_fix'),
                    onPressed: onOpenDetails,
                    child: const Text(SecurityCenterSection.fixProtectionLabel),
                  ),
                if (onManageApps != null)
                  TextButton(
                    key: const Key('sc_critical_manage'),
                    onPressed: onManageApps,
                    child: const Text(SecurityCenterSection.manageAppsLabel),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A status tag in the design-system pill style whose text wraps under
/// large text (the shared pill keeps a single line).
class _StatusTag extends StatelessWidget {
  const _StatusTag({super.key, required this.label, required this.tone});

  final String label;
  final DsTone tone;

  @override
  Widget build(BuildContext context) {
    final Color color = tone.colorOf(context.dsColors);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(DsRadii.pill),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
