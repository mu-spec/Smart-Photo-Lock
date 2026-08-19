import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/design_system/design_system.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(body: Center(child: child)),
      );

  group('DsPinPad', () {
    testWidgets('renders all ten digit keys', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(DsPinPad(onDigit: (_) {}, onDelete: () {})),
      );
      for (int d = 0; d <= 9; d++) {
        expect(find.byKey(Key('pin_key_$d')), findsOneWidget);
      }
      expect(find.byKey(const Key('pin_key_backspace')), findsOneWidget);
      // No biometric slot by default.
      expect(find.byKey(const Key('pin_key_biometric')), findsNothing);
    });

    testWidgets('digit taps fire the callback with the digit',
        (WidgetTester tester) async {
      final List<String> tapped = <String>[];
      await tester.pumpWidget(
        wrap(DsPinPad(onDigit: tapped.add, onDelete: () {})),
      );
      await tester.tap(find.byKey(const Key('pin_key_5')));
      await tester.tap(find.byKey(const Key('pin_key_0')));
      expect(tapped, <String>['5', '0']);
    });

    testWidgets('backspace fires onDelete; long-press fires onDeleteAll only',
        (WidgetTester tester) async {
      int deletes = 0;
      int clears = 0;
      await tester.pumpWidget(
        wrap(
          DsPinPad(
            onDigit: (_) {},
            onDelete: () => deletes++,
            onDeleteAll: () => clears++,
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('pin_key_backspace')));
      expect(deletes, 1);
      expect(clears, 0);

      await tester.longPress(find.byKey(const Key('pin_key_backspace')));
      expect(deletes, 1); // long-press must not also fire the tap
      expect(clears, 1);
    });

    testWidgets('biometric slot shows only when enabled and fires its callback',
        (WidgetTester tester) async {
      int bioTaps = 0;
      await tester.pumpWidget(
        wrap(
          DsPinPad(
            onDigit: (_) {},
            onDelete: () {},
            showBiometric: true,
            onBiometric: () => bioTaps++,
          ),
        ),
      );
      expect(find.byKey(const Key('pin_key_biometric')), findsOneWidget);
      expect(find.byIcon(Icons.fingerprint), findsOneWidget);

      await tester.tap(find.byKey(const Key('pin_key_biometric')));
      expect(bioTaps, 1);
    });

    testWidgets('disabled pad ignores all input', (WidgetTester tester) async {
      final List<String> tapped = <String>[];
      int deletes = 0;
      await tester.pumpWidget(
        wrap(
          DsPinPad(
            onDigit: tapped.add,
            onDelete: () => deletes++,
            enabled: false,
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('pin_key_3')));
      await tester.tap(find.byKey(const Key('pin_key_backspace')));
      expect(tapped, isEmpty);
      expect(deletes, 0);
    });
  });
}
