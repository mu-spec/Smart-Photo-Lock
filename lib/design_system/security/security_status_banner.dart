import 'package:flutter/material.dart';

import '../ds_context.dart';
import '../ds_palette.dart';
import '../ds_radii.dart';
import '../ds_spacing.dart';
import '../ds_tone.dart';
import '../widgets/ds_button.dart';
import 'security_level.dart';

/// Large callout showing the overall security posture, with an optional
/// primary action (e.g. "Set up PIN").
class SecurityStatusBanner extends StatelessWidget {
  const SecurityStatusBanner({
    super.key,
    required this.level,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.footer,
  });

  final SecurityLevel level;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Optional extra line rendered under the message (e.g. a readiness
  /// count such as "2 of 3 ready").
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final DsPalette palette = context.dsColors;
    final ThemeData theme = Theme.of(context);
    final Color toneColor = level.tone.colorOf(palette);

    return Container(
      padding: const EdgeInsets.all(DsSpacing.lg),
      decoration: BoxDecoration(
        color: toneColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(DsRadii.xl),
        border: Border.all(color: toneColor.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: toneColor.withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
            child: Icon(level.icon, size: 26, color: toneColor),
          ),
          const SizedBox(width: DsSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: DsSpacing.xs),
                Text(
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.textSecondary,
                  ),
                ),
                if (footer != null) ...<Widget>[
                  const SizedBox(height: DsSpacing.sm),
                  footer!,
                ],
                if (actionLabel != null) ...<Widget>[
                  const SizedBox(height: DsSpacing.md),
                  DsButton(
                    label: actionLabel!,
                    size: DsButtonSize.small,
                    variant: level == SecurityLevel.atRisk ||
                            level == SecurityLevel.vulnerable
                        ? DsButtonVariant.primary
                        : DsButtonVariant.outline,
                    onPressed: onAction,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
