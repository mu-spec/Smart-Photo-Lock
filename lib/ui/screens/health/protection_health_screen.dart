import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_container.dart';
import '../../../app/app_scope.dart';
import '../../../design_system/design_system.dart';
import '../../../protection/health/protection_health_engine.dart';
import '../../../services/watcher_service.dart';
import '../../../utilities/result.dart';
import 'health_presentation.dart';
import 'protection_health_controller.dart';

/// Result of a repair, judged ONLY from a fresh health report.
enum HealthRepairOutcome {
  /// A fresh, non-stale report no longer contains the issue.
  resolved,

  /// A fresh report still contains the issue.
  stillPresent,

  /// No fresh report (the check failed or was unavailable).
  unknown,
}

/// Phase 7 / M2 — Issue Details and Fix Protection.
///
/// Shows the overall state and every M1 issue in engine order (offline,
/// attention, advisory), each with its cause class and a repair the user
/// starts with a tap. Pops with a main-shell tab index when a repair lives
/// on another tab (Security / Apps).
///
/// Repairs never grant a permission, start an authorization, clear a
/// ticket or claim success: only a fresh health report can show "resolved".
/// Android Settings screens are opened, never changed; after returning, the
/// user checks again (automatic refresh on return is Phase 7 / M3).
class ProtectionHealthScreen extends StatefulWidget {
  const ProtectionHealthScreen({super.key});

  static const String title = 'Protection status';
  static const String settingsOpenedNotice =
      'Android Settings opened. After changing the setting, come back and '
      'tap Check again. The status updates only after a fresh check.';
  static const String settingsFailedNotice =
      'Android could not open that screen. Open Android Settings, then Apps, '
      'then Smart App Lock.';
  static const String checkFailedNotice =
      'Could not check again. The status is unknown until a check succeeds.';
  static const String restartFailedNotice =
      'Protection could not be restarted.';

  /// Judges a repair from a fresh report: resolved only when the report is
  /// fresh (not stale) and no longer lists the same issue code + component.
  static HealthRepairOutcome outcome(
    HealthIssue issue,
    ProtectionHealthReport? fresh,
  ) {
    if (fresh == null || fresh.stale) return HealthRepairOutcome.unknown;
    final bool present = fresh.issues.any(
      (HealthIssue i) => i.code == issue.code && i.component == issue.component,
    );
    return present
        ? HealthRepairOutcome.stillPresent
        : HealthRepairOutcome.resolved;
  }

  @override
  State<ProtectionHealthScreen> createState() => _ProtectionHealthScreenState();
}

class _ProtectionHealthScreenState extends State<ProtectionHealthScreen> {
  ProtectionHealthController? _controller;
  AppContainer? _container;
  bool _busy = false;
  String? _notice;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    _container = AppScope.read(context);
    _controller = ProtectionHealthController(_container?.protectionHealth)
      ..addListener(_onChanged);
    // The details screen became visible: one coalesced refresh.
    unawaited(_controller!.refresh());
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_onChanged);
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _checkAgain() async {
    final ProtectionHealthController? controller = _controller;
    if (controller == null || _busy) return;
    setState(() => _notice = null);
    final ProtectionHealthReport? fresh = await controller.refresh();
    if (!mounted) return;
    if (fresh == null && controller.available) {
      setState(() => _notice = ProtectionHealthScreen.checkFailedNotice);
    }
  }

  Future<void> _repair(HealthIssue issue, HealthRepairPlan plan) async {
    if (_busy) return;
    final String title = HealthPresentation.issue(issue).title;
    switch (plan.kind) {
      case HealthRepairKind.openTab:
        Navigator.of(context).pop<int>(plan.tab);
        return;
      case HealthRepairKind.checkAgain:
        await _run(() async => _judge(issue, title, await _refresh()));
        return;
      case HealthRepairKind.openSetupScreen:
        await _run(() async {
          // Existing setup screens disclose, open Settings and recheck on
          // their own; when they close, check health once.
          await Navigator.of(context).pushNamed<bool>(plan.route!);
          if (!mounted) return;
          _judge(issue, title, await _refresh());
        });
        return;
      case HealthRepairKind.openSystemSettings:
        await _run(() async {
          final WatcherService? watcher = _container?.watcher;
          final Result<bool>? opened = watcher == null
              ? null
              : await watcher.openProtectionSettings(plan.settingsTarget!);
          if (!mounted) return;
          final bool ok = opened?.valueOrNull == true;
          setState(() {
            _notice = ok
                ? ProtectionHealthScreen.settingsOpenedNotice
                : ProtectionHealthScreen.settingsFailedNotice;
          });
        });
        return;
      case HealthRepairKind.restartProtection:
        await _run(() async {
          final AppContainer? container = _container;
          if (container == null) return;
          // The existing synchronization (as used by the Security and Apps
          // screens): configures native protection from the encrypted Dart
          // settings and starts the watcher if needed. One run per tap.
          final Result<Object?> sync =
              await container.protectionBootstrap.synchronize();
          if (!mounted) return;
          final ProtectionHealthReport? fresh = await _refresh();
          if (!mounted) return;
          _judge(
            issue,
            title,
            fresh,
            prefix: sync.isFailure
                ? '${ProtectionHealthScreen.restartFailedNotice} '
                : null,
          );
        });
        return;
      case HealthRepairKind.guidanceOnly:
        return;
    }
  }

  Future<ProtectionHealthReport?> _refresh() async =>
      _controller == null ? null : await _controller!.refresh();

  Future<void> _run(Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await body();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _judge(
    HealthIssue issue,
    String title,
    ProtectionHealthReport? fresh, {
    String? prefix,
  }) {
    if (!mounted) return;
    final String text = switch (ProtectionHealthScreen.outcome(issue, fresh)) {
      HealthRepairOutcome.resolved =>
        'A fresh check no longer reports "$title".',
      HealthRepairOutcome.stillPresent => 'A fresh check still reports '
          '"$title".',
      HealthRepairOutcome.unknown => ProtectionHealthScreen.checkFailedNotice,
    };
    setState(() => _notice = '${prefix ?? ''}$text');
  }

  @override
  Widget build(BuildContext context) {
    final ProtectionHealthController? controller = _controller;
    final ProtectionHealthReport? report = controller?.report;
    final bool checking = controller?.checking ?? false;
    final HealthStatusView status = HealthPresentation.status(
      report,
      checking: checking,
      failed: controller?.failed ?? false,
    );
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    final List<HealthIssue> issues = report?.issues ?? const <HealthIssue>[];
    final List<HealthIssue> problems = issues
        .where((HealthIssue i) => i.severity != HealthIssueSeverity.advisory)
        .toList();
    final List<HealthIssue> advisories = issues
        .where((HealthIssue i) => i.severity == HealthIssueSeverity.advisory)
        .toList();
    final bool canCheck = (controller?.available ?? false) && !_busy;

    return Scaffold(
      appBar: AppBar(title: const Text(ProtectionHealthScreen.title)),
      body: SafeArea(
        child: ListView(
          key: const Key('health_details_list'),
          padding: DsInsets.screen,
          children: <Widget>[
            Semantics(
              container: true,
              label: 'Protection status: ${status.title}',
              child: SecurityStatusBanner(
                key: const Key('health_details_status'),
                level: status.level,
                title: status.title,
                message: status.message,
                footer: report == null
                    ? null
                    : Text(
                        'Last checked at '
                        '${_time(context, report.observedAt)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette.textSecondary,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: DsSpacing.md),
            Align(
              alignment: Alignment.centerLeft,
              child: DsButton(
                key: const Key('health_check_again'),
                label: checking ? 'Checking…' : 'Check again',
                icon: Icons.refresh,
                variant: DsButtonVariant.outline,
                onPressed: canCheck && !checking ? _checkAgain : null,
              ),
            ),
            if (_notice != null) ...<Widget>[
              const SizedBox(height: DsSpacing.md),
              Semantics(
                liveRegion: true,
                child: DsCard(
                  key: const Key('health_repair_notice'),
                  child: Text(_notice!),
                ),
              ),
            ],
            if (problems.isNotEmpty) ...<Widget>[
              const SizedBox(height: DsSpacing.xl),
              DsSectionTitle(
                problems.length == 1 ? 'Issue' : 'Issues (${problems.length})',
              ),
              const SizedBox(height: DsSpacing.md),
              for (final HealthIssue issue in problems)
                _IssueCard(
                  issue: issue,
                  busy: _busy || checking,
                  onRepair: _repair,
                ),
            ],
            if (advisories.isNotEmpty) ...<Widget>[
              const SizedBox(height: DsSpacing.lg),
              const DsSectionTitle('Advisories'),
              const SizedBox(height: DsSpacing.md),
              for (final HealthIssue issue in advisories)
                _IssueCard(
                  issue: issue,
                  busy: _busy || checking,
                  onRepair: _repair,
                ),
            ],
            const SizedBox(height: DsSpacing.xl),
            DsCard(
              key: const Key('health_scope_note'),
              child: Text(
                HealthPresentation.secureScope,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _time(BuildContext context, DateTime at) =>
      MaterialLocalizations.of(context).formatTimeOfDay(
        TimeOfDay.fromDateTime(at.toLocal()),
      );
}

class _IssueCard extends StatelessWidget {
  const _IssueCard({
    required this.issue,
    required this.busy,
    required this.onRepair,
  });

  final HealthIssue issue;
  final bool busy;
  final Future<void> Function(HealthIssue, HealthRepairPlan) onRepair;

  @override
  Widget build(BuildContext context) {
    final HealthIssueView view = HealthPresentation.issue(issue);
    final HealthRepairPlan plan = view.repair;
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: DsSpacing.md),
      child: DsCard(
        key: ValueKey<String>(
          'health_issue_${issue.code.id}_${issue.component.id}',
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            DsStatusPill(label: view.categoryLabel, tone: view.tone),
            const SizedBox(height: DsSpacing.sm),
            Text(
              view.title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: DsSpacing.xs),
            Text(
              view.explanation,
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.textSecondary,
              ),
            ),
            if (plan.guidance != null) ...<Widget>[
              const SizedBox(height: DsSpacing.sm),
              Text(
                plan.guidance!,
                key: ValueKey<String>('health_guidance_${issue.code.id}'),
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (plan.hasAction) ...<Widget>[
              const SizedBox(height: DsSpacing.md),
              DsButton(
                key: ValueKey<String>('health_repair_${issue.code.id}'),
                label: plan.label!,
                variant: issue.severity == HealthIssueSeverity.advisory
                    ? DsButtonVariant.outline
                    : DsButtonVariant.primary,
                onPressed: busy ? null : () => onRepair(issue, plan),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
