import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/design_system/design_system.dart';

void main() {
  Widget wrap(Widget child) =>
      MaterialApp(theme: AppTheme.dark, home: Scaffold(body: child));

  group('DsTextField', () {
    testWidgets('renders label, hint and helper text', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(
          const DsTextField(
            label: 'PIN',
            hint: 'Enter your PIN',
            helperText: 'At least 4 digits',
          ),
        ),
      );
      expect(find.text('PIN'), findsOneWidget);
      expect(find.text('Enter your PIN'), findsOneWidget);
      expect(find.text('At least 4 digits'), findsOneWidget);
    });

    testWidgets('password visibility toggles', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(const DsTextField(label: 'PIN', obscureText: true)),
      );
      // TextFormField builds an EditableText internally; obscureText is
      // exposed there (current Flutter API).
      EditableText editable() =>
          tester.widget<EditableText>(find.byType(EditableText));
      expect(editable().obscureText, isTrue);

      await tester.tap(find.byIcon(Icons.visibility_outlined));
      await tester.pump();
      expect(editable().obscureText, isFalse);

      await tester.tap(find.byIcon(Icons.visibility_off_outlined));
      await tester.pump();
      expect(editable().obscureText, isTrue);
    });

    testWidgets('validator errors show inside a Form', (WidgetTester tester) async {
      final GlobalKey<FormState> formKey = GlobalKey<FormState>();
      await tester.pumpWidget(
        wrap(
          Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                DsTextField(
                  label: 'PIN',
                  validator: (String? v) =>
                      (v == null || v.isEmpty) ? 'PIN is required' : null,
                ),
                DsButton(
                  label: 'Submit',
                  onPressed: () => formKey.currentState!.validate(),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Submit'));
      await tester.pump();
      expect(find.text('PIN is required'), findsOneWidget);
    });

    testWidgets('direct errorText renders without a Form', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(const DsTextField(label: 'PIN', errorText: 'Too short')),
      );
      expect(find.text('Too short'), findsOneWidget);
    });

    testWidgets('entered text reaches the controller', (WidgetTester tester) async {
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        wrap(DsTextField(controller: controller, label: 'PIN')),
      );
      await tester.enterText(find.byType(TextFormField), '1234');
      expect(controller.text, '1234');
    });
  });
}
