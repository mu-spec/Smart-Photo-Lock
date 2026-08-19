import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';

/// Home tab — welcome header, protection status, and quick access to the
/// other four sections.
///
/// This is the landing screen of the app. Real dashboards (protected app
/// count, recent lock events) replace the placeholder bits in later phases.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, this.onNavigate});

  /// Tab-switch callback provided by the shell so the quick-access tiles
  /// can jump straight to the matching tab.
  final ValueChanged<int>? onNavigate;

  /// Exact label shown in the header chip (also asserted in widget tests).
  static const String phaseLabel = 'Phase 1C — Navigation Foundation';

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: <Widget>[
          const _Header(),
          const SizedBox(height: 20),
          const _StatusCard(),
          const SizedBox(height: 24),
          Text('Quick access', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
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
          const SizedBox(height: 24),
          Text('Next up', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Coming in the next phases',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Onboarding & PIN setup, the protected apps list, smart '
                    'lock automations and the lock screen itself.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
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
    return Column(
      children: <Widget>[
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.12),
            shape: BoxShape.circle,
            border: Border.all(
              color: AppColors.accent.withValues(alpha: 0.4),
            ),
          ),
          child: const Icon(
            Icons.lock_outline,
            size: 36,
            color: AppColors.accent,
          ),
        ),
        const SizedBox(height: 16),
        Text('Smart App Lock', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: AppColors.accent.withValues(alpha: 0.35),
            ),
          ),
          child: const Text(
            HomeScreen.phaseLabel,
            style: TextStyle(
              color: AppColors.accent,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Welcome back — everything you protect lives here.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// Live summary of the protection state (placeholder values until the
/// security and app-list phases fill them in).
class _StatusCard extends StatelessWidget {
  const _StatusCard();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          children: const <Widget>[
            _StatusRow(label: 'Unlock PIN', value: 'Not set'),
            _StatusRow(label: 'Protected apps', value: '0'),
            _StatusRow(label: 'Active profile', value: 'None'),
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
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
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: theme.colorScheme.primary, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(
                      label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.textSecondary,
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
        ),
      ),
    );
  }
}
