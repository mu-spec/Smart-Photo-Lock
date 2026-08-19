import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/design_system/design_system.dart';

/// Phase 2H: the draggable pattern grid — hit-testing, sequences,
/// completion, disabled and error states.
void main() {
  const double size = 280;

  Widget wrap({required Widget grid}) => MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Center(child: SizedBox(width: size, height: size, child: grid)),
        ),
      );

  // Node centers for a 280x280 grid (10% padding, two equal gaps).
  Offset centerOf(int node) {
    final int i = node - 1;
    return Offset(28 + (i % 3) * 112, 28 + (i ~/ 3) * 112);
  }

  Offset gridOrigin(WidgetTester tester) =>
      tester.getTopLeft(find.byType(DsPatternGrid));

  testWidgets('renders a grid whose painter knows all nodes',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(grid: DsPatternGrid(nodes: const <int>[1, 2, 3])),
    );
    final CustomPaint paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(DsPatternGrid),
        matching: find.byType(CustomPaint),
      ),
    );
    final PatternGridPainter painter =
        paint.painter! as PatternGridPainter;
    expect(painter.nodes, const <int>[1, 2, 3]);
  });

  testWidgets('dragging across nodes builds the sequence and ends cleanly',
      (WidgetTester tester) async {
    final List<List<int>> sequences = <List<int>>[];
    bool ended = false;
    await tester.pumpWidget(
      wrap(
        grid: DsPatternGrid(
          nodes: const <int>[],
          onNodeAdded: sequences.add,
          onDragEnd: () => ended = true,
        ),
      ),
    );

    final Offset origin = gridOrigin(tester);
    final TestGesture gesture =
        await tester.startGesture(origin + centerOf(1));
    await tester.pump();
    await gesture.moveTo(origin + centerOf(2));
    await tester.pump();
    await gesture.moveTo(origin + centerOf(3));
    await tester.pump();
    await gesture.moveTo(origin + centerOf(6));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(ended, isTrue);
    expect(sequences.last, const <int>[1, 2, 3, 6]);
  });

  testWidgets('a node cannot be visited twice in one stroke',
      (WidgetTester tester) async {
    final List<List<int>> sequences = <List<int>>[];
    await tester.pumpWidget(
      wrap(grid: DsPatternGrid(nodes: const <int>[], onNodeAdded: sequences.add)),
    );
    final Offset origin = gridOrigin(tester);
    final TestGesture gesture =
        await tester.startGesture(origin + centerOf(1));
    await tester.pump();
    await gesture.moveTo(origin + centerOf(2));
    await tester.pump();
    // Back to node 1: must be ignored (already selected).
    await gesture.moveTo(origin + centerOf(1));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(sequences.last, const <int>[1, 2]);
  });

  testWidgets('disabled grid ignores gestures', (WidgetTester tester) async {
    final List<List<int>> sequences = <List<int>>[];
    bool ended = false;
    await tester.pumpWidget(
      wrap(
        grid: DsPatternGrid(
          nodes: const <int>[],
          enabled: false,
          onNodeAdded: sequences.add,
          onDragEnd: () => ended = true,
        ),
      ),
    );
    final Offset origin = gridOrigin(tester);
    final TestGesture gesture =
        await tester.startGesture(origin + centerOf(1));
    await tester.pump();
    await gesture.moveTo(origin + centerOf(2));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(sequences, isEmpty);
    expect(ended, isFalse);
  });

  testWidgets('error state paints with the danger tone', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(grid: DsPatternGrid(nodes: const <int>[], error: true)),
    );
    final CustomPaint paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(DsPatternGrid),
        matching: find.byType(CustomPaint),
      ),
    );
    final PatternGridPainter painter =
        paint.painter! as PatternGridPainter;
    expect(painter.color, DsPalette.dark.danger);
  });

  testWidgets('showFeedback=false hides the drawing trail (Phase 2K)',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(
        grid: DsPatternGrid(
          nodes: const <int>[1, 2, 3],
          showFeedback: false,
        ),
      ),
    );
    final CustomPaint paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(DsPatternGrid),
        matching: find.byType(CustomPaint),
      ),
    );
    final PatternGridPainter painter =
        paint.painter! as PatternGridPainter;
    expect(painter.showFeedback, isFalse);
  });

  testWidgets('showFeedback defaults to true (visible)',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(grid: DsPatternGrid(nodes: const <int>[1, 2, 3])),
    );
    final CustomPaint paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(DsPatternGrid),
        matching: find.byType(CustomPaint),
      ),
    );
    final PatternGridPainter painter =
        paint.painter! as PatternGridPainter;
    expect(painter.showFeedback, isTrue);
  });

  test('nodeCenter geometry matches the 10% padding layout', () {
    const Size gridSize = Size(280, 280);
    expect(DsPatternGrid.nodeCenter(1, gridSize), const Offset(28, 28));
    expect(DsPatternGrid.nodeCenter(9, gridSize), const Offset(252, 252));
    expect(DsPatternGrid.nodeCenter(5, gridSize), const Offset(140, 140));
  });
}
