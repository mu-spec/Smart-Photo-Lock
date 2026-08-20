import 'package:flutter/material.dart';

import '../ds_context.dart';
import '../ds_palette.dart';

/// A tiny attention dot used on icons/titles (e.g. an unresolved
/// capability problem). Shows only when [show] is true.
class DsDotBadge extends StatelessWidget {
  const DsDotBadge({
    super.key,
    required this.show,
    this.color,
    this.size = 10,
  });

  final bool show;

  /// Badge color; defaults to the palette danger tone.
  final Color? color;

  final double size;

  @override
  Widget build(BuildContext context) {
    if (!show) {
      return const SizedBox.shrink();
    }
    final DsPalette palette = context.dsColors;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color ?? palette.danger,
        shape: BoxShape.circle,
        border: Border.all(color: palette.background, width: 1.5),
      ),
    );
  }
}
