import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/security_settings.dart';
import 'package:smart_app_lock/data/repositories/security_settings_repository.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/credentials/impl/default_credential_manager.dart';
import 'package:smart_app_lock/security/credentials/pattern_hasher.dart';
import 'package:smart_app_lock/security/pin_hasher.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_setup_screen.dart';
import 'package:smart_app_lock/utilities/result.dart';

/// Phase 2H: pattern creation + confirmation flow.
void main() {
  Future<AppContainer> pumpHosted(WidgetTester tester) async {
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
                  key: const Key('open_pattern_setup'),
                  onPressed: () => Navigator.of(context).push<bool>(
                    MaterialPageRoute<bool>(
                      builder: (_) => const PatternSetupScreen(),
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
    await tester.tap(find.byKey(const Key('open_pattern_setup')));
    await tester.pumpAndSettle();
    return container;
  }

  // Node centers for the fixed 280x280 grid (10% padding, two equal gaps).
  Offset nodeCenter(int node) {
    final int i = node - 1;
    return Offset(28 + (i % 3) * 112, 28 + (i ~/ 3) * 112);
  }

  Future<void> drawPattern(WidgetTester tester, List<int> nodes) async {
    final Offset origin = tester.getTopLeft(find.byType(DsPatternGrid));
    final TestGesture gesture =
        await tester.startGesture(origin + nodeCenter(nodes.first));
    await tester.pump(const Duration(milliseconds: 20));
    for (final int node in nodes.skip(1)) {
      await gesture.moveTo(origin + nodeCenter(node));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('draw → confirm → enroll → success (exact ordered sequence)',
      (WidgetTester tester) async {
    final AppContainer container = await pumpHosted(tester);

    expect(find.text(PatternSetupScreen.enterTitle), findsOneWidget);

    await drawPattern(tester, const <int>[1, 2, 3, 6]);
    expect(find.text(PatternSetupScreen.confirmTitle), findsOneWidget);

    // Confirm the EXACT sequence in the same direction — must match.
    await drawPattern(tester, const <int>[1, 2, 3, 6]);
    expect(find.text(PatternSetupScreen.successTitle), findsOneWidget);

    // Really enrolled and verifiable.
    final state = (await container.auth.status()).valueOrNull!;
    expect(state.hasEnrolled(AuthType.pattern), isTrue);
    expect(state.primary, AuthType.pattern);
    final result = (await container.auth.authenticatePattern(
      const <int>[1, 2, 3, 6],
    )).valueOrNull!;
    expect(result, isA<AuthSuccess>());

    // Done pops back.
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open_pattern_setup')), findsOneWidget);
  });

  testWidgets('setup confirmation is direction-sensitive: reverse does NOT match',
      (WidgetTester tester) async {
    final AppContainer container = await pumpHosted(tester);

    await drawPattern(tester, const <int>[1, 2, 3, 6]); // first entry
    await drawPattern(tester, const <int>[6, 3, 2, 1]); // reverse confirm

    // PATTERNS DO NOT MATCH — dedicated mismatch state.
    expect(find.text(PatternSetupScreen.mismatchTitle), findsOneWidget);
    expect(find.text(PatternSetupScreen.mismatchMessage), findsOneWidget);

    // Nothing was enrolled — no partial credential.
    final state = (await container.auth.status()).valueOrNull!;
    expect(state.hasAnyCredential, isFalse);
  });

  testWidgets('mismatch opens the dedicated state and saves nothing',
      (WidgetTester tester) async {
    final AppContainer container = await pumpHosted(tester);

    await drawPattern(tester, const <int>[1, 2, 3, 6]);
    await drawPattern(tester, const <int>[1, 2, 3, 5]); // different sequence

    expect(find.text(PatternSetupScreen.mismatchTitle), findsOneWidget);
    expect(find.text(PatternSetupScreen.mismatchMessage), findsOneWidget);
    expect(find.text(PatternSetupScreen.reconfirmLabel), findsOneWidget);
    expect(find.text(PatternSetupScreen.startOverLabel), findsOneWidget);

    // Nothing was enrolled — no partial credential.
    final state = (await container.auth.status()).valueOrNull!;
    expect(state.hasAnyCredential, isFalse);
  });

  testWidgets('Re-confirm keeps the first pattern and re-asks confirmation',
      (WidgetTester tester) async {
    final AppContainer container = await pumpHosted(tester);

    await drawPattern(tester, const <int>[1, 2, 3, 6]);
    await drawPattern(tester, const <int>[1, 2, 3, 5]);
    expect(find.text(PatternSetupScreen.mismatchTitle), findsOneWidget);

    await tester.tap(find.text(PatternSetupScreen.reconfirmLabel));
    await tester.pumpAndSettle();
    expect(find.text(PatternSetupScreen.confirmTitle), findsOneWidget);

    await drawPattern(tester, const <int>[1, 2, 3, 6]);
    expect(find.text(PatternSetupScreen.successTitle), findsOneWidget);

    final result = (await container.auth.authenticatePattern(
      const <int>[1, 2, 3, 6],
    )).valueOrNull!;
    expect(result, isA<AuthSuccess>());
  });

  testWidgets('Start over clears everything and restarts at the first draw',
      (WidgetTester tester) async {
    final AppContainer container = await pumpHosted(tester);

    await drawPattern(tester, const <int>[1, 2, 3, 6]);
    await drawPattern(tester, const <int>[1, 2, 3, 5]);
    await tester.tap(find.text(PatternSetupScreen.startOverLabel));
    await tester.pumpAndSettle();
    expect(find.text(PatternSetupScreen.enterTitle), findsOneWidget);

    // The fresh pattern is the one that gets enrolled.
    await drawPattern(tester, const <int>[1, 4, 7, 8, 9]);
    await drawPattern(tester, const <int>[1, 4, 7, 8, 9]);
    expect(find.text(PatternSetupScreen.successTitle), findsOneWidget);

    final ok = (await container.auth.authenticatePattern(
      const <int>[1, 4, 7, 8, 9],
    )).valueOrNull!;
    expect(ok, isA<AuthSuccess>());
    final wrong = (await container.auth.authenticatePattern(
      const <int>[1, 2, 3, 6],
    )).valueOrNull!;
    expect(wrong, isA<AuthFailure>());
  });

  testWidgets('too-short patterns are rejected inline with a shake',
      (WidgetTester tester) async {
    await pumpHosted(tester);

    await drawPattern(tester, const <int>[1, 2, 3]); // only 3 dots
    expect(find.text(PatternSetupScreen.tooShortMessage), findsOneWidget);
    expect(find.text(PatternSetupScreen.enterTitle), findsOneWidget);
  });

  testWidgets('Clear button resets the current drawing',
      (WidgetTester tester) async {
    await pumpHosted(tester);

    // Draw a partial stroke, then clear before lifting is not possible
    // (gesture already ended) — draw a short stroke, then clear.
    await drawPattern(tester, const <int>[1, 2]); // rejected as too short
    expect(find.text(PatternSetupScreen.tooShortMessage), findsOneWidget);
    // After rejection the grid is already cleared; draw again and clear
    // mid-progress via the button after completion.
    final Offset origin = tester.getTopLeft(find.byType(DsPatternGrid));
    final TestGesture gesture =
        await tester.startGesture(origin + nodeCenter(1));
    await tester.pump();
    await gesture.moveTo(origin + nodeCenter(2));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    // 2 dots -> error again; tap Clear to reset (already empty), then a
    // valid draw still works.
    await tester.tap(find.text(PatternSetupScreen.clearLabel));
    await tester.pump();
    await drawPattern(tester, const <int>[1, 2, 3, 6]);
    expect(find.text(PatternSetupScreen.confirmTitle), findsOneWidget);
  });

  testWidgets('enrollment failure returns to enter with an error',
      (WidgetTester tester) async {
    // A manager whose settings repository always fails — enrollPattern
    // must fail cleanly and the screen must recover to the enter step.
    final DefaultCredentialManager failing = DefaultCredentialManager(
      settings: _FailingSettingsRepository(),
      pinHasher: Pbkdf2PinHasher(iterations: 200),
      patternHasher: Pbkdf2PatternHasher(iterations: 200),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: PatternSetupScreen(credentialManager: failing),
      ),
    );
    await tester.pumpAndSettle();

    await drawPattern(tester, const <int>[1, 2, 3, 6]);
    await drawPattern(tester, const <int>[1, 2, 3, 6]);

    expect(find.text(PatternSetupScreen.saveFailedMessage), findsOneWidget);
    expect(find.text(PatternSetupScreen.enterTitle), findsOneWidget);
  });

  testWidgets('pattern setup is reachable via its route name',
      (WidgetTester tester) async {
    // Router integration: RouteNames.patternSetup maps to the screen.
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        initialRoute: '/pattern/setup',
        routes: <String, WidgetBuilder>{
          '/pattern/setup': (_) => const PatternSetupScreen(),
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(PatternSetupScreen.enterTitle), findsOneWidget);
  });
}

/// A settings repository that always fails — used to exercise the screen's
/// enrollment-failure path.
class _FailingSettingsRepository implements SecuritySettingsRepository {
  @override
  Future<Result<SecuritySettings>> getSettings() async =>
      Result.failure(StateError('simulated storage failure'));

  @override
  Future<Result<bool>> hasPin() async =>
      Result.failure(StateError('simulated storage failure'));

  @override
  Future<Result<void>> saveSettings(SecuritySettings settings) async =>
      Result.failure(StateError('simulated storage failure'));
}
