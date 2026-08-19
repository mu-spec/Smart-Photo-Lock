import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/credential_state_machine.dart';
import 'package:smart_app_lock/security/credentials/impl/default_credential_manager.dart';
import 'package:smart_app_lock/security/credentials/pattern_hasher.dart';
import 'package:smart_app_lock/security/pin_hasher.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_change_screen.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_setup_screen.dart';

/// Phase 2K: change-pattern flow — verify the current pattern, then draw
/// and confirm a new one.
void main() {
  late DefaultCredentialManager manager;
  late List<Object?> results;

  setUp(() {
    manager = DefaultCredentialManager(
      settings: AppContainer.inMemory().securitySettings,
      pinHasher: Pbkdf2PinHasher(iterations: 200),
      patternHasher: Pbkdf2PatternHasher(iterations: 200),
      stateMachine: CredentialStateMachine(
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
                        PatternChangeScreen(credentialManager: manager),
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

  Future<void> drawPattern(WidgetTester tester, List<int> nodes) async {
    // Settle any pending step/view transition so exactly one grid is
    // mounted (getRect throws when the switcher still holds two).
    await tester.pump(const Duration(milliseconds: 300));
    final Finder gridFinder = find.byType(DsPatternGrid);
    expect(gridFinder, findsOneWidget);
    final Rect bounds = tester.getRect(gridFinder);

    // Node centers computed from the RENDERED bounds (10% padding, two
    // equal gaps) — no hardcoded coordinates, matching the painter.
    final double pad = bounds.width * 0.10;
    final double step = (bounds.width - 2 * pad) / 2;
    Offset center(int node) {
      final int i = node - 1;
      return Offset(
        bounds.left + pad + (i % 3) * step,
        bounds.top + pad + (i ~/ 3) * step,
      );
    }

    final TestGesture gesture =
        await tester.startGesture(center(nodes.first));
    await tester.pump();
    // Win the gesture arena from the enclosing scrollable with a small
    // HORIZONTAL movement (the scrollable's vertical drag rejects it,
    // the grid's pan accepts it) before any vertical leg is drawn.
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();

    Offset current = center(nodes.first).translate(20, 0);
    for (final int node in nodes.skip(1)) {
      // Micro-step toward each node so the recognizer sees a continuous,
      // device-like stroke and every hit test lands.
      final Offset target = center(node);
      const int steps = 6;
      for (int s = 1; s <= steps; s++) {
        final Offset next = Offset(
          current.dx + (target.dx - current.dx) * s / steps,
          current.dy + (target.dy - current.dy) * s / steps,
        );
        await gesture.moveTo(next);
        await tester.pump();
      }
      current = target;
    }
    await gesture.up();
    await tester.pump();
    // Let async verification/enrollment (PBKDF2 + encrypted settings) and
    // step transitions finish.
    await tester.pump(const Duration(milliseconds: 700));
  }

  testWidgets('verifies the current pattern before allowing a change',
      (WidgetTester tester) async {
    await manager.enrollPattern(const <int>[1, 2, 3, 6]);
    await pumpHosted(tester);

    // Step 1: current-pattern verification.
    expect(find.text(PatternChangeScreen.verifyTitle), findsOneWidget);

    // Wrong pattern: stays on verify with an error.
    await drawPattern(tester, const <int>[1, 2, 3, 5]);
    expect(find.textContaining('Incorrect pattern'), findsOneWidget);
    expect(find.text(PatternChangeScreen.verifyTitle), findsOneWidget);

    // Correct pattern: the exact ordered sequence.
    await drawPattern(tester, const <int>[1, 2, 3, 6]);
    await tester.pumpAndSettle();
    expect(find.text(PatternChangeScreen.setupTitle), findsOneWidget);
  });

  testWidgets('full change flow: old pattern stops working, new one works',
      (WidgetTester tester) async {
    await manager.enrollPattern(const <int>[1, 2, 3, 6]);
    await pumpHosted(tester);

    await drawPattern(tester, const <int>[1, 2, 3, 6]); // verify current
    await tester.pumpAndSettle();

    expect(find.text(PatternChangeScreen.setupTitle), findsOneWidget);
    await drawPattern(tester, const <int>[1, 4, 7, 8]); // new pattern
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text(PatternSetupScreen.confirmTitle), findsOneWidget);

    await drawPattern(tester, const <int>[1, 4, 7, 8]); // confirm
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text(PatternSetupScreen.successTitle), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // The change screen pops with true.
    expect(find.byKey(const Key('open_change')), findsOneWidget);
    expect(results.last, true);

    // Old pattern rejected, new pattern accepted.
    expect(
      (await manager.authenticatePattern(const <int>[1, 2, 3, 6]))
          .valueOrNull,
      isA<AuthFailure>(),
    );
    expect(
      (await manager.authenticatePattern(const <int>[1, 4, 7, 8]))
          .valueOrNull,
      isA<AuthSuccess>(),
    );
  });

  testWidgets('cancelling the verification cancels the change',
      (WidgetTester tester) async {
    await manager.enrollPattern(const <int>[1, 2, 3, 6]);
    await pumpHosted(tester);

    expect(find.text(PatternChangeScreen.verifyTitle), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('open_change')), findsOneWidget);
    expect(results.last, false);

    // Pattern untouched.
    expect(
      (await manager.authenticatePattern(const <int>[1, 2, 3, 6]))
          .valueOrNull,
      isA<AuthSuccess>(),
    );
  });

  testWidgets('falls through to initial setup when no pattern is enrolled',
      (WidgetTester tester) async {
    await pumpHosted(tester);
    expect(find.text(PatternSetupScreen.enterTitle), findsOneWidget);
  });
}
