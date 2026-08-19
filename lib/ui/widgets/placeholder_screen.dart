import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';

/// Shared scaffold for feature screens that are not implemented yet.
///
/// Every tab keeps its own screen file and identity (see `screens/*`) so the
/// navigation graph is real even before the features land. As a feature is
/// implemented, its screen file swaps this widget for the real UI — nothing
/// else changes.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.features,
    this.badge = 'Coming soon',
  });

  final IconData icon;
  final String title;
  final String description;

  /// Short list of what will land here in later phases.
  final List<String> features;

  /// Small pill label shown under the description.
  final String badge;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        children: <Widget>[
          Center(
            child: Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.10),
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.accent.withValues(alpha: 0.35),
                ),
              ),
              child: Icon(icon, size: 40, color: AppColors.accent),
            ),
          ),
          const SizedBox(height: 20),
          Center(child: Text(title, style: theme.textTheme.headlineSmall)),
          const SizedBox(height: 8),
          Center(
            child: Text(
              description,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(child: _Badge(label: badge)),
          const SizedBox(height: 32),
          Text('Planned features', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                children: <Widget>[
                  for (final String feature in features)
                    ListTile(
                      dense: true,
                      leading: const Icon(
                        Icons.check_circle_outline,
                        color: AppColors.accent,
                        size: 20,
                      ),
                      title: Text(feature, style: theme.textTheme.bodyMedium),
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

/// Rounded status pill (shared style with the home screen chips).
class _Badge extends StatelessWidget {
  const _Badge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.accent,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
