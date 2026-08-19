import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/design_system/design_system.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(body: Center(child: child)),
      );

  BoxDecoration? decorationOf(WidgetTester tester, int index) =>
      tester
          .widget<AnimatedContainer>(
            find.byType(AnimatedContainer).at(index),
          )
          .decoration as BoxDecoration?;

  group('DsPinDots', () {
    testWidgets('renders one dot per target digit', (WidgetTester tester) async {
      await tester.pumpWidget(wrap(const DsPinDots(filled: 0, total: 6)));
      expect(find.byType(AnimatedContainer), findsNWidgets(6));
    });

    testWidgets('filled dots use the accent color, empty dots are hollow',
        (WidgetTester tester) async {
      await tester.pumpWidget(wrap(const DsPinDots(filled: 2, total: 4)));

      final Color filled = (decorationOf(tester, 0)!).color!;
      final Color empty = (decorationOf(tester, 2)!).color!;
      expect(filled, DsPalette.dark.primary);
      expect(empty, Colors.transparent);
      // Hollow dots still draw a border.
      expect(decorationOf(tester, 2)!.border, isNotNull);
    });

    testWidgets('error state paints the filled dot in the danger tone',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(const DsPinDots(filled: 1, total: 4, error: true)),
      );
      final Color filled = (decorationOf(tester, 0)!).color!;
      expect(filled, DsPalette.dark.danger);
    });

    testWidgets('filled cannot exceed total (defensive rendering)',
        (WidgetTester tester) async {
      // Even with bad input, only `total` dots exist.
      await tester.pumpWidget(wrap(const DsPinDots(filled: 9, total: 4)));
      expect(find.byType(AnimatedContainer), findsNWidgets(4));
    });
  });
}
