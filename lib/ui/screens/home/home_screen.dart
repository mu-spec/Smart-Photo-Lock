import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../app/router.dart';
import '../../../design_system/design_system.dart';
import '../../../protection/health/protection_health_engine.dart';
import '../health/health_presentation.dart';
import '../health/protection_health_controller.dart';

/// Home tab — welcome header, protection status, and quick access to the
/// other four sections. Built entirely on the design system.
///
/// Phase 7 / M2: the status card is driven by the shared Phase 7 / M1
/// Protection Health monitor. Health is refreshed (one coalesced probe)
/// when Home first appears, when the Home tab becomes visible again, when
/// the details screen closes, and on "Check again". There is no polling.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.onNavigate, this.isActive = true});

  /// Tab-switch callback provided by the shell so the quick-access tiles
  /// can jump straight to the matching tab.
  final ValueChanged<int>? onNavigate;

  /// Whether the Home tab is the visible tab (the shell keeps every tab
  /// alive in an IndexedStack). Becoming active triggers one refresh.
  final bool isActive;

  /// Exact label shown in the header chip (also asserted in widget tests).
  static const String phaseLabel = 'Phase 5 Complete';

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  ProtectionHealthController? _health;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_health != null) return;
    _health = ProtectionHealthController(
      AppScope.read(context)?.protectionHealth,
    )..addListener(_onHealthChanged);
    if (widget.isActive) unawaited(_health!.refresh());
  }

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      unawaited(_health?.refresh());
    }
  }

  void _onHealthChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _health?.removeListener(_onHealthChanged);
    _health?.dispose();
    super.dispose();
  }

  Future<void> _openDetails() async {
    final int? tab =
        await Navigator.of(context).pushNamed<int>(RouteNames.protectionHealth);
    if (!mounted) return;
    if (tab != null) widget.onNavigate?.call(tab);
    unawaited(_health?.refresh());
  }

  @override
  Widget build(BuildContext context) {
    final ValueChanged<int>? onNavigate = widget.onNavigate;
    return SafeArea(
      child: ListView(
        padding: DsInsets.screen,
        children: <Widget>[
          const _Header(),
          const SizedBox(height: DsSpacing.xl),
          _ProtectionStatusCard(
            controller: _health,
            onOpenDetails: _openDetails,
          ),
          const SizedBox(height: DsSpacing.xl),
          const DsSectionTitle('Quick access'),
          const SizedBox(height: DsSpacing.md),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: DsSpacing.sm + 2,
            crossAxisSpacing: DsSpacing.sm + 2,
            childAspectRatio: 1.7,
            children: <Widget>[
              _QuickTile(
                key: const Key('quick_access_apps'),
                icon: Icons.apps,
                label: 'Apps',
                subtitle: 'Choose apps to lock',
                onTap: () => onNavigate?.call(1),
              ),
              _QuickTile(
                key: const Key('quick_access_smart'),
                icon: Icons.auto_awesome,
                label: 'Smart',
                subtitle: 'Auto-lock rules',
                onTap: () => onNavigate?.call(2),
              ),
              _QuickTile(
                key: const Key('quick_access_security'),
                icon: Icons.shield,
                label: 'Security',
                subtitle: 'PIN & protection',
                onTap: () => onNavigate?.call(3),
              ),
              _QuickTile(
                key: const Key('quick_access_settings'),
                icon: Icons.settings,
                label: 'Settings',
                subtitle: 'Preferences',
                onTap: () => onNavigate?.call(4),
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.xl),
          const DsSectionTitle('Developer'),
          const SizedBox(height: DsSpacing.md),
          // Phase 5B: temporary diagnostics entry — verifies foreground
          // detection on a device. Removed once the lock engine lands.
          DsCard(
            key: const Key('quick_access_diagnostics'),
            onTap: () => Navigator.of(context)
                .pushNamed(RouteNames.detectionDiagnostics),
            child: Row(
              children: <Widget>[
                Icon(Icons.terminal, color: context.dsColors.primary),
                const SizedBox(width: DsSpacing.md),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Detection diagnostics',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      SizedBox(height: DsSpacing.xxs),
                      Text('Verify foreground app detection'),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: context.dsColors.textSecondary,
                ),
              ],
            ),
          ),
          const SizedBox(height: DsSpacing.xl),
          const DsSectionTitle('Next up'),
          const SizedBox(height: DsSpacing.md),
          const DsCard(
            title: 'Coming in the next phases',
            subtitle: 'Onboarding & PIN setup, the protected apps list, '
                'smart lock automations and the lock screen itself.',
          ),
        ],
      ),
    );
  }
}

/// Brand header: logo, app name, phase chip, welcome note.
class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    return Column(
      children: <Widget>[
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: palette.primary.withValues(alpha: 0.12),
            shape: BoxShape.circle,
            border: Border.all(color: palette.primary.withValues(alpha: 0.4)),
          ),
          child: Icon(Icons.lock_outline, size: 36, color: palette.primary),
        ),
        const SizedBox(height: DsSpacing.lg),
        Text('Smart App Lock', style: theme.textTheme.headlineSmall),
        const SizedBox(height: DsSpacing.sm + 2),
        const DsStatusPill(label: HomeScreen.phaseLabel, showDot: false),
        const SizedBox(height: DsSpacing.md),
        Text(
          'Welcome back — everything you protect lives here.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: palette.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// Phase 7 / M2 — PROTECTION STATUS card, driven by the M1 health report.
class _ProtectionStatusCard extends StatelessWidget {
  const _ProtectionStatusCard({
    required this.controller,
    required this.onOpenDetails,
  });

  final ProtectionHealthController? controller;
  final VoidCallback onOpenDetails;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    final ProtectionHealthController? health = controller;
    final ProtectionHealthReport? report = health?.report;
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
        : report == null
            ? 'View details'
            : report.state == ProtectionHealthState.secure
                ? 'View details'
                : 'Fix protection';

    return Column(
      key: const Key('home_protection_status'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'PROTECTION STATUS',
          style: theme.textTheme.labelMedium?.copyWith(
            color: palette.textSecondary,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        Semantics(
          container: true,
          label: 'Protection status: ${status.title}',
          child: SecurityStatusBanner(
            level: status.level,
            title: status.title,
            message: status.message,
            actionLabel: actionLabel,
            onAction: actionLabel == null ? null : onOpenDetails,
            footer: problems.isEmpty
                ? null
                : Text(
                    problems.length == 1
                        ? HealthPresentation.issue(problems.first).title
                        : '${HealthPresentation.issue(problems.first).title} '
                            '(+${problems.length - 1} more)',
                    key: const Key('home_top_issue'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ),
        if (available)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const Key('home_check_again'),
              onPressed: checking ? null : () => unawaited(health!.refresh()),
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(checking ? 'Checking…' : 'Check again'),
            ),
          ),
      ],
    );
  }
}

/// Tappable dashboard tile used by the quick-access grid.
class _QuickTile extends StatelessWidget {
  const _QuickTile({
    super.key,
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    return DsCard(
      margin: EdgeInsets.zero,
      padding: DsInsets.cardCompact,
      onTap: onTap,
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: palette.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(DsRadii.sm + 2),
            ),
            child: Icon(icon, color: palette.primary, size: 22),
          ),
          const SizedBox(width: DsSpacing.sm + 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  label,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: DsSpacing.xxs),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.textSecondary,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
