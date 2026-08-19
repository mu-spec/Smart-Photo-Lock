import 'package:flutter/material.dart';

import '../ds_context.dart';
import '../ds_palette.dart';
import '../ds_radii.dart';
import '../ds_spacing.dart';
import '../ds_tone.dart';
import 'security_level.dart';
import 'security_status_pill.dart';

/// A single protection row: tinted icon, title/subtitle, and a status pill.
///
/// Used on the Security tab for PIN, intruder selfie, stealth mode, ...
class SecurityStatusItem extends StatelessWidget {
  const SecurityStatusItem({
    super.key,
    required this.icon,
    required this.title,
    required this.level,
    this.subtitle,
    this.statusLabel,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final SecurityLevel level;

  /// Overrides the pill label (defaults to [SecurityLevel.label]).
  final String? statusLabel;

  /// Optional tap action (e.g. opening the unlock screen from a status row).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final DsPalette palette = context.dsColors;
    final ThemeData theme = Theme.of(context);
    final Color toneColor = level.tone.colorOf(palette);

    final Widget content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: DsSpacing.lg, vertical: DsSpacing.sm + 2),
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: toneColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(DsRadii.md),
            ),
            child: Icon(icon, size: 20, color: toneColor),
          ),
          const SizedBox(width: DsSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: palette.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: DsSpacing.sm),
          SecurityStatusPill(level: level, label: statusLabel),
        ],
      ),
    );

    final VoidCallback? onTap = this.onTap;
    if (onTap == null) {
      return content;
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DsRadii.md),
      child: content,
    );
  }
}
