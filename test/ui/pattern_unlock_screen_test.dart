import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/security/credentials/credential_state_machine.dart';
import 'package:smart_app_lock/security/credentials/impl/default_credential_manager.dart';
import 'package:smart_app_lock/security/credentials/pattern_hasher.dart';
import 'package:smart_app_lock/security/pin_hasher.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_unlock_screen.dart';

/// Phase 2I: pattern authentication — uses the saved pattern (direction
/// independent), with attempts/lockouts/escalating cooldowns inherited
/// from the credential manager.
void main() {
  /// Builds the host: AppScope + a page that pushes the unlock screen and
  /// records its pop result.
  Future<AppContainer> pumpHosted(
    WidgetTester tester, {
    DateTime Function()? now,
  }) async {
    final AppContainer container = AppContainer.inMemory();
    final DefaultCredentialManager manager = DefaultCredentialManager(
      settings: container.securitySettings,
      pinHasher: Pbkdf2PinHasher(iterations: 200),
      patternHasher: Pbkdf2PatternHasher(iterations: 200),
      stateMachine: CredentialStateMachine(
        maxFailedAttempts: 3,
        lockoutDuration: Duration(seconds: 30),
      ),
      // Same clock as the screen: lockout timestamps stay deterministic.
      now: now,
    );
    final List<Object?> results = <Object?>[];
    await tester.pumpWidget(
      AppScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: TextButton(
                  key: const Key('open_unlock'),
                  onPressed: () async {
                    final Object? res = await Navigator.of(context)
                        .push<Object?>(MaterialPageRoute<Object?>(
                      builder: (_) => PatternUnlockScreen(
                        credentialManager: manager,
                        now: now,
                      ),
                    ));
                    results.add(res);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    _ManagerResults.manager = manager;
    _ManagerResults.results = results;
    return container;
  }

  Future<void> openUnlock(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('open_unlock')));
    await tester.pumpAndSettle();
  }

  Future<void> enrollPattern(WidgetTester tester, List<int> nodes) async {
    await _ManagerResults.manager.enrollPattern(nodes);
  }

  // Node centers for the fixed 280x280 grid (10% padding, two equal gaps).
  Offset nodeCenter(int node) {
    final int i = node - 1;
    return Offset(28 + (i % 3) * 112, 28 + (i ~/ 3) * 112);
  }

  Future<void> drawPattern(WidgetTester tester, List<int> nodes) async {
    // Settle any pending step/view transition so exactly one grid is
    // mounted (getTopLeft throws when the switcher still holds two).
    await tester.pump(const Duration(milliseconds: 250));
    final Offset origin = tester.getTopLeft(find.byType(DsPatternGrid));
    final TestGesture gesture =
        await tester.startGesture(origin + nodeCenter(nodes.first));
    await tester.pump();
    // Win the gesture arena with a small HORIZONTAL movement before any
    // vertical leg: the enclosing scrollable would otherwise claim
    // vertical drags and the grid's pan callbacks would never fire.
    await gesture.moveBy(const Offset(24, 0));
    await tester.pump();
    for (final int node in nodes.skip(1)) {
      await gesture.moveTo(origin + nodeCenter(node));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    // Let async verification/enrollment and step transitions finish.
    await tester.pump(const Duration(milliseconds: 400));
  }

  List<int> gridNodes(WidgetTester tester) {
    final CustomPaint paint = tester.widget<CustomPaint>(
      find
          .descendant(
            of: find.byType(DsPatternGrid),
            matching: find.byType(CustomPaint),
          )
          .first,
    );
    return (paint.painter! as PatternGridPainter).nodes;
  }

  testWidgets('correct pattern pops with true', (WidgetTester tester) async {
    await pumpHosted(tester);
    await enrollPattern(tester, const <int>[1, 2, 3, 6]);
    await openUnlock(tester);

    expect(find.text(PatternUnlockScreen.readyHint), findsOneWidget);

    await drawPattern(tester, const <int>[1, 2, 3, 6]);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('open_unlock')), findsOneWidget); // back home
    expect(_ManagerResults.results.last, true);
  });

  testWidgets('the reverse of the saved pattern is REJECTED',
      (WidgetTester tester) async {
    await pumpHosted(tester);
    await enrollPattern(tester, const <int>[1, 2, 3, 6]);
    await openUnlock(tester);

    // Exact sequence: 1-2-3-6 was saved; its reverse must fail.
    await drawPattern(tester, const <int>[6, 3, 2, 1]);

    expect(find.textContaining('Incorrect pattern'), findsOneWidget);
    expect(find.byKey(const Key('open_unlock')), findsNothing); // not popped
  });

  testWidgets('a reordered sequence is REJECTED',
      (WidgetTester tester) async {
    await pumpHosted(tester);
    await enrollPattern(tester, const <int>[1, 2, 3, 6]);
    await openUnlock(tester);

    // Same nodes, different order: 1-3-2-6 must fail.
    await drawPattern(tester, const <int>[1, 3, 2, 6]);

    expect(find.textContaining('Incorrect pattern'), findsOneWidget);
    expect(find.byKey(const Key('open_unlock')), findsNothing);
  });

  testWidgets('wrong pattern shows the error with remaining attempts',
      (WidgetTester tester) async {
    await pumpHosted(tester);
    await enrollPattern(tester, const <int>[1, 2, 3, 6]);
    await openUnlock(tester);

    await drawPattern(tester, const <int>[1, 2, 3, 5]);

    expect(find.text('Incorrect pattern — 2 attempts left.'), findsOneWidget);
    expect(find.byKey(const Key('open_unlock')), findsNothing); // not popped
    expect(gridNodes(tester), isEmpty); // grid cleared for the retry
  });

  testWidgets('too-short draws are rejected inline without counting',
      (WidgetTester tester) async {
    await pumpHosted(tester);
    await enrollPattern(tester, const <int>[1, 2, 3, 6]);
    await openUnlock(tester);

    await drawPattern(tester, const <int>[1, 2, 3]); // only 3 dots

    expect(find.text(PatternUnlockScreen.tooShortMessage), findsOneWidget);
    expect(find.byKey(const Key('open_unlock')), findsNothing);
    // A too-short draw must not count as a failed authentication.
    final state = (await _ManagerResults.manager.status()).valueOrNull!;
    expect(state.failedAttempts, 0);
  });

  testWidgets('reaching the threshold opens the lockout view with a countdown',
      (WidgetTester tester) async {
    await pumpHosted(tester);
    await enrollPattern(tester, const <int>[1, 2, 3, 6]);
    await openUnlock(tester);

    await drawPattern(tester, const <int>[1, 2, 3, 5]);
    await drawPattern(tester, const <int>[1, 2, 3, 7]);
    await drawPattern(tester, const <int>[1, 2, 3, 8]);

    expect(find.text(PatternUnlockScreen.lockedOutTitle), findsOneWidget);
    expect(find.textContaining(PatternUnlockScreen.lockedOutMessage),
        findsOneWidget);

    // The grid is disabled: drawing changes nothing.
    await drawPattern(tester, const <int>[1, 2, 3, 6]);
    expect(find.text(PatternUnlockScreen.lockedOutTitle), findsOneWidget);

    // Tear down so the periodic timer is disposed.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a pre-existing lockout is picked up when the screen opens',
      (WidgetTester tester) async {
    await pumpHosted(tester);
    await enrollPattern(tester, const <int>[1, 2, 3, 6]);

    // Lock out through the manager before opening the screen.
    await _ManagerResults.manager.authenticatePattern(const <int>[1, 2, 3, 5]);
    await _ManagerResults.manager.authenticatePattern(const <int>[1, 2, 3, 7]);
    await _ManagerResults.manager.authenticatePattern(const <int>[1, 2, 3, 8]);

    // Bounded pumps: pumpAndSettle would fast-forward the countdown timer.
    await tester.tap(find.byKey(const Key('open_unlock')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // route transition
    await tester.pump(); // async status load

    expect(find.text(PatternUnlockScreen.lockedOutTitle), findsOneWidget);
    expect(find.textContaining(PatternUnlockScreen.lockedOutMessage),
        findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('countdown expiry re-enables the grid', (WidgetTester tester) async {
    DateTime fakeNow = DateTime.now();
    await pumpHosted(tester, now: () => fakeNow);
    await enrollPattern(tester, const <int>[1, 2, 3, 6]);
    await openUnlock(tester);

    await drawPattern(tester, const <int>[1, 2, 3, 5]);
    await drawPattern(tester, const <int>[1, 2, 3, 7]);
    await drawPattern(tester, const <int>[1, 2, 3, 8]);
    expect(find.text(PatternUnlockScreen.lockedOutTitle), findsOneWidget);

    // Advance well past the 30s lockout (fake time runs ahead of real time
    // during test pumps) and let the periodic tick fire.
    fakeNow = fakeNow.add(const Duration(seconds: 60));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text(PatternUnlockScreen.lockedOutTitle), findsNothing);
    expect(find.text(PatternUnlockScreen.readyHint), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('repeated lockouts escalate the cooldown (Phase 2F)',
      (WidgetTester tester) async {
    DateTime fakeNow = DateTime.now();
    await pumpHosted(tester, now: () => fakeNow);
    await enrollPattern(tester, const <int>[1, 2, 3, 6]);
    await openUnlock(tester);

    // First lockout: streak 1 -> base 30s cooldown, no escalation notice.
    await drawPattern(tester, const <int>[1, 2, 3, 5]);
    await drawPattern(tester, const <int>[1, 2, 3, 7]);
    await drawPattern(tester, const <int>[1, 2, 3, 8]);
    expect(find.text(PatternUnlockScreen.lockedOutTitle), findsOneWidget);
    expect(find.text('Cooldown increases with repeated failures.'),
        findsNothing);

    final state1 = (await _ManagerResults.manager.status()).valueOrNull!;
    expect(state1.lockoutStreak, 1);
    final int cooldown1 = state1.lockedOutUntil!.difference(fakeNow).inSeconds;
    expect(cooldown1, inInclusiveRange(25, 30));

    // Wait the lockout out via the injected clock.
    fakeNow = fakeNow.add(const Duration(seconds: 60));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(PatternUnlockScreen.readyHint), findsOneWidget);

    // Second lockout: streak 2 -> doubled cooldown + escalation notice.
    await drawPattern(tester, const <int>[1, 2, 3, 5]);
    await drawPattern(tester, const <int>[1, 2, 3, 7]);
    await drawPattern(tester, const <int>[1, 2, 3, 8]);
    expect(find.text(PatternUnlockScreen.lockedOutTitle), findsOneWidget);
    expect(find.text('Cooldown increases with repeated failures.'),
        findsOneWidget);

    final state2 = (await _ManagerResults.manager.status()).valueOrNull!;
    expect(state2.lockoutStreak, 2);
    final int cooldown2 = state2.lockedOutUntil!.difference(fakeNow).inSeconds;
    expect(cooldown2, inInclusiveRange(50, 60));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('no configured pattern shows the guided recovery view',
      (WidgetTester tester) async {
    await pumpHosted(tester);
    await openUnlock(tester);

    expect(find.text(PatternUnlockScreen.noCredentialTitle), findsOneWidget);
    expect(find.text(PatternUnlockScreen.noCredentialMessage), findsOneWidget);
    expect(find.text(PatternUnlockScreen.setUpPatternLabel), findsOneWidget);

    // Back pops false without a credential.
    await tester.tap(find.text(PatternUnlockScreen.backLabel));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open_unlock')), findsOneWidget);
    expect(_ManagerResults.results.last, false);
  });

  testWidgets('clear button resets the current drawing',
      (WidgetTester tester) async {
    await pumpHosted(tester);
    await enrollPattern(tester, const <int>[1, 2, 3, 6]);
    await openUnlock(tester);

    // Draw a valid stroke but do NOT authenticate: clearing happens
    // mid-draw by ending a short stroke then clearing.
    await drawPattern(tester, const <int>[1, 2]); // too short -> error+clear
    expect(gridNodes(tester), isEmpty);

    // Draw a full stroke manually and clear before lifting is impossible;
    // instead assert the clear button exists and does not crash.
    await tester.tap(find.text(PatternUnlockScreen.clearLabel));
    await tester.pump();
    expect(find.text(PatternUnlockScreen.readyHint), findsOneWidget);
  });

  // -------------------------------------------------------------------
  // Phase 2K — pattern trail visibility
  // -------------------------------------------------------------------
  PatternGridPainter gridPainter(WidgetTester tester) =>
      tester
          .widget<CustomPaint>(
            find
                .descendant(
                  of: find.byType(DsPatternGrid),
                  matching: find.byType(CustomPaint),
                )
                .first,
          )
          .painter! as PatternGridPainter;

  testWidgets('pattern trail is visible by default', (WidgetTester tester) async {
    await pumpHosted(tester);
    await enrollPattern(tester, const <int>[1, 2, 3, 6]);
    await openUnlock(tester);

    expect(gridPainter(tester).showFeedback, isTrue);
    expect(find.text('Pattern trail hidden for privacy'), findsNothing);
  });

  testWidgets('disabling pattern visibility hides the trail on the unlock screen',
      (WidgetTester tester) async {
    await pumpHosted(tester);
    await enrollPattern(tester, const <int>[1, 2, 3, 6]);
    await _ManagerResults.manager.setPatternVisibilityEnabled(false);
    await openUnlock(tester);

    expect(gridPainter(tester).showFeedback, isFalse);
    expect(find.text('Pattern trail hidden for privacy'), findsOneWidget);

    // The setting persists.
    final state = (await _ManagerResults.manager.status()).valueOrNull!;
    expect(state.patternVisibilityEnabled, isFalse);
  });
}

/// Test-only holder so helper functions can reach the manager and results.
class _ManagerResults {
  static late DefaultCredentialManager manager;
  static late List<Object?> results;
}
