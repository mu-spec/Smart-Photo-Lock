import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/router.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/repositories/security_settings_repository.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/data/repositories/impl/security_settings_repository_impl.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/credentials/biometric_options.dart';
import 'package:smart_app_lock/security/credentials/credential_change_authorization.dart';
import 'package:smart_app_lock/security/credentials/credential_state.dart';
import 'package:smart_app_lock/security/credentials/credential_state_machine.dart';
import 'package:smart_app_lock/security/credentials/impl/default_credential_manager.dart';
import 'package:smart_app_lock/security/credentials/pattern_hasher.dart';
import 'package:smart_app_lock/security/pin_hasher.dart';
import 'package:smart_app_lock/services/biometric_service.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_change_screen.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_setup_screen.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_change_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_setup_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/security/credential_change_flow.dart';
import 'package:smart_app_lock/ui/screens/security/security_screen.dart';
import 'package:smart_app_lock/utilities/result.dart';

/// CR-3 regression: adding, replacing or changing a PIN or pattern requires
/// successful verification of an EXISTING app credential whenever one
/// exists. This is enforced at the credential write layer
/// (DefaultCredentialManager.enrollPin/enrollPattern), not only in the UI.
///
/// NOTE: these are host-side unit and widget tests. App switching is
/// simulated by driving the Flutter lifecycle, and "process recreation" is
/// simulated with a fresh manager over the same persisted store. Neither is
/// a real Android process death, and nothing here is device verification.

const String _pin = '1234';
const List<int> _pattern = <int>[1, 2, 3, 6];
const List<int> _newPattern = <int>[1, 4, 7, 8];

void main() {
  // =====================================================================
  // A. Manager write gate (the binding control)
  // =====================================================================
  group('CR-3 manager write gate', () {
    late SecuritySettingsRepository settings;
    late DateTime clock;
    late _FakeBiometric biometric;

    DefaultCredentialManager newManager() => DefaultCredentialManager(
          settings: settings,
          pinHasher: Pbkdf2PinHasher(iterations: 200),
          patternHasher: Pbkdf2PatternHasher(iterations: 200),
          stateMachine: CredentialStateMachine(
            maxFailedAttempts: 3,
            lockoutDuration: const Duration(seconds: 30),
          ),
          biometricService: biometric,
          now: () => clock,
        );

    late DefaultCredentialManager manager;

    setUp(() {
      settings = SecuritySettingsRepositoryImpl(InMemoryLocalDatabase());
      clock = DateTime(2026, 10, 25, 12);
      biometric = _FakeBiometric();
      manager = newManager();
    });

    Future<CredentialState> state() async =>
        (await manager.status()).valueOrNull!;

    CredentialChangeDenial? denialOf(Result<void> r) {
      final Object? e = r.errorOrNull;
      return e is CredentialChangeNotAuthorized ? e.denial : null;
    }

    Future<CredentialChangeAuthorization> grantPin() async {
      final CredentialChangeAttempt a =
          (await manager.verifyPinForCredentialChange(_pin)).valueOrNull!;
      expect(a.result, isA<AuthSuccess>());
      return a.authorization!;
    }

    Future<CredentialChangeAuthorization> grantPattern() async {
      final CredentialChangeAttempt a =
          (await manager.verifyPatternForCredentialChange(_pattern))
              .valueOrNull!;
      expect(a.result, isA<AuthSuccess>());
      return a.authorization!;
    }

    Future<void> expectOnlyPinUnchanged() async {
      final CredentialState s = await state();
      expect(s.hasEnrolled(AuthType.pin), isTrue);
      expect(s.hasEnrolled(AuthType.pattern), isFalse);
      expect(s.primary, AuthType.pin);
      expect(
        (await manager.authenticatePin(_pin)).valueOrNull,
        isA<AuthSuccess>(),
      );
    }

    test('initial enrollment (no credential) needs no authorization', () async {
      expect((await manager.enrollPin(_pin)).isSuccess, isTrue);
      expect((await state()).primary, AuthType.pin);
    });

    test('initial pattern enrollment (no credential) needs no authorization',
        () async {
      expect((await manager.enrollPattern(_pattern)).isSuccess, isTrue);
      expect((await state()).primary, AuthType.pattern);
    });

    test('PIN -> pattern WITHOUT authorization is refused before any write',
        () async {
      await manager.enrollPin(_pin);
      final Result<void> r = await manager.enrollPattern(_newPattern);
      expect(r.isFailure, isTrue);
      expect(denialOf(r), CredentialChangeDenial.missing);
      await expectOnlyPinUnchanged();
    });

    test('pattern -> PIN WITHOUT authorization is refused before any write',
        () async {
      await manager.enrollPattern(_pattern);
      final Result<void> r = await manager.enrollPin('5678');
      expect(denialOf(r), CredentialChangeDenial.missing);
      final CredentialState s = await state();
      expect(s.hasEnrolled(AuthType.pin), isFalse);
      expect(s.primary, AuthType.pattern);
      expect(
        (await manager.authenticatePattern(_pattern)).valueOrNull,
        isA<AuthSuccess>(),
      );
    });

    test('replacing a PIN WITHOUT authorization is refused', () async {
      await manager.enrollPin(_pin);
      expect(denialOf(await manager.enrollPin('5678')),
          CredentialChangeDenial.missing);
      expect((await manager.authenticatePin(_pin)).valueOrNull,
          isA<AuthSuccess>());
      expect((await manager.authenticatePin('5678')).valueOrNull,
          isA<AuthFailure>());
    });

    test('replacing a pattern WITHOUT authorization is refused', () async {
      await manager.enrollPattern(_pattern);
      expect(denialOf(await manager.enrollPattern(_newPattern)),
          CredentialChangeDenial.missing);
      expect((await manager.authenticatePattern(_pattern)).valueOrNull,
          isA<AuthSuccess>());
    });

    test('PIN -> pattern WITH a verified PIN grant succeeds', () async {
      await manager.enrollPin(_pin);
      final Result<void> r = await manager.enrollPattern(
        _newPattern,
        authorization: await grantPin(),
      );
      expect(r.isSuccess, isTrue);
      final CredentialState s = await state();
      expect(s.hasEnrolled(AuthType.pattern), isTrue);
      expect(s.primary, AuthType.pattern);
    });

    test('pattern -> PIN WITH a verified pattern grant succeeds', () async {
      await manager.enrollPattern(_pattern);
      final Result<void> r =
          await manager.enrollPin('5678', authorization: await grantPattern());
      expect(r.isSuccess, isTrue);
      expect((await state()).primary, AuthType.pin);
      expect((await manager.authenticatePin('5678')).valueOrNull,
          isA<AuthSuccess>());
    });

    test('a pattern grant can replace the PIN when both exist', () async {
      await manager.enrollPin(_pin);
      await manager.enrollPattern(_pattern, authorization: await grantPin());
      final Result<void> r =
          await manager.enrollPin('5678', authorization: await grantPattern());
      expect(r.isSuccess, isTrue);
      expect((await manager.authenticatePin(_pin)).valueOrNull,
          isA<AuthFailure>());
    });

    test('wrong credential: no grant, the attempt is counted', () async {
      await manager.enrollPin(_pin);
      final CredentialChangeAttempt a =
          (await manager.verifyPinForCredentialChange('9999')).valueOrNull!;
      expect(a.result, isA<AuthFailure>());
      expect(a.authorization, isNull);
      expect((await state()).failedAttempts, 1);

      final CredentialChangeAttempt p =
          (await manager.verifyPatternForCredentialChange(_newPattern))
              .valueOrNull!;
      expect(p.authorization, isNull); // no pattern enrolled
      await expectOnlyPinUnchanged();
    });

    test(
        'active lockout: the correct PIN yields NO grant, enrollment is '
        'refused, and the lockout is NOT reset', () async {
      await manager.enrollPin(_pin);
      for (int i = 0; i < 3; i++) {
        await manager.verifyPinForCredentialChange('9999');
      }
      final CredentialState locked = await state();
      expect(locked.lockedOutUntil, isNotNull);

      final CredentialChangeAttempt a =
          (await manager.verifyPinForCredentialChange(_pin)).valueOrNull!;
      expect(a.result, isA<AuthLockedOut>());
      expect(a.authorization, isNull);

      expect(denialOf(await manager.enrollPattern(_newPattern)),
          CredentialChangeDenial.missing);
      expect(denialOf(await manager.enrollPin('5678')),
          CredentialChangeDenial.missing);

      final CredentialState after = await state();
      expect(after.lockedOutUntil, locked.lockedOutUntil);
      expect(after.failedAttempts, locked.failedAttempts);
      expect(after.lockoutStreak, locked.lockoutStreak);
      expect(after.hasEnrolled(AuthType.pattern), isFalse);
    });

    test(
        'a grant issued before a lockout cannot be used while locked out, '
        'and the lockout survives', () async {
      await manager.enrollPin(_pin);
      final CredentialChangeAuthorization grant = await grantPin();
      for (int i = 0; i < 3; i++) {
        await manager.authenticatePin('9999');
      }
      final CredentialState locked = await state();
      expect(locked.lockedOutUntil, isNotNull);

      final Result<void> r =
          await manager.enrollPattern(_newPattern, authorization: grant);
      expect(denialOf(r), CredentialChangeDenial.lockedOut);
      final CredentialState after = await state();
      expect(after.lockedOutUntil, locked.lockedOutUntil);
      expect(after.failedAttempts, locked.failedAttempts);
      expect(after.hasEnrolled(AuthType.pattern), isFalse);
    });

    test('biometric success is never a substitute', () async {
      await manager.enrollPin(_pin);
      await manager.updateBiometricOptions(BiometricOptions.defaults);
      expect(
        (await manager.authenticateBiometric()).valueOrNull,
        isA<AuthSuccess>(),
      ); // biometric really succeeds...
      // ...but it issues no grant, and the write is still refused.
      expect(denialOf(await manager.enrollPattern(_newPattern)),
          CredentialChangeDenial.missing);
      expect((await state()).hasEnrolled(AuthType.pattern), isFalse);
    });

    test('stale: an expired grant is refused (TTL)', () async {
      await manager.enrollPin(_pin);
      final CredentialChangeAuthorization grant = await grantPin();
      clock = clock.add(DefaultCredentialManager
              .credentialChangeAuthorizationTtl +
          const Duration(seconds: 1));
      expect(
        denialOf(
            await manager.enrollPattern(_newPattern, authorization: grant)),
        CredentialChangeDenial.expired,
      );
      await expectOnlyPinUnchanged();
    });

    test('stale: a grant is refused if the clock moved backwards', () async {
      await manager.enrollPin(_pin);
      final CredentialChangeAuthorization grant = await grantPin();
      clock = clock.subtract(const Duration(seconds: 5));
      expect(
        denialOf(
            await manager.enrollPattern(_newPattern, authorization: grant)),
        CredentialChangeDenial.expired,
      );
      await expectOnlyPinUnchanged();
    });

    test('stale: a grant is single-use (replay refused)', () async {
      await manager.enrollPin(_pin);
      final CredentialChangeAuthorization grant = await grantPin();
      expect(
        (await manager.enrollPattern(_newPattern, authorization: grant))
            .isSuccess,
        isTrue,
      );
      expect(
        denialOf(await manager.enrollPin('5678', authorization: grant)),
        CredentialChangeDenial.unknown,
      );
      expect((await manager.authenticatePin(_pin)).valueOrNull,
          isA<AuthSuccess>());
    });

    test('stale: a refused attempt still consumes the grant', () async {
      await manager.enrollPin(_pin);
      final CredentialChangeAuthorization grant = await grantPin();
      clock = clock.add(const Duration(minutes: 10));
      await manager.enrollPattern(_newPattern, authorization: grant);
      clock = clock.subtract(const Duration(minutes: 10));
      expect(
        denialOf(
            await manager.enrollPattern(_newPattern, authorization: grant)),
        CredentialChangeDenial.unknown,
      );
    });

    test('stale: a grant from before a credential-set change is refused',
        () async {
      await manager.enrollPin(_pin);
      final CredentialChangeAuthorization grant = await grantPin();
      await manager.clearAll();
      await manager.enrollPin('5678'); // initial enrollment again
      expect(
        (await manager.enrollPattern(_newPattern, authorization: grant))
            .isFailure,
        isTrue,
      );
      expect((await state()).hasEnrolled(AuthType.pattern), isFalse);
    });

    test('stale: a newer verification supersedes the older grant', () async {
      await manager.enrollPin(_pin);
      final CredentialChangeAuthorization first = await grantPin();
      final CredentialChangeAuthorization second = await grantPin();
      expect(
        denialOf(
            await manager.enrollPattern(_newPattern, authorization: first)),
        CredentialChangeDenial.unknown,
      );
      expect(
        (await manager.enrollPattern(_newPattern, authorization: second))
            .isSuccess,
        isTrue,
      );
    });

    test('stale: a revoked grant is refused', () async {
      await manager.enrollPin(_pin);
      final CredentialChangeAuthorization grant = await grantPin();
      manager.revokeCredentialChangeAuthorization(grant);
      expect(
        denialOf(
            await manager.enrollPattern(_newPattern, authorization: grant)),
        CredentialChangeDenial.unknown,
      );
      await expectOnlyPinUnchanged();
    });

    test(
        'SIMULATED process recreation: a grant from the old manager is '
        'refused by a fresh manager over the same store', () async {
      await manager.enrollPin(_pin);
      final CredentialChangeAuthorization grant = await grantPin();
      final DefaultCredentialManager recreated = newManager();
      final Result<void> r =
          await recreated.enrollPattern(_newPattern, authorization: grant);
      expect(r.errorOrNull, isA<CredentialChangeNotAuthorized>());
      expect(
        (await recreated.status()).valueOrNull!.hasEnrolled(AuthType.pattern),
        isFalse,
      );
    });

    test('a forged (never issued) handle is refused', () async {
      await manager.enrollPin(_pin);
      final CredentialChangeAuthorization forged =
          CredentialChangeAuthorization.handle(method: AuthType.pin);
      expect(
        denialOf(
            await manager.enrollPattern(_newPattern, authorization: forged)),
        CredentialChangeDenial.unknown,
      );
      await expectOnlyPinUnchanged();
    });

    test('an input-policy rejection does not consume the grant', () async {
      await manager.enrollPin(_pin);
      final CredentialChangeAuthorization grant = await grantPin();
      final Result<void> weak =
          await manager.enrollPattern(const <int>[1, 2], authorization: grant);
      expect(weak.errorOrNull, isA<FormatException>());
      expect(
        (await manager.enrollPattern(_newPattern, authorization: grant))
            .isSuccess,
        isTrue,
      );
    });

    test(
        'an unauthorized enrollment never resets failed attempts', () async {
      await manager.enrollPin(_pin);
      await manager.authenticatePin('9999');
      await manager.authenticatePin('9999');
      expect((await state()).failedAttempts, 2);
      await manager.enrollPattern(_newPattern);
      await manager.enrollPin('5678');
      expect((await state()).failedAttempts, 2);
    });
  });

  // =====================================================================
  // B. UI paths (Security screen -> change flows -> setup screens)
  // =====================================================================
  group('CR-3 UI paths', () {
    Future<AppContainer> pumpSecurity(
      WidgetTester tester,
      AppContainer c,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        AppScope(
          container: c,
          child: MaterialApp(
            theme: AppTheme.dark,
            onGenerateRoute: (RouteSettings settings) {
              final WidgetBuilder? builder = _routes[settings.name];
              if (builder == null) return null;
              return MaterialPageRoute<bool>(
                settings: settings,
                builder: builder,
              );
            },
            home: const Scaffold(body: SecurityScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return c;
    }

    Future<void> tapRow(WidgetTester tester, String title) async {
      final Finder row = find.widgetWithText(SecurityStatusItem, title);
      expect(row, findsOneWidget);
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
    }

    Future<CredentialState> stateOf(AppContainer c) async =>
        (await c.auth.status()).valueOrNull!;

    testWidgets(
        'PIN set -> "Set up pattern" demands the PIN first; Back changes '
        'nothing', (WidgetTester tester) async {
      final AppContainer c = AppContainer.inMemory();
      await c.auth.enrollPin(_pin);
      await pumpSecurity(tester, c);

      await tapRow(tester, SecurityScreen.setPatternTitle);
      expect(find.byType(PatternSetupScreen), findsNothing);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(find.text(verifyExistingPinTitle), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(SecurityScreen), findsOneWidget);
      expect(find.byType(PatternSetupScreen), findsNothing);
      final CredentialState s = await stateOf(c);
      expect(s.hasEnrolled(AuthType.pattern), isFalse);
      expect(s.primary, AuthType.pin);
    });

    testWidgets(
        'PIN set -> "Set up pattern": a wrong PIN never reaches setup and is '
        'counted', (WidgetTester tester) async {
      final AppContainer c = AppContainer.inMemory();
      await c.auth.enrollPin(_pin);
      await pumpSecurity(tester, c);

      await tapRow(tester, SecurityScreen.setPatternTitle);
      await _tapDigits(tester, '9999');
      expect(find.textContaining('Incorrect PIN'), findsOneWidget);
      expect(find.byType(PatternSetupScreen), findsNothing);
      expect((await stateOf(c)).failedAttempts, 1);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect((await stateOf(c)).hasEnrolled(AuthType.pattern), isFalse);
    });

    testWidgets(
        'PIN set -> "Set up pattern": the correct PIN unlocks setup and the '
        'pattern is enrolled', (WidgetTester tester) async {
      final AppContainer c = AppContainer.inMemory();
      await c.auth.enrollPin(_pin);
      await pumpSecurity(tester, c);

      await tapRow(tester, SecurityScreen.setPatternTitle);
      await _tapDigits(tester, _pin);
      await tester.pumpAndSettle();
      expect(find.byType(PatternSetupScreen), findsOneWidget);
      expect(find.text(PatternSetupScreen.enterTitle), findsOneWidget);

      await _drawPattern(tester, _newPattern);
      await tester.pump(const Duration(milliseconds: 50));
      await _drawPattern(tester, _newPattern);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text(PatternSetupScreen.successTitle), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      final CredentialState s = await stateOf(c);
      expect(s.hasEnrolled(AuthType.pattern), isTrue);
      expect(s.primary, AuthType.pattern);
      expect(find.byType(SecurityScreen), findsOneWidget);
    });

    testWidgets(
        'pattern set -> "Set up PIN" demands the pattern first; Back changes '
        'nothing', (WidgetTester tester) async {
      final AppContainer c = AppContainer.inMemory();
      await c.auth.enrollPattern(_pattern);
      await pumpSecurity(tester, c);

      await tapRow(tester, SecurityScreen.setPinTitle);
      expect(find.byType(PinSetupScreen), findsNothing);
      expect(find.byType(PatternUnlockScreen), findsOneWidget);
      expect(find.text(verifyExistingPatternTitle), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      final CredentialState s = await stateOf(c);
      expect(s.hasEnrolled(AuthType.pin), isFalse);
      expect(s.primary, AuthType.pattern);
    });

    testWidgets(
        'pattern set -> "Set up PIN": the correct pattern unlocks setup and '
        'the PIN is enrolled', (WidgetTester tester) async {
      final AppContainer c = AppContainer.inMemory();
      await c.auth.enrollPattern(_pattern);
      await pumpSecurity(tester, c);

      await tapRow(tester, SecurityScreen.setPinTitle);
      await _drawPattern(tester, _pattern);
      await tester.pumpAndSettle();
      expect(find.byType(PinSetupScreen), findsOneWidget);

      await tester.tap(find.text('4-digit PIN'));
      await tester.pumpAndSettle();
      await _tapDigits(tester, '5678');
      await _tapDigits(tester, '5678');
      expect(find.text(PinSetupScreen.successTitle), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      final CredentialState s = await stateOf(c);
      expect(s.hasEnrolled(AuthType.pin), isTrue);
      expect(s.primary, AuthType.pin);
    });

    testWidgets(
        'active lockout: "Set up pattern" cannot proceed and the lockout is '
        'not reset', (WidgetTester tester) async {
      final AppContainer c = AppContainer.inMemory();
      await c.auth.enrollPin(_pin);
      AuthAttemptResult? last;
      for (int i = 0; i < 10 && last is! AuthLockedOut; i++) {
        last = (await c.auth.authenticatePin('9999')).valueOrNull;
      }
      expect(last, isA<AuthLockedOut>());
      final CredentialState locked = await stateOf(c);
      await pumpSecurity(tester, c);

      await tapRow(tester, SecurityScreen.setPatternTitle);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await _tapDigits(tester, _pin); // correct PIN, but locked out
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(PatternSetupScreen), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();
      final CredentialState after = await stateOf(c);
      expect(after.hasEnrolled(AuthType.pattern), isFalse);
      expect(after.lockedOutUntil, locked.lockedOutUntil);
      expect(after.lockoutStreak, locked.lockoutStreak);
    });

    testWidgets(
        'biometric is hidden on the change verification (Change PIN) even '
        'when enabled', (WidgetTester tester) async {
      final AppContainer c =
          AppContainer.inMemory(biometrics: _FakeBiometric());
      await c.auth.enrollPin(_pin);
      await c.auth.updateBiometricOptions(BiometricOptions.defaults);
      await pumpSecurity(tester, c);

      await tapRow(tester, SecurityScreen.changePinTitle);
      expect(find.text(PinChangeScreen.verifyTitle), findsOneWidget);
      expect(find.byKey(const Key('pin_key_biometric')), findsNothing);
      expect(find.byType(PinSetupScreen), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect((await c.auth.authenticatePin(_pin)).valueOrNull,
          isA<AuthSuccess>());
    });

    testWidgets(
        'SIMULATED app switch after verification closes setup and revokes '
        'the grant: nothing is written', (WidgetTester tester) async {
      final AppContainer c = AppContainer.inMemory();
      await c.auth.enrollPin(_pin);
      await pumpSecurity(tester, c);
      addTearDown(() => tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed));

      await tapRow(tester, SecurityScreen.setPatternTitle);
      await _tapDigits(tester, _pin);
      await tester.pumpAndSettle();
      expect(find.byType(PatternSetupScreen), findsOneWidget);

      for (final AppLifecycleState s in <AppLifecycleState>[
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
        await tester.pump();
      }
      for (final AppLifecycleState s in <AppLifecycleState>[
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(find.byType(PatternSetupScreen), findsNothing);
      expect(find.byType(SecurityScreen), findsOneWidget);
      final CredentialState s = await stateOf(c);
      expect(s.hasEnrolled(AuthType.pattern), isFalse);
      expect(s.primary, AuthType.pin);
    });

    testWidgets(
        'backstop: the raw pattern-setup route (as used by the unlock '
        'screens\' "Set up" buttons) cannot overwrite an existing PIN',
        (WidgetTester tester) async {
      final AppContainer c = AppContainer.inMemory();
      await c.auth.enrollPin(_pin);
      await c.auth.authenticatePin('9999'); // one failed attempt on record
      await pumpSecurity(tester, c);

      final NavigatorState nav =
          tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.pushNamed<bool>(RouteNames.patternSetup);
      await tester.pumpAndSettle();
      expect(find.byType(PatternSetupScreen), findsOneWidget);

      await _drawPattern(tester, _newPattern);
      await tester.pump(const Duration(milliseconds: 50));
      await _drawPattern(tester, _newPattern);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(PatternSetupScreen.successTitle), findsNothing);
      expect(find.text(PatternSetupScreen.saveFailedMessage), findsOneWidget);

      final CredentialState s = await stateOf(c);
      expect(s.hasEnrolled(AuthType.pattern), isFalse);
      expect(s.primary, AuthType.pin);
      expect(s.failedAttempts, 1); // attempt state NOT reset
    });

    testWidgets(
        'backstop: the raw PIN-setup route cannot overwrite an existing '
        'pattern', (WidgetTester tester) async {
      final AppContainer c = AppContainer.inMemory();
      await c.auth.enrollPattern(_pattern);
      await pumpSecurity(tester, c);

      final NavigatorState nav =
          tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.pushNamed<bool>(RouteNames.pinSetup);
      await tester.pumpAndSettle();
      await tester.tap(find.text('4-digit PIN'));
      await tester.pumpAndSettle();
      await _tapDigits(tester, '5678');
      await _tapDigits(tester, '5678');
      expect(find.text(PinSetupScreen.successTitle), findsNothing);
      expect(find.text(PinSetupScreen.saveFailedMessage), findsOneWidget);
      expect((await stateOf(c)).hasEnrolled(AuthType.pin), isFalse);
    });

    testWidgets('initial enrollment from Security needs no verification',
        (WidgetTester tester) async {
      final AppContainer c = AppContainer.inMemory();
      await pumpSecurity(tester, c);

      await tapRow(tester, SecurityScreen.setPatternTitle);
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(find.byType(PatternUnlockScreen), findsNothing);
      expect(find.text(PatternSetupScreen.enterTitle), findsOneWidget);

      await _drawPattern(tester, _pattern);
      await tester.pump(const Duration(milliseconds: 50));
      await _drawPattern(tester, _pattern);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text(PatternSetupScreen.successTitle), findsOneWidget);
      expect((await stateOf(c)).primary, AuthType.pattern);
    });

    testWidgets(
        'credential replacement via Change pattern still requires the '
        'current pattern and works end-to-end', (WidgetTester tester) async {
      final AppContainer c = AppContainer.inMemory();
      await c.auth.enrollPattern(_pattern);
      await pumpSecurity(tester, c);

      await tapRow(tester, SecurityScreen.changePatternTitle);
      expect(find.text(PatternChangeScreen.verifyTitle), findsOneWidget);
      await _drawPattern(tester, _pattern);
      await tester.pumpAndSettle();
      expect(find.text(PatternChangeScreen.setupTitle), findsOneWidget);
      await _drawPattern(tester, _newPattern);
      await tester.pump(const Duration(milliseconds: 50));
      await _drawPattern(tester, _newPattern);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text(SecurityScreen.patternChangedMessage), findsOneWidget);

      expect((await c.auth.authenticatePattern(_pattern)).valueOrNull,
          isA<AuthFailure>());
      expect((await c.auth.authenticatePattern(_newPattern)).valueOrNull,
          isA<AuthSuccess>());
    });
  });
}

final Map<String, WidgetBuilder> _routes = <String, WidgetBuilder>{
  RouteNames.pinSetup: (BuildContext context) => const PinSetupScreen(),
  RouteNames.pinUnlock: (BuildContext context) => const PinUnlockScreen(),
  RouteNames.pinChange: (BuildContext context) => const PinChangeScreen(),
  RouteNames.patternSetup: (BuildContext context) => const PatternSetupScreen(),
  RouteNames.patternUnlock: (BuildContext context) =>
      const PatternUnlockScreen(),
  RouteNames.patternChange: (BuildContext context) =>
      const PatternChangeScreen(),
};

Future<void> _tapDigits(WidgetTester tester, String digits) async {
  await tester.pump(const Duration(milliseconds: 250));
  for (final String d in digits.split('')) {
    await tester.tap(find.byKey(Key('pin_key_$d')));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 100));
}

/// Same stroke technique as test/ui/pattern_change_screen_test.dart.
Future<void> _drawPattern(WidgetTester tester, List<int> nodes) async {
  await tester.pump(const Duration(milliseconds: 450));
  final Finder gridFinder = find.byType(DsPatternGrid);
  expect(gridFinder, findsOneWidget);
  final Rect bounds = tester.getRect(gridFinder);
  final double pad = bounds.width * 0.10;
  final double step = (bounds.width - 2 * pad) / 2;
  Offset center(int node) {
    final int i = node - 1;
    return Offset(
      bounds.left + pad + (i % 3) * step,
      bounds.top + pad + (i ~/ 3) * step,
    );
  }

  final TestGesture gesture = await tester.startGesture(center(nodes.first));
  await tester.pump();
  await gesture.moveBy(const Offset(20, 0));
  await tester.pump();
  Offset current = center(nodes.first).translate(20, 0);
  for (final int node in nodes.skip(1)) {
    final Offset target = center(node);
    const int steps = 6;
    for (int s = 1; s <= steps; s++) {
      await gesture.moveTo(Offset(
        current.dx + (target.dx - current.dx) * s / steps,
        current.dy + (target.dy - current.dy) * s / steps,
      ));
      await tester.pump();
    }
    current = target;
  }
  await gesture.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
}

/// Deterministic fake: biometric hardware present and the prompt succeeds.
class _FakeBiometric implements BiometricService {
  @override
  Future<Result<bool>> isSupported() async => Result.success(true);

  @override
  Future<Result<Set<BiometricKind>>> availableKinds() async =>
      Result.success(const <BiometricKind>{BiometricKind.strong});

  @override
  Future<Result<bool>> authenticate({
    required String reason,
    BiometricOptions? options,
  }) async =>
      Result.success(true);
}
