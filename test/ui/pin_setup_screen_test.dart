import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_setup_screen.dart';

/// Phase 2B: PIN setup flow — length choice, entry, confirmation,
/// enrollment, mismatch handling and navigation result.
void main() {
  /// Pumps the setup screen inside an [AppScope] with an in-memory
  /// container, hosted by a page that can push it (so pops are testable).
  Future<AppContainer> pumpHosted(
    WidgetTester tester, {
    int? initialLength,
  }) async {
    final AppContainer container = AppContainer.inMemory();
    await tester.pumpWidget(
      AppScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: TextButton(
                  key: const Key('open_pin_setup'),
                  onPressed: () => Navigator.of(context).push<bool>(
                    MaterialPageRoute<bool>(
                      builder: (_) =>
                          PinSetupScreen(initialLength: initialLength),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open_pin_setup')));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> tapDigits(WidgetTester tester, String digits) async {
    for (final String d in digits.split('')) {
      await tester.tap(find.byKey(Key('pin_key_$d')));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('length step offers both options and advances on tap',
      (WidgetTester tester) async {
    await pumpHosted(tester);

    expect(find.text(PinSetupScreen.chooseLengthTitle), findsOneWidget);
    expect(find.text('4-digit PIN'), findsOneWidget);
    expect(find.text('6-digit PIN'), findsOneWidget);

    await tester.tap(find.text('4-digit PIN'));
    await tester.pumpAndSettle();
    expect(find.text(PinSetupScreen.enterPinTitle), findsOneWidget);
    expect(find.text('Enter your new 4-digit PIN'), findsOneWidget);
  });

  testWidgets('full 4-digit happy path enrolls the PIN and pops with true',
      (WidgetTester tester) async {
    final AppContainer container = await pumpHosted(tester);

    await tester.tap(find.text('4-digit PIN'));
    await tester.pumpAndSettle();

    await tapDigits(tester, '1234');
    expect(find.text(PinSetupScreen.confirmPinTitle), findsOneWidget);

    await tapDigits(tester, '1234');
    expect(find.text(PinSetupScreen.successTitle), findsOneWidget);

    // Credential really enrolled.
    final state = (await container.auth.status()).valueOrNull!;
    expect(state.hasEnrolled(AuthType.pin), isTrue);
    final result = (await container.auth.authenticatePin('1234')).valueOrNull!;
    expect(result, isA<AuthSuccess>());

    // Done pops back to the host.
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open_pin_setup')), findsOneWidget);
  });

  testWidgets('full 6-digit happy path works', (WidgetTester tester) async {
    final AppContainer container = await pumpHosted(tester);

    await tester.tap(find.text('6-digit PIN'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your new 6-digit PIN'), findsOneWidget);

    await tapDigits(tester, '246810');
    expect(find.text(PinSetupScreen.confirmPinTitle), findsOneWidget);

    await tapDigits(tester, '246810');
    expect(find.text(PinSetupScreen.successTitle), findsOneWidget);

    final result =
        (await container.auth.authenticatePin('246810')).valueOrNull!;
    expect(result, isA<AuthSuccess>());
  });

  testWidgets('mismatch shows the error banner and restarts entry',
      (WidgetTester tester) async {
    final AppContainer container = await pumpHosted(tester);

    await tester.tap(find.text('4-digit PIN'));
    await tester.pumpAndSettle();

    await tapDigits(tester, '1234');
    await tapDigits(tester, '9999');

    expect(find.text(PinSetupScreen.mismatchMessage), findsOneWidget);
    expect(find.text(PinSetupScreen.enterPinTitle), findsOneWidget);

    // Recover: enter the PIN correctly twice.
    await tapDigits(tester, '1234');
    await tapDigits(tester, '1234');
    expect(find.text(PinSetupScreen.successTitle), findsOneWidget);

    final result = (await container.auth.authenticatePin('1234')).valueOrNull!;
    expect(result, isA<AuthSuccess>());
  });

  testWidgets('backspace removes one digit; long-press clears all',
      (WidgetTester tester) async {
    await pumpHosted(tester);

    await tester.tap(find.text('4-digit PIN'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('pin_key_1')));
    await tester.tap(find.byKey(const Key('pin_key_2')));
    await tester.pump();
    expect(tester.widget<DsPinDots>(find.byType(DsPinDots)).filled, 2);

    await tester.tap(find.byKey(const Key('pin_key_backspace')));
    await tester.pump();
    expect(tester.widget<DsPinDots>(find.byType(DsPinDots)).filled, 1);

    await tester.longPress(find.byKey(const Key('pin_key_backspace')));
    await tester.pump();
    expect(tester.widget<DsPinDots>(find.byType(DsPinDots)).filled, 0);
  });

  testWidgets('initialLength skips the length step', (WidgetTester tester) async {
    await pumpHosted(tester, initialLength: 6);

    expect(find.text(PinSetupScreen.chooseLengthTitle), findsNothing);
    expect(find.text(PinSetupScreen.enterPinTitle), findsOneWidget);
    expect(find.text('Enter your new 6-digit PIN'), findsOneWidget);
  });

  testWidgets('change length returns to the choice step',
      (WidgetTester tester) async {
    await pumpHosted(tester);

    await tester.tap(find.text('6-digit PIN'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change PIN length'));
    await tester.pumpAndSettle();

    expect(find.text(PinSetupScreen.chooseLengthTitle), findsOneWidget);
  });
}
