import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';

/// Home tab — welcome header, protection status, and quick access to the
/// other four sections. Built entirely on the design system.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, this.onNavigate});

  /// Tab-switch callback provided by the shell so the quick-access tiles
  /// can jump straight to the matching tab.
  final ValueChanged<int>? onNavigate;

  /// Exact label shown in the header chip (also asserted in widget tests).
  static const String phaseLabel = 'Phase 2 Complete';

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: DsInsets.screen,
        children: <Widget>[
          const _Header(),
          const SizedBox(height: DsSpacing.xl),
          const _StatusCard(),
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

/// Live summary of the protection state (placeholder values until the
/// security and app-list phases feed real data).
class _StatusCard extends StatelessWidget {
  const _StatusCard();

  @override
  Widget build(BuildContext context) {
    return DsCard(
      title: 'Protection status',
      child: Column(
        children: <Widget>[
          _StatusRow(
            label: 'Unlock PIN',
            trailing: const SecurityStatusPill(level: SecurityLevel.notSet),
          ),
          _StatusRow(
            label: 'Protected apps',
            trailing: const DsStatusPill(label: '0'),
          ),
          _StatusRow(
            label: 'Active profile',
            trailing: const DsStatusPill(label: 'None'),
          ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.trailing});

  final String label;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    return Padding(
      padding: DsInsets.row,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.textSecondary,
            ),
          ),
          trailing,
        ],
      ),
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
