import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/credential_state_machine.dart';
import 'package:smart_app_lock/security/credentials/impl/default_credential_manager.dart';
import 'package:smart_app_lock/security/credentials/pattern_hasher.dart';
import 'package:smart_app_lock/security/pin_hasher.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_change_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_setup_screen.dart';

/// Phase 2K: change-PIN flow — verify current PIN, then set a new one.
void main() {
  late DefaultCredentialManager manager;
  late List<Object?> results;

  setUp(() {
    manager = DefaultCredentialManager(
      settings: AppContainer.inMemory().securitySettings,
      pinHasher: Pbkdf2PinHasher(iterations: 200),
      patternHasher: Pbkdf2PatternHasher(iterations: 200),
      stateMachine: const CredentialStateMachine(
        maxFailedAttempts: 3,
        lockoutDuration: Duration(seconds: 30),
      ),
    );
  });

  Future<void> pumpHosted(WidgetTester tester) async {
    results = <Object?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const Key('open_change'),
                onPressed: () async {
                  final Object? res = await Navigator.of(context)
                      .push<Object?>(MaterialPageRoute<Object?>(
                    builder: (_) =>
                        PinChangeScreen(credentialManager: manager),
                  ));
                  results.add(res);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open_change')));
    await tester.pumpAndSettle();
  }

  Future<void> tapDigits(WidgetTester tester, String digits) async {
    for (final String d in digits.split('')) {
      await tester.tap(find.byKey(Key('pin_key_$d')));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('verifies the current PIN before allowing a change',
      (WidgetTester tester) async {
    await manager.enrollPin('1234');
    await pumpHosted(tester);

    // Step 1: current-PIN verification.
    expect(find.text(PinChangeScreen.verifyTitle), findsOneWidget);

    // Wrong PIN: stays on verify with an error.
    await tapDigits(tester, '9999');
    expect(find.textContaining('Incorrect PIN'), findsOneWidget);
    expect(find.text(PinChangeScreen.verifyTitle), findsOneWidget);

    // Correct PIN: moves to the new-PIN setup.
    await tapDigits(tester, '1234');
    await tester.pumpAndSettle();
    expect(find.text(PinChangeScreen.setupTitle), findsOneWidget);
    expect(find.text('Enter your new 4-digit PIN'), findsOneWidget);
  });

  testWidgets('full change flow: old PIN stops working, new one works',
      (WidgetTester tester) async {
    await manager.enrollPin('1234');
    await pumpHosted(tester);

    await tapDigits(tester, '1234'); // verify current
    await tester.pumpAndSettle();

    await tapDigits(tester, '5678'); // new PIN
    await tester.pumpAndSettle();
    expect(find.text(PinSetupScreen.confirmPinTitle), findsOneWidget);

    await tapDigits(tester, '5678'); // confirm
    await tester.pumpAndSettle();
    expect(find.text(PinSetupScreen.successTitle), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // The change screen pops with true.
    expect(find.byKey(const Key('open_change')), findsOneWidget);
    expect(results.last, true);

    // Old PIN rejected, new PIN accepted.
    expect((await manager.authenticatePin('1234')).valueOrNull,
        isA<AuthFailure>());
    expect((await manager.authenticatePin('5678')).valueOrNull,
        isA<AuthSuccess>());
  });

  testWidgets('cancelling the verification cancels the change',
      (WidgetTester tester) async {
    await manager.enrollPin('1234');
    await pumpHosted(tester);

    expect(find.text(PinChangeScreen.verifyTitle), findsOneWidget);
    // App-bar back on the verify screen.
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('open_change')), findsOneWidget);
    expect(results.last, false);

    // PIN untouched.
    expect((await manager.authenticatePin('1234')).valueOrNull,
        isA<AuthSuccess>());
  });

  testWidgets('falls through to initial setup when no PIN is enrolled',
      (WidgetTester tester) async {
    await pumpHosted(tester);

    // No verification step — straight to setup.
    expect(find.text(PinSetupScreen.chooseLengthTitle), findsOneWidget);
  });
}
