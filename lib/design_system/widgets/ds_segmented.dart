import 'package:flutter/material.dart';

import '../ds_context.dart';
import '../ds_palette.dart';

/// One option of a [DsSegmented] filter.
class DsSegment<T> {
  const DsSegment({required this.value, required this.label});

  final T value;
  final String label;
}

/// Generic single-select segmented control (Phase 3D).
///
/// Wraps Material 3's [SegmentedButton] with the design-system palette so
/// screens never style raw Material components themselves. Used by the
/// Apps tab filters (All / Protected / Unprotected) and reusable for
/// future filter bars.
class DsSegmented<T> extends StatelessWidget {
  const DsSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelected,
  });

  final List<DsSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final DsPalette palette = context.dsColors;
    return SegmentedButton<T>(
      showSelectedIcon: false,
      segments: <ButtonSegment<T>>[
        for (final DsSegment<T> segment in segments)
          ButtonSegment<T>(
            value: segment.value,
            label: Text(segment.label),
          ),
      ],
      selected: <T>{selected},
      onSelectionChanged: (Set<T> selection) => onSelected(selection.first),
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        backgroundColor: WidgetStateProperty.resolveWith<Color?>(
          (Set<WidgetState> states) =>
              states.contains(WidgetState.selected)
                  ? palette.primary.withValues(alpha: 0.16)
                  : palette.surface,
        ),
        foregroundColor: WidgetStateProperty.resolveWith<Color?>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? palette.primary
              : palette.textSecondary,
        ),
        side: WidgetStatePropertyAll<BorderSide>(
          BorderSide(color: palette.border.withValues(alpha: 0.6)),
        ),
        textStyle: WidgetStatePropertyAll<TextStyle>(
          TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
