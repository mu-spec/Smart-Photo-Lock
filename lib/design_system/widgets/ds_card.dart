import 'package:flutter/material.dart';

import '../ds_context.dart';
import '../ds_palette.dart';
import '../ds_radii.dart';
import '../ds_spacing.dart';

/// The app's card — optional header (title/subtitle/trailing), optional
/// tap ripple, and free-form content.
class DsCard extends StatelessWidget {
  const DsCard({
    super.key,
    this.title,
    this.subtitle,
    this.trailing,
    this.child,
    this.onTap,
    this.padding = DsInsets.card,
    this.margin = EdgeInsets.zero,
    this.color,
    this.showBorder = true,
  });

  final String? title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final Color? color;
  final bool showBorder;

  @override
  Widget build(BuildContext context) {
    final DsPalette palette = context.dsColors;
    final ThemeData theme = Theme.of(context);
    const BorderRadius radius = BorderRadius.all(Radius.circular(DsRadii.lg));

    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: color ?? palette.surface,
        borderRadius: radius,
        border: showBorder
            ? Border.all(color: palette.border.withValues(alpha: 0.6))
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Padding(
            padding: padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (title != null) ...<Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          title!,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (trailing != null) trailing!,
                    ],
                  ),
                  if (subtitle != null) ...<Widget>[
                    const SizedBox(height: DsSpacing.xs),
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: palette.textSecondary,
                      ),
                    ),
                  ],
                  if (child != null) const SizedBox(height: DsSpacing.md),
                ],
                if (child != null) child!,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
