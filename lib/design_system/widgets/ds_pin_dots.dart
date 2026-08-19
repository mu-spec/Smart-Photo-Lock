import 'package:flutter/material.dart';

import '../ds_context.dart';
import '../ds_palette.dart';

/// Animated PIN-entry dots: one circle per target digit, filled as the user
/// types. Used by both the setup flow and (later) the unlock screen.
class DsPinDots extends StatelessWidget {
  const DsPinDots({
    super.key,
    required this.filled,
    required this.total,
    this.error = false,
    this.dotSize = 16,
    this.dotSpacing = 16,
  });

  /// Number of entered digits (0..[total]).
  final int filled;

  /// Target PIN length (4 or 6).
  final int total;

  /// Danger tint for failed attempts.
  final bool error;

  final double dotSize;
  final double dotSpacing;

  @override
  Widget build(BuildContext context) {
    final DsPalette palette = context.dsColors;
    final Color fillColor = error ? palette.danger : palette.primary;
    final Color emptyColor = error
        ? palette.danger.withValues(alpha: 0.5)
        : palette.border;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < total; i++) ...<Widget>[
          if (i > 0) SizedBox(width: dotSpacing),
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < filled ? fillColor : Colors.transparent,
              border: Border.all(
                color: i < filled ? fillColor : emptyColor,
                width: 2,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
