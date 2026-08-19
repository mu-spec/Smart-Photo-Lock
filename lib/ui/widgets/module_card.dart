import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';

/// Static description of one architecture module, shown on the home dashboard.
class ModuleInfo {
  const ModuleInfo({
    required this.icon,
    required this.title,
    required this.description,
    required this.path,
  });

  final IconData icon;
  final String title;
  final String description;
  final String path;
}

/// Dashboard card representing one architecture module.
class ModuleCard extends StatelessWidget {
  const ModuleCard({super.key, required this.info, required this.status});

  final ModuleInfo info;
  final String status;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: <Widget>[
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(info.icon, color: theme.colorScheme.primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(info.title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    info.path,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.textSecondary,
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    info.description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _StatusChip(label: status),
          ],
        ),
      ),
    );
  }
}

/// Small rounded status pill (e.g. "Scaffolded").
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.accent,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
