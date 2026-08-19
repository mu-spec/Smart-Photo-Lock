import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../ds_context.dart';
import '../ds_palette.dart';

/// Draggable 3x3 unlock-pattern grid (Phase 2H).
///
/// Nodes are numbered row-major 1-9, matching `PatternCodec` in the
/// security module. The widget is **controlled**: the parent owns the
/// selected sequence ([nodes]) and updates it via [onNodeAdded] while the
/// user drags; [onDragEnd] fires when the pointer lifts so the parent can
/// validate/confirm the completed shape.
class DsPatternGrid extends StatelessWidget {
  const DsPatternGrid({
    super.key,
    required this.nodes,
    this.onNodeAdded,
    this.onDragEnd,
    this.enabled = true,
    this.error = false,
    this.nodeRadius = 17,
    this.showFeedback = true,
  });

  /// Current selected node sequence (values 1-9).
  final List<int> nodes;

  /// Fired with the new sequence each time the drag reaches a new node.
  final ValueChanged<List<int>>? onNodeAdded;

  /// Fired when the pointer lifts with the completed sequence.
  final VoidCallback? onDragEnd;

  /// When false, gestures are ignored.
  final bool enabled;

  /// Danger tint for the mismatch/error state.
  final bool error;

  /// Visual radius of a single node.
  final double nodeRadius;

  /// Draws the connecting trail and fills selected nodes (Phase 2K).
  /// When false, only the node rings are shown — the drawing itself stays
  /// invisible (anti-shoulder-surfing), while gestures work identically.
  final bool showFeedback;

  /// Grid geometry: nodes sit at 10% padding with two equal gaps.
  static Offset nodeCenter(int node, Size size) {
    final double p = size.shortestSide * 0.10;
    final double step = (size.shortestSide - 2 * p) / 2;
    final int i = node - 1;
    return Offset(p + (i % 3) * step, p + (i ~/ 3) * step);
  }

  int? _hitNode(Offset position, Size size) {
    for (int node = 1; node <= 9; node++) {
      if ((position - nodeCenter(node, size)).distance <= nodeRadius * 1.6) {
        return node;
      }
    }
    return null;
  }

  void _handle(BuildContext context, Offset localPosition) {
    if (!enabled || onNodeAdded == null) {
      return;
    }
    final Size? size = context.size;
    if (size == null) {
      return;
    }
    final int? hit = _hitNode(localPosition, size);
    if (hit == null || nodes.contains(hit)) {
      return;
    }
    onNodeAdded!(<int>[...nodes, hit]);
  }

  @override
  Widget build(BuildContext context) {
    final DsPalette palette = context.dsColors;
    final Color color = error ? palette.danger : palette.primary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanDown: enabled ? (DragDownDetails d) => _handle(context, d.localPosition) : null,
      onPanUpdate:
          enabled ? (DragUpdateDetails d) => _handle(context, d.localPosition) : null,
      onPanEnd: enabled ? (DragEndDetails _) => onDragEnd?.call() : null,
      child: CustomPaint(
        size: Size.infinite,
        painter: PatternGridPainter(
          nodes: nodes,
          color: color,
          nodeRadius: nodeRadius,
          showFeedback: showFeedback,
        ),
      ),
    );
  }
}

/// Paints the grid: soft halos, rings, and the connecting path between
/// selected nodes. Exposed publicly so tests can assert its state.
class PatternGridPainter extends CustomPainter {
  PatternGridPainter({
    required this.nodes,
    required this.color,
    required this.nodeRadius,
    this.lineWidth = 3,
    this.showFeedback = true,
  });

  final List<int> nodes;
  final Color color;
  final double nodeRadius;
  final double lineWidth;

  /// See [DsPatternGrid.showFeedback].
  final bool showFeedback;

  @override
  void paint(Canvas canvas, Size size) {
    // Connecting path between consecutive selected nodes (hidden when
    // feedback is disabled).
    if (showFeedback && nodes.length >= 2) {
      final Paint line = Paint()
        ..color = color.withValues(alpha: 0.85)
        ..strokeWidth = lineWidth
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      final Path path = Path();
      final Offset first = DsPatternGrid.nodeCenter(nodes.first, size);
      path.moveTo(first.dx, first.dy);
      for (final int node in nodes.skip(1)) {
        final Offset c = DsPatternGrid.nodeCenter(node, size);
        path.lineTo(c.dx, c.dy);
      }
      canvas.drawPath(path, line);
    }

    final Paint halo = Paint()
      ..style = PaintingStyle.fill
      ..color = color.withValues(alpha: 0.22);
    final Paint ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = color.withValues(alpha: 0.65);
    final Paint core = Paint()
      ..style = PaintingStyle.fill
      ..color = color;

    for (int node = 1; node <= 9; node++) {
      final Offset c = DsPatternGrid.nodeCenter(node, size);
      canvas.drawCircle(c, nodeRadius, halo);
      canvas.drawCircle(c, nodeRadius, ring);
      if (showFeedback && nodes.contains(node)) {
        canvas.drawCircle(c, nodeRadius * 0.45, core);
      }
    }
  }

  @override
  bool shouldRepaint(covariant PatternGridPainter oldDelegate) =>
      !listEquals(oldDelegate.nodes, nodes) ||
      oldDelegate.color != color ||
      oldDelegate.nodeRadius != nodeRadius ||
      oldDelegate.lineWidth != lineWidth ||
      oldDelegate.showFeedback != showFeedback;
}
