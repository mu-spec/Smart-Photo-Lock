import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/design_system/design_system.dart';

void main() {
  Widget wrap(Widget child) =>
      MaterialApp(theme: AppTheme.dark, home: Scaffold(body: Center(child: child)));

  group('DsButton', () {
    testWidgets('renders its label and fires onPressed', (WidgetTester tester) async {
      bool pressed = false;
      await tester.pumpWidget(
        wrap(DsButton(label: 'Unlock', onPressed: () => pressed = true)),
      );
      expect(find.text('Unlock'), findsOneWidget);
      await tester.tap(find.text('Unlock'));
      expect(pressed, isTrue);
    });

    testWidgets('loading state shows a spinner and blocks taps',
        (WidgetTester tester) async {
      bool pressed = false;
      await tester.pumpWidget(
        wrap(DsButton(label: 'Save', loading: true, onPressed: () => pressed = true)),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.text('Save'));
      expect(pressed, isFalse);
    });

    testWidgets('every variant maps to the right Material button',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              DsButton(label: 'Primary', onPressed: () {}),
              DsButton(label: 'Secondary', variant: DsButtonVariant.secondary, onPressed: () {}),
              DsButton(label: 'Outline', variant: DsButtonVariant.outline, onPressed: () {}),
              DsButton(label: 'Ghost', variant: DsButtonVariant.ghost, onPressed: () {}),
              DsButton(label: 'Danger', variant: DsButtonVariant.danger, onPressed: () {}),
            ],
          ),
        ),
      );
      // primary + secondary (tonal) + danger are FilledButtons.
      expect(find.byType(FilledButton), findsNWidgets(3));
      expect(find.byType(OutlinedButton), findsOneWidget);
      expect(find.byType(TextButton), findsOneWidget);
    });

    testWidgets('renders a leading icon', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(DsButton(label: 'Lock', icon: Icons.lock_outline, onPressed: () {})),
      );
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });

    testWidgets('disabled button does not fire', (WidgetTester tester) async {
      bool pressed = false;
      await tester.pumpWidget(
        wrap(DsButton(label: 'Disabled', onPressed: null)),
      );
      await tester.tap(find.text('Disabled'));
      expect(pressed, isFalse);
    });
  });
}
