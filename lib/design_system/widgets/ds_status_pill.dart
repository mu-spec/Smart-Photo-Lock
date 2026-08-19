import 'package:flutter/material.dart';

import '../ds_context.dart';
import '../ds_palette.dart';
import '../ds_radii.dart';
import '../ds_tone.dart';

/// Small rounded status pill with a tone-colored dot.
///
/// Generic primitive; the security-specific wrapper
/// ([SecurityStatusPill]) maps [SecurityLevel] onto it.
class DsStatusPill extends StatelessWidget {
  const DsStatusPill({
    super.key,
    required this.label,
    this.tone = DsTone.neutral,
    this.showDot = true,
  });

  final String label;
  final DsTone tone;
  final bool showDot;

  @override
  Widget build(BuildContext context) {
    final DsPalette palette = context.dsColors;
    final Color color = tone.colorOf(palette);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(DsRadii.pill),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (showDot) ...<Widget>[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
