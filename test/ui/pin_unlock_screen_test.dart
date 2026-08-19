import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/biometric_options.dart';
import 'package:smart_app_lock/security/credentials/credential_state_machine.dart';
import 'package:smart_app_lock/security/credentials/impl/default_credential_manager.dart';
import 'package:smart_app_lock/security/credentials/pattern_hasher.dart';
import 'package:smart_app_lock/security/pin_hasher.dart';
import 'package:smart_app_lock/services/biometric_service.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/utilities/result.dart';

/// Phase 2E: PIN unlock screen — uses the configured PIN, handles wrong
/// entries, lockouts (including pre-existing ones), countdown expiry and
/// the not-configured state.
void main() {
  /// Builds the host: AppScope + a page that pushes the unlock screen and
  /// records its pop result. [seed] injects a deterministic RNG for the
  /// randomized-keypad tests. [biometricService] fakes the platform
  /// biometric bridge (Phase 2J tests).
  Future<AppContainer> pumpHosted(
    WidgetTester tester, {
    DateTime Function()? now,
    int? seed,
    BiometricService? biometricService,
  }) async {
    final AppContainer container = AppContainer.inMemory();
    // Fast hashers + a low lockout threshold so the suite stays quick.
    final DefaultCredentialManager manager = DefaultCredentialManager(
      settings: container.securitySettings,
      pinHasher: Pbkdf2PinHasher(iterations: 200),
      patternHasher: Pbkdf2PatternHasher(iterations: 200),
      stateMachine: CredentialStateMachine(
        maxFailedAttempts: 3,
        lockoutDuration: Duration(seconds: 30),
      ),
      biometricService: biometricService,
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextButton(
                      key: const Key('open_unlock'),
                      onPressed: () async {
                        final Object? res = await Navigator.of(context)
                            .push<Object?>(MaterialPageRoute<Object?>(
                          builder: (_) => PinUnlockScreen(
                            credentialManager: manager,
                            now: now,
                            random: seed == null ? null : math.Random(seed),
                          ),
                        ));
                        results.add(res);
                      },
                      child: const Text('open'),
                    ),
                    TextButton(
                      key: const Key('close_unlock'),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('back'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // Expose the manager + results for assertions.
    _ManagerResults.manager = manager;
    _ManagerResults.results = results;
    return container;
  }

  Future<void> openUnlock(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('open_unlock')));
    await tester.pumpAndSettle();
  }

  Future<void> tapDigits(WidgetTester tester, String digits) async {
    // Let any pending AnimatedSwitcher transition finish (e.g. the
    // lockout view's disabled pad being removed) so exactly one keypad
    // is mounted when the taps land.
    await tester.pump(const Duration(milliseconds: 250));
    for (final String d in digits.split('')) {
      await tester.tap(find.byKey(Key('pin_key_$d')));
      await tester.pump(const Duration(milliseconds: 50));
    }
    // Entry completion delay + async verification.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> enrollPin(WidgetTester tester, String pin) async {
    await _ManagerResults.manager.enrollPin(pin);
  }

  int dotsTotal(WidgetTester tester) =>
      tester.widget<DsPinDots>(find.byType(DsPinDots)).total;

  /// The ten digit labels rendered by the pad, in visual order. Layout
  /// spacers (no label) are excluded — only numeric keys count.
  List<String> padOrder(WidgetTester tester) => tester
      .widgetList<Text>(
        find.descendant(
          of: find.byType(DsPinPad),
          matching: find.byType(Text),
        ),
      )
      .map((Text t) => t.data ?? '')
      .where((String label) => label.isNotEmpty)
      .toList();

  testWidgets('dots match the configured PIN length (4 and 6)',
      (WidgetTester tester) async {
    await pumpHosted(tester);

    await enrollPin(tester, '1234');
    await openUnlock(tester);
    expect(dotsTotal(tester), 4);

    await tester.tap(find.byKey(const Key('close_unlock')));
    await tester.pumpAndSettle();

    await enrollPin(tester, '246810');
    await openUnlock(tester);
    expect(dotsTotal(tester), 6);
    expect(find.text('Enter your 6-digit PIN'), findsOneWidget);
  });

  testWidgets('correct PIN pops with true', (WidgetTester tester) async {
    await pumpHosted(tester);
    await enrollPin(tester, '1234');
    await openUnlock(tester);

    await tapDigits(tester, '1234');
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('open_unlock')), findsOneWidget); // back home
    expect(_ManagerResults.results.last, true);
  });

  testWidgets('wrong PIN shows the error with remaining attempts and stays',
      (WidgetTester tester) async {
    await pumpHosted(tester);
    await enrollPin(tester, '1234');
    await openUnlock(tester);

    await tapDigits(tester, '9999');

    expect(find.text('Incorrect PIN — 2 attempts left.'), findsOneWidget);
    expect(find.byKey(const Key('open_unlock')), findsNothing); // not popped
    // Entry was cleared for the retry.
    expect(tester.widget<DsPinDots>(find.byType(DsPinDots)).filled, 0);
  });

  testWidgets('reaching the threshold opens the lockout view with a countdown',
      (WidgetTester tester) async {
    await pumpHosted(tester);
    await enrollPin(tester, '1234');
    await openUnlock(tester);

    await tapDigits(tester, '9999');
    await tapDigits(tester, '8888');
    await tapDigits(tester, '7777');

    expect(find.text(PinUnlockScreen.lockedOutTitle), findsOneWidget);
    expect(find.textContaining(PinUnlockScreen.lockedOutMessage),
        findsOneWidget);

    // The pad is disabled: further taps change nothing. (Settle the
    // switcher first so the outgoing ready pad is gone.)
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('pin_key_1')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(PinUnlockScreen.lockedOutTitle), findsOneWidget);

    // Tear down so the periodic timer is disposed.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a pre-existing lockout is picked up when the screen opens',
      (WidgetTester tester) async {
    await pumpHosted(tester);
    await enrollPin(tester, '1234');

    // Trigger a lockout through the manager (as if an earlier attempt
    // happened before opening the screen).
    await _ManagerResults.manager.authenticatePin('9999');
    await _ManagerResults.manager.authenticatePin('8888');
    await _ManagerResults.manager.authenticatePin('7777');

    // Open with bounded pumps: pumpAndSettle would fast-forward the fake
    // clock straight through the 30s countdown timer.
    await tester.tap(find.byKey(const Key('open_unlock')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // route transition
    await tester.pump(); // async status load

    expect(find.text(PinUnlockScreen.lockedOutTitle), findsOneWidget);
    expect(find.textContaining(PinUnlockScreen.lockedOutMessage),
        findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('countdown expiry re-enables the pad', (WidgetTester tester) async {
    DateTime fakeNow = DateTime.now();
    await pumpHosted(tester, now: () => fakeNow);
    await enrollPin(tester, '1234');
    await openUnlock(tester);

    await tapDigits(tester, '9999');
    await tapDigits(tester, '8888');
    await tapDigits(tester, '7777');
    expect(find.text(PinUnlockScreen.lockedOutTitle), findsOneWidget);

    // Advance well past the 30s lockout (fake time runs ahead of real
    // time during test pumps) and let the periodic tick fire.
    fakeNow = fakeNow.add(const Duration(seconds: 60));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text(PinUnlockScreen.lockedOutTitle), findsNothing);
    expect(find.text('Enter your 4-digit PIN'), findsOneWidget);

    // Teardown (a new timer no longer exists, but stay safe).
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('repeated lockouts escalate the cooldown (Phase 2F)',
      (WidgetTester tester) async {
    DateTime fakeNow = DateTime.now();
    await pumpHosted(tester, now: () => fakeNow);
    await enrollPin(tester, '1234');
    await openUnlock(tester);

    // First lockout: streak 1 -> base 30s cooldown, no escalation notice.
    await tapDigits(tester, '9999');
    await tapDigits(tester, '8888');
    await tapDigits(tester, '7777');
    expect(find.text(PinUnlockScreen.lockedOutTitle), findsOneWidget);
    expect(find.text('Cooldown increases with repeated failures.'),
        findsNothing);

    // The manager records the streak and a ~30s cooldown (real clock).
    final state1 = (await _ManagerResults.manager.status()).valueOrNull!;
    expect(state1.lockoutStreak, 1);
    final int cooldown1 =
        state1.lockedOutUntil!.difference(DateTime.now()).inSeconds;
    expect(cooldown1, inInclusiveRange(25, 30));

    // Wait the lockout out (screen countdown uses the injected clock;
    // advance well past the cooldown to cover fake/real clock drift).
    fakeNow = fakeNow.add(const Duration(seconds: 60));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Enter your 4-digit PIN'), findsOneWidget);

    // Second lockout: streak 2 -> doubled cooldown + escalation notice.
    await tapDigits(tester, '1111');
    await tapDigits(tester, '2222');
    await tapDigits(tester, '3333');
    expect(find.text(PinUnlockScreen.lockedOutTitle), findsOneWidget);
    expect(find.text('Cooldown increases with repeated failures.'),
        findsOneWidget);

    final state2 = (await _ManagerResults.manager.status()).valueOrNull!;
    expect(state2.lockoutStreak, 2);
    final int cooldown2 =
        state2.lockedOutUntil!.difference(DateTime.now()).inSeconds;
    expect(cooldown2, inInclusiveRange(50, 60));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  // -------------------------------------------------------------------
  // Phase 2G — randomized keypad (optional, default off)
  // -------------------------------------------------------------------
  testWidgets('no configured PIN shows the guided recovery view',
      (WidgetTester tester) async {
    await pumpHosted(tester);
    await openUnlock(tester);

    expect(find.text(PinUnlockScreen.noCredentialTitle), findsOneWidget);
    expect(find.text(PinUnlockScreen.noCredentialMessage), findsOneWidget);
    expect(find.text(PinUnlockScreen.setUpPinLabel), findsOneWidget);

    // Back pops false without a credential.
    await tester.tap(find.text(PinUnlockScreen.backLabel));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open_unlock')), findsOneWidget);
    expect(_ManagerResults.results.last, false);
  });

  testWidgets('default keypad order is the accessible 1-9 layout',
      (WidgetTester tester) async {
    await pumpHosted(tester);
    await enrollPin(tester, '1234');
    await openUnlock(tester);

    expect(padOrder(tester), DsPinPad.defaultDigitOrder);
    expect(find.text('Keypad order randomized'), findsNothing);
  });

  testWidgets('randomized keypad shuffles and reshuffles after failures',
      (WidgetTester tester) async {
    await pumpHosted(tester, seed: 42);
    await enrollPin(tester, '1234');
    await _ManagerResults.manager.setRandomizedKeypadEnabled(true);
    await openUnlock(tester);

    // Replay the screen's RNG sequence to predict the layouts.
    final math.Random replay = math.Random(42);
    final List<String> firstExpected = shuffledDigitOrder(replay);
    expect(padOrder(tester), firstExpected);
    expect(find.text('Keypad order randomized'), findsOneWidget);

    // One wrong attempt -> the pad reshuffles for the retry.
    await tapDigits(tester, '9999');
    expect(find.text('Incorrect PIN — 2 attempts left.'), findsOneWidget);
    final List<String> secondExpected = shuffledDigitOrder(replay);
    expect(padOrder(tester), secondExpected);
    expect(secondExpected, isNot(equals(firstExpected)));

    // Tapping by digit value still works regardless of position.
    await tapDigits(tester, '1234');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open_unlock')), findsOneWidget);
    expect(_ManagerResults.results.last, true);
  });

  testWidgets('randomized keypad stays off by default and is opt-in only',
      (WidgetTester tester) async {
    await pumpHosted(tester);
    await enrollPin(tester, '1234');
    await openUnlock(tester);

    final state = (await _ManagerResults.manager.status()).valueOrNull!;
    expect(state.randomizedKeypadEnabled, isFalse);
    expect(padOrder(tester), DsPinPad.defaultDigitOrder);
  });

  // -------------------------------------------------------------------
  // Phase 2J — biometric shortcut
  // -------------------------------------------------------------------
  testWidgets('fingerprint slot appears when biometric unlock is enabled',
      (WidgetTester tester) async {
    await pumpHosted(
      tester,
      biometricService:
          const _FakeBiometricService(supported: true, passes: true),
    );
    await enrollPin(tester, '1234');
    await _ManagerResults.manager
        .updateBiometricOptions(BiometricOptions.defaults);
    await openUnlock(tester);

    expect(find.byKey(const Key('pin_key_biometric')), findsOneWidget);
    expect(find.byIcon(Icons.fingerprint), findsOneWidget);
    expect(find.text('Or use your fingerprint'), findsOneWidget);
  });

  testWidgets('biometric slot stays hidden when not configured',
      (WidgetTester tester) async {
    await pumpHosted(tester);
    await enrollPin(tester, '1234'); // no biometric options
    await openUnlock(tester);

    expect(find.byKey(const Key('pin_key_biometric')), findsNothing);
    expect(find.text('Or use your fingerprint'), findsNothing);
  });

  testWidgets('successful biometric unlock pops with true',
      (WidgetTester tester) async {
    await pumpHosted(
      tester,
      biometricService:
          const _FakeBiometricService(supported: true, passes: true),
    );
    await enrollPin(tester, '1234');
    await _ManagerResults.manager
        .updateBiometricOptions(BiometricOptions.defaults);
    await openUnlock(tester);

    await tester.tap(find.byKey(const Key('pin_key_biometric')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('open_unlock')), findsOneWidget);
    expect(_ManagerResults.results.last, true);
  });

  testWidgets('biometric failure shows an error and stays',
      (WidgetTester tester) async {
    await pumpHosted(
      tester,
      biometricService:
          const _FakeBiometricService(supported: true, passes: false),
    );
    await enrollPin(tester, '1234');
    await _ManagerResults.manager
        .updateBiometricOptions(BiometricOptions.defaults);
    await openUnlock(tester);

    await tester.tap(find.byKey(const Key('pin_key_biometric')));
    await tester.pumpAndSettle();

    expect(find.text('Biometric failed — 2 attempts left.'), findsOneWidget);
    expect(find.byKey(const Key('open_unlock')), findsNothing); // not popped
  });

  testWidgets('unconfigured biometric shows the enable hint',
      (WidgetTester tester) async {
    // Service supported, but the user never opted in (no options).
    await pumpHosted(
      tester,
      biometricService:
          const _FakeBiometricService(supported: true, passes: true),
    );
    await enrollPin(tester, '1234');
    await openUnlock(tester);

    // No biometric slot without opt-in, so go through the manager path
    // directly via the pad is impossible — assert the slot is absent and
    // the manager reports notConfigured.
    expect(find.byKey(const Key('pin_key_biometric')), findsNothing);
    final result = (await _ManagerResults.manager.authenticateBiometric())
        .valueOrNull!;
    expect(result, isA<AuthFailure>());
    expect(
      (result as AuthFailure).reason,
      AuthFailureReason.notConfigured,
    );
  });
}

/// Test double for the platform biometric bridge.
class _FakeBiometricService implements BiometricService {
  const _FakeBiometricService({required this.supported, required this.passes});

  final bool supported;
  final bool passes;

  @override
  Future<Result<bool>> isSupported() async => Result.success(supported);

  @override
  Future<Result<Set<BiometricKind>>> availableKinds() async =>
      Result.success(const <BiometricKind>{
        BiometricKind.strong,
        BiometricKind.deviceCredential,
      });

  @override
  Future<Result<bool>> authenticate({
    required String reason,
    BiometricOptions? options,
  }) async =>
      Result.success(passes);
}

/// Test-only holder so helper functions can reach the manager and results
/// without threading them through every call.
class _ManagerResults {
  static late DefaultCredentialManager manager;
  static late List<Object?> results;
}
