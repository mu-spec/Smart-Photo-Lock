import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_setup_screen.dart';

/// Phase 2B + 2C: PIN setup flow — length choice, entry, mandatory
/// confirmation, clean mismatch handling (re-confirm / start over) and
/// enrollment.
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

  /// Enters the PIN twice and reaches the success step.
  Future<void> enrollPin(WidgetTester tester, String pin) async {
    await tapDigits(tester, pin);
    await tapDigits(tester, pin);
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

    await enrollPin(tester, '246810');
    expect(find.text(PinSetupScreen.successTitle), findsOneWidget);

    final result =
        (await container.auth.authenticatePin('246810')).valueOrNull!;
    expect(result, isA<AuthSuccess>());
  });

  // -------------------------------------------------------------------
  // Phase 2C — confirmation & mismatch handling
  // -------------------------------------------------------------------
  testWidgets(
      'mismatched confirmation opens a dedicated state and saves nothing',
      (WidgetTester tester) async {
    final AppContainer container = await pumpHosted(tester);

    await tester.tap(find.text('4-digit PIN'));
    await tester.pumpAndSettle();

    await tapDigits(tester, '1234');
    await tapDigits(tester, '9999');

    // Dedicated mismatch state.
    expect(find.text(PinSetupScreen.mismatchTitle), findsOneWidget);
    expect(find.text(PinSetupScreen.mismatchMessage), findsOneWidget);
    expect(find.text(PinSetupScreen.reconfirmLabel), findsOneWidget);
    expect(find.text(PinSetupScreen.startOverLabel), findsOneWidget);

    // Error dots are rendered.
    final DsPinDots dots = tester.widget<DsPinDots>(find.byType(DsPinDots));
    expect(dots.error, isTrue);
    expect(dots.total, 4);

    // Nothing was enrolled — no partial credential.
    final state = (await container.auth.status()).valueOrNull!;
    expect(state.hasAnyCredential, isFalse);
  });

  testWidgets('Re-confirm keeps the first PIN and only re-asks confirmation',
      (WidgetTester tester) async {
    final AppContainer container = await pumpHosted(tester);

    await tester.tap(find.text('4-digit PIN'));
    await tester.pumpAndSettle();

    await tapDigits(tester, '1234');
    await tapDigits(tester, '9999'); // wrong confirmation
    expect(find.text(PinSetupScreen.mismatchTitle), findsOneWidget);

    // Re-confirm: only the confirmation step comes back.
    await tester.tap(find.text(PinSetupScreen.reconfirmLabel));
    await tester.pumpAndSettle();
    expect(find.text(PinSetupScreen.confirmPinTitle), findsOneWidget);

    await tapDigits(tester, '1234'); // correct this time
    expect(find.text(PinSetupScreen.successTitle), findsOneWidget);

    final result = (await container.auth.authenticatePin('1234')).valueOrNull!;
    expect(result, isA<AuthSuccess>());
  });

  testWidgets('repeated mismatch can be re-confirmed again',
      (WidgetTester tester) async {
    final AppContainer container = await pumpHosted(tester);

    await tester.tap(find.text('4-digit PIN'));
    await tester.pumpAndSettle();

    await tapDigits(tester, '1234');
    await tapDigits(tester, '9999');
    await tester.tap(find.text(PinSetupScreen.reconfirmLabel));
    await tester.pumpAndSettle();
    await tapDigits(tester, '8888'); // wrong again
    expect(find.text(PinSetupScreen.mismatchTitle), findsOneWidget);

    await tester.tap(find.text(PinSetupScreen.reconfirmLabel));
    await tester.pumpAndSettle();
    await tapDigits(tester, '1234'); // finally correct
    expect(find.text(PinSetupScreen.successTitle), findsOneWidget);

    final result = (await container.auth.authenticatePin('1234')).valueOrNull!;
    expect(result, isA<AuthSuccess>());
  });

  testWidgets('Start over clears everything and restarts at the first entry',
      (WidgetTester tester) async {
    final AppContainer container = await pumpHosted(tester);

    await tester.tap(find.text('4-digit PIN'));
    await tester.pumpAndSettle();

    await tapDigits(tester, '1234');
    await tapDigits(tester, '9999');
    expect(find.text(PinSetupScreen.mismatchTitle), findsOneWidget);

    await tester.tap(find.text(PinSetupScreen.startOverLabel));
    await tester.pumpAndSettle();
    expect(find.text(PinSetupScreen.enterPinTitle), findsOneWidget);

    // Both entries are required again.
    await enrollPin(tester, '4321');
    expect(find.text(PinSetupScreen.successTitle), findsOneWidget);

    // The start-over PIN (not the first attempt) is what got enrolled.
    final result = (await container.auth.authenticatePin('4321')).valueOrNull!;
    expect(result, isA<AuthSuccess>());
    final wrong =
        (await container.auth.authenticatePin('1234')).valueOrNull!;
    expect(wrong, isA<AuthFailure>());
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
