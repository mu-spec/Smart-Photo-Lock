import 'package:flutter/material.dart';

import '../../design_system/design_system.dart';

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
    final DsPalette palette = context.dsColors;
    return SafeArea(
      child: ListView(
        padding: DsInsets.screen,
        children: <Widget>[
          Center(
            child: Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: palette.primary.withValues(alpha: 0.10),
                shape: BoxShape.circle,
                border: Border.all(
                  color: palette.primary.withValues(alpha: 0.35),
                ),
              ),
              child: Icon(icon, size: 40, color: palette.primary),
            ),
          ),
          const SizedBox(height: DsSpacing.xl),
          Center(child: Text(title, style: theme.textTheme.headlineSmall)),
          const SizedBox(height: DsSpacing.sm),
          Center(
            child: Text(
              description,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: palette.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: DsSpacing.lg),
          Center(child: DsStatusPill(label: badge)),
          const SizedBox(height: DsSpacing.xxl),
          const DsSectionTitle('Planned features'),
          const SizedBox(height: DsSpacing.md),
          DsCard(
            padding: const EdgeInsets.symmetric(vertical: DsSpacing.xs + 2),
            child: Column(
              children: <Widget>[
                for (final String feature in features)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      Icons.check_circle_outline,
                      color: palette.primary,
                      size: 20,
                    ),
                    title: Text(feature, style: theme.textTheme.bodyMedium),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
