import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// The OS layer is faked at the real plugin seam (LocalAuthPlatform.instance)
// so the production LocalAuthBiometricService runs unmodified.
// ignore: depend_on_referenced_packages
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';

import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/router.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/security_settings.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/credentials/biometric_options.dart';
import 'package:smart_app_lock/security/credentials/credential_change_authorization.dart';
import 'package:smart_app_lock/security/credentials/credential_manager.dart';
import 'package:smart_app_lock/security/credentials/credential_state.dart';
import 'package:smart_app_lock/security/credentials/pattern_policy.dart';
import 'package:smart_app_lock/security/pin_policy.dart';
import 'package:smart_app_lock/services/impl/local_auth_biometric_service.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/security/app_credential_verification.dart';
import 'package:smart_app_lock/ui/screens/security/security_screen.dart';
import 'package:smart_app_lock/utilities/result.dart';
import '../support/credential_change_grant.dart';

/// H-3 F4: enabling biometric unlock requires verifying the configured
/// PRIMARY Smart App Lock credential, through a flow that is isolated from
/// the CR-3 credential-change grant machinery. Disabling needs no
/// verification.
///
/// SIMULATED: the OS is a fake [LocalAuthPlatform]; the credential manager,
/// verification screens and Security screen are production code.
void main() {
  late _FakeOs os;

  setUp(() {
    os = _FakeOs()..enrolled = <BiometricType>[BiometricType.strong];
    LocalAuthPlatform.instance = os;
  });

  const String pin = '482916';
  const List<int> pattern = <int>[3, 6, 9, 8];
  const String enabledText = 'Biometric unlock enabled ✓';
  const String notEnabledText = 'Biometric unlock was not enabled.';

  Future<void> pumpSecurity(WidgetTester tester, AppContainer c) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.dark,
          onGenerateRoute: AppRouter.onGenerateRoute,
          home: const Scaffold(body: SecurityScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder biometricRow() =>
      find.widgetWithText(SecurityStatusItem, 'Biometric unlock');

  Future<void> tapBiometricRow(WidgetTester tester) async {
    await tester.ensureVisible(biometricRow());
    await tester.pumpAndSettle();
    await tester.tap(biometricRow());
    await tester.pumpAndSettle();
  }

  Future<void> tapDigits(WidgetTester tester, String digits) async {
    await tester.pump(const Duration(milliseconds: 250));
    for (final String d in digits.split('')) {
      await tester.tap(find.byKey(Key('pin_key_$d')));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  Future<void> drawPattern(WidgetTester tester, List<int> nodes) async {
    await tester.pump(const Duration(milliseconds: 450));
    final Rect bounds = tester.getRect(find.byType(DsPatternGrid));
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
    await tester.pumpAndSettle();
  }

  Future<BiometricOptions?> storedOptions(AppContainer c) async =>
      (await c.securitySettings.getSettings()).valueOrNull!.biometricOptions;

  AppContainer newContainer() =>
      AppContainer.inMemory(biometrics: LocalAuthBiometricService());

  // ---------------------------------------------------------------------
  // Primary credential is required (PIN and pattern)
  // ---------------------------------------------------------------------
  group('enabling requires the primary credential', () {
    testWidgets('PIN primary: verification screen first, then enabled',
        (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await c.auth.enrollPin(pin);
      await pumpSecurity(tester, c);

      await tapBiometricRow(tester);

      // Not enabled before verification; the screen offers no biometric.
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(find.text('Enter current PIN'), findsOneWidget);
      expect(find.byKey(const Key('pin_key_biometric')), findsNothing);
      expect(await storedOptions(c), isNull);

      await tapDigits(tester, pin);

      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(find.text(enabledText), findsOneWidget);
      final BiometricOptions stored = (await storedOptions(c))!;
      expect(stored.allowDeviceCredential, isFalse); // F3 preserved
      expect(stored.allowStrongBiometrics, isTrue);
      expect(os.prompts, isEmpty, reason: 'biometric is never prompted');
    });

    testWidgets('pattern primary: asks for the pattern, then enabled',
        (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await c.auth.enrollPattern(pattern);
      await pumpSecurity(tester, c);

      await tapBiometricRow(tester);

      expect(find.byType(PatternUnlockScreen), findsOneWidget);
      expect(find.text('Enter current pattern'), findsOneWidget);
      expect(find.byKey(const Key('pattern_key_biometric')), findsNothing);
      expect(await storedOptions(c), isNull);

      await drawPattern(tester, pattern);

      expect(find.byType(PatternUnlockScreen), findsNothing);
      expect(find.text(enabledText), findsOneWidget);
      expect((await storedOptions(c))!.allowDeviceCredential, isFalse);
    });

    testWidgets('both enrolled: the configured primary (pattern) is asked',
        (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await c.auth.enrollPin(pin);
      await c.auth.enrollPattern(
        pattern,
        authorization: await grantWithPin(c.auth, pin),
      );
      expect((await c.auth.status()).valueOrNull!.primary, AuthType.pattern);
      await pumpSecurity(tester, c);

      await tapBiometricRow(tester);

      expect(find.byType(PatternUnlockScreen), findsOneWidget);
      expect(find.byType(PinUnlockScreen), findsNothing);
    });
  });

  // ---------------------------------------------------------------------
  // Failure paths never enable
  // ---------------------------------------------------------------------
  group('failures never enable', () {
    testWidgets('wrong PIN counts normally, then Back: not enabled',
        (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await c.auth.enrollPin(pin);
      await pumpSecurity(tester, c);
      await tapBiometricRow(tester);

      await tapDigits(tester, '000000');

      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(await storedOptions(c), isNull);
      expect((await c.auth.status()).valueOrNull!.failedAttempts, 1);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(find.text(notEnabledText), findsOneWidget);
      expect(await storedOptions(c), isNull);
      expect((await c.auth.status()).valueOrNull!.failedAttempts, 1);
    });

    testWidgets('Back without entering anything: not enabled, not counted, '
        'and a later attempt starts a fresh verification',
        (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await c.auth.enrollPin(pin);
      await pumpSecurity(tester, c);
      await tapBiometricRow(tester);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text(notEnabledText), findsOneWidget);
      expect(await storedOptions(c), isNull);
      expect((await c.auth.status()).valueOrNull!.failedAttempts, 0);

      // The denied attempt leaves nothing behind: tapping again asks again.
      await tester.pump(const Duration(seconds: 5)); // let the snackbar go
      await tapBiometricRow(tester);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await tapDigits(tester, pin);
      expect(find.text(enabledText), findsOneWidget);
    });

    testWidgets('wrong PIN x3 inside the flow locks out; Back: not enabled',
        (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await c.auth.enrollPin(pin);
      await pumpSecurity(tester, c);
      await tapBiometricRow(tester);

      for (int i = 0; i < 3; i++) {
        await tapDigits(tester, '000000');
      }
      final SecuritySettings locked =
          (await c.securitySettings.getSettings()).valueOrNull!;
      expect(locked.lockedOutUntil, isNotNull);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(await storedOptions(c), isNull);
      final SecuritySettings after =
          (await c.securitySettings.getSettings()).valueOrNull!;
      expect(after.lockedOutUntil, locked.lockedOutUntil);
      expect(after.lockoutStreak, locked.lockoutStreak);
    });

    testWidgets('an active lockout before tapping: the correct PIN cannot '
        'verify, nothing is reset, not enabled', (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await c.auth.enrollPin(pin);
      for (int i = 0; i < 3; i++) {
        await c.auth.authenticatePin('000000');
      }
      final SecuritySettings locked =
          (await c.securitySettings.getSettings()).valueOrNull!;
      expect(locked.lockedOutUntil, isNotNull);
      await pumpSecurity(tester, c);

      await tapBiometricRow(tester);
      // The lockout view is shown with a DISABLED keypad: entering the
      // CORRECT PIN does nothing, and a direct manager attempt with the
      // correct PIN is refused too.
      expect(find.text(PinUnlockScreen.lockedOutTitle), findsOneWidget);
      await tapDigits(tester, pin);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(find.text(enabledText), findsNothing);
      expect((await c.auth.authenticatePin(pin)).valueOrNull,
          isA<AuthLockedOut>());

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(await storedOptions(c), isNull);
      final SecuritySettings after =
          (await c.securitySettings.getSettings()).valueOrNull!;
      expect(after.lockedOutUntil, locked.lockedOutUntil);
      expect(after.lockoutStreak, locked.lockoutStreak);
    });

    testWidgets('no app credential: refused without a verification screen',
        (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await pumpSecurity(tester, c);

      await tapBiometricRow(tester);

      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(find.byType(PatternUnlockScreen), findsNothing);
      expect(await storedOptions(c), isNull);
    });
  });

  // ---------------------------------------------------------------------
  // Re-checks immediately before saving
  // ---------------------------------------------------------------------
  group('state is re-checked immediately before saving', () {
    testWidgets('biometric enrollment lost during verification: not enabled',
        (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await c.auth.enrollPin(pin);
      await pumpSecurity(tester, c);
      await tapBiometricRow(tester);
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      os.enrolled = <BiometricType>[]; // fingerprint removed meanwhile
      await tapDigits(tester, pin);

      expect(find.text(enabledText), findsNothing);
      expect(find.text(SecurityScreen.biometricNotEnrolledMessage),
          findsOneWidget);
      expect(await storedOptions(c), isNull);
    });

    testWidgets('primary credential changed during verification: not enabled',
        (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await c.auth.enrollPin(pin);
      await pumpSecurity(tester, c);
      await tapBiometricRow(tester);
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      // A CR-3-authorized change makes the pattern primary meanwhile.
      await tester.runAsync(() async {
        await c.auth.enrollPattern(
          pattern,
          authorization: await grantWithPin(c.auth, pin),
        );
      });
      await tapDigits(tester, pin);

      expect(find.text(enabledText), findsNothing);
      expect(find.text(notEnabledText), findsOneWidget);
      expect(await storedOptions(c), isNull);
    });

    testWidgets('duplicate taps open ONE verification and enable once',
        (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await c.auth.enrollPin(pin);
      await pumpSecurity(tester, c);
      await tester.ensureVisible(biometricRow());
      await tester.pumpAndSettle();

      await tester.tap(biometricRow());
      await tester.tap(biometricRow(), warnIfMissed: false);
      await tester.pump();
      await tester.tap(biometricRow(), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await tapDigits(tester, pin);
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(find.text(enabledText), findsOneWidget);
      expect((await storedOptions(c))!.allowDeviceCredential, isFalse);
    });
  });

  // ---------------------------------------------------------------------
  // Disabling stays free
  // ---------------------------------------------------------------------
  testWidgets('disabling needs no verification', (WidgetTester tester) async {
    final AppContainer c = newContainer();
    await c.auth.enrollPin(pin);
    await c.auth.updateBiometricOptions(BiometricOptions.defaults);
    await pumpSecurity(tester, c);

    await tapBiometricRow(tester);

    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(find.text('Biometric unlock disabled.'), findsOneWidget);
    expect(await storedOptions(c), isNull);
  });

  // ---------------------------------------------------------------------
  // CR-3 grant isolation
  // ---------------------------------------------------------------------
  group('CR-3 grant isolation', () {
    testWidgets(
        'an existing credential-change grant survives the F4 flow and '
        'still authorizes exactly one write', (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await c.auth.enrollPin(pin);
      final CredentialChangeAuthorization existing =
          await grantWithPin(c.auth, pin);
      await pumpSecurity(tester, c);

      await tapBiometricRow(tester);
      await tapDigits(tester, pin);
      expect(find.text(enabledText), findsOneWidget);

      // Not invalidated: the pre-existing grant still authorizes a write.
      late Result<void> write;
      await tester.runAsync(() async {
        write = await c.auth.enrollPattern(pattern, authorization: existing);
      });
      expect(write.isSuccess, isTrue);
      // ...and is consumed by that write as usual (CR-3 unchanged).
      await tester.runAsync(() async {
        write = await c.auth.enrollPattern(
          const <int>[1, 2, 3, 6],
          authorization: existing,
        );
      });
      expect(write.errorOrNull, isA<CredentialChangeNotAuthorized>());
    });

    testWidgets('the F4 flow creates no grant: an unauthorized write after a '
        'successful verification is still refused',
        (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await c.auth.enrollPin(pin);
      await pumpSecurity(tester, c);

      await tapBiometricRow(tester);
      await tapDigits(tester, pin);
      expect(find.text(enabledText), findsOneWidget);

      late Result<void> write;
      await tester.runAsync(() async {
        write = await c.auth.enrollPattern(pattern);
      });
      expect(write.errorOrNull, isA<CredentialChangeNotAuthorized>());
      expect(
        (write.errorOrNull! as CredentialChangeNotAuthorized).denial,
        CredentialChangeDenial.missing,
      );
    });
  });

  // ---------------------------------------------------------------------
  // The helper itself (call-level proof of isolation and binding)
  // ---------------------------------------------------------------------
  group('verifyPrimaryAppCredential', () {
    late _SpyManager spy;
    late List<AppCredentialVerificationResult> results;

    Future<void> pumpHost(WidgetTester tester, CredentialManager manager) async {
      results = <AppCredentialVerificationResult>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: TextButton(
                key: const Key('verify'),
                onPressed: () async => results.add(
                  await verifyPrimaryAppCredential(
                    Navigator.of(context),
                    manager,
                  ),
                ),
                child: const Text('verify'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('verify')));
      await tester.pumpAndSettle();
    }

    testWidgets('success uses ONLY status + normal authenticatePin',
        (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await c.auth.enrollPin(pin);
      spy = _SpyManager(c.auth);
      await pumpHost(tester, spy);

      await tapDigits(tester, pin);

      expect(results.single.isVerified, isTrue);
      expect(results.single.method, AuthType.pin);
      expect(spy.calls.toSet(), <String>{'status', 'authenticatePin'});
    });

    testWidgets('pattern success uses ONLY status + normal authenticatePattern',
        (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await c.auth.enrollPattern(pattern);
      spy = _SpyManager(c.auth);
      await pumpHost(tester, spy);

      await drawPattern(tester, pattern);

      expect(results.single.isVerified, isTrue);
      expect(results.single.method, AuthType.pattern);
      expect(spy.calls.toSet(), <String>{'status', 'authenticatePattern'});
    });

    testWidgets('wrong PIN + Back: denied; still no CR-3 or write calls',
        (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await c.auth.enrollPin(pin);
      spy = _SpyManager(c.auth);
      await pumpHost(tester, spy);

      await tapDigits(tester, '000000');
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(results.single.outcome, AppCredentialVerificationOutcome.denied);
      expect(spy.calls.toSet(), <String>{'status', 'authenticatePin'});
    });

    testWidgets('a success outside this verification does not count; popping '
        'true without a success is denied', (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await c.auth.enrollPin(pin);
      await pumpHost(tester, c.auth);

      // Correct PIN entered elsewhere (not through this flow's screen).
      late Result<AuthAttemptResult> outside;
      await tester.runAsync(() async {
        outside = await c.auth.authenticatePin(pin);
      });
      expect(outside.valueOrNull, isA<AuthSuccess>());
      // Force the screen closed with `true` without a verified attempt.
      Navigator.of(tester.element(find.byType(PinUnlockScreen))).pop(true);
      await tester.pumpAndSettle();

      expect(results.single.outcome, AppCredentialVerificationOutcome.denied);
    });

    testWidgets('biometric is hidden and refused inside the flow, even when '
        'biometric unlock is already configured', (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await c.auth.enrollPin(pin);
      await c.auth.updateBiometricOptions(BiometricOptions.defaults);
      // Sanity: the normal unlock path WOULD offer biometric here.
      expect((await c.auth.status()).valueOrNull!.hasEnrolled(
        AuthType.biometric,
      ), isTrue);
      spy = _SpyManager(c.auth);
      await pumpHost(tester, spy);

      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(find.byKey(const Key('pin_key_biometric')), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(results.single.outcome, AppCredentialVerificationOutcome.denied);
      expect(spy.calls, isNot(contains('authenticateBiometric')));
      expect(os.prompts, isEmpty);
    });

    testWidgets(
        'Back while the CORRECT PIN is still being verified: denied, and the '
        'late success is ignored', (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await c.auth.enrollPin(pin);
      final _GatedManager manager = _GatedManager(c.auth);
      final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
      results = <AppCredentialVerificationResult>[];
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          theme: AppTheme.dark,
          home: const Scaffold(body: Text('root')),
        ),
      );
      // A spacer page under the verification route keeps the root route
      // safe from any late pop by the dismissed screen.
      navKey.currentState!.push(MaterialPageRoute<void>(
        builder: (BuildContext context) => Scaffold(
          body: TextButton(
            key: const Key('verify'),
            onPressed: () async => results.add(
              await verifyPrimaryAppCredential(Navigator.of(context), manager),
            ),
            child: const Text('verify'),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('verify')));
      await tester.pumpAndSettle();

      // Enter the correct PIN; the manager holds the (real) result.
      await tester.pump(const Duration(milliseconds: 250));
      for (final String d in pin.split('')) {
        await tester.tap(find.byKey(Key('pin_key_$d')));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 300));
      expect(manager.pending, isTrue);

      // System Back while verification is in flight.
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(results.single.outcome, AppCredentialVerificationOutcome.denied);

      // Now the correct-PIN success arrives: it must change nothing.
      await tester.runAsync(manager.release);
      await tester.pumpAndSettle();
      expect(results, hasLength(1));
      expect(results.single.outcome, AppCredentialVerificationOutcome.denied);
      expect(manager.lastResult, isA<AuthSuccess>());
    });

    testWidgets('unreadable status: unavailable, no screen',
        (WidgetTester tester) async {
      await pumpHost(tester, _FailingStatusManager());

      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(
        results.single.outcome,
        AppCredentialVerificationOutcome.unavailable,
      );
    });

    testWidgets('no credential: unavailable, no screen',
        (WidgetTester tester) async {
      final AppContainer c = newContainer();
      await pumpHost(tester, c.auth);

      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(find.byType(PatternUnlockScreen), findsNothing);
      expect(
        results.single.outcome,
        AppCredentialVerificationOutcome.unavailable,
      );
    });
  });
}

/// Records every call, then forwards to the real manager.
class _SpyManager implements CredentialManager {
  _SpyManager(this._d);

  final CredentialManager _d;
  final List<String> calls = <String>[];

  T _log<T>(String name, T Function() f) {
    calls.add(name);
    return f();
  }

  @override
  Future<Result<CredentialState>> status() => _log('status', _d.status);

  @override
  Future<Result<AuthAttemptResult>> authenticatePin(String pin) =>
      _log('authenticatePin', () => _d.authenticatePin(pin));

  @override
  Future<Result<AuthAttemptResult>> authenticatePattern(List<int> nodes) =>
      _log('authenticatePattern', () => _d.authenticatePattern(nodes));

  @override
  Future<Result<AuthAttemptResult>> authenticateBiometric({
    String reason = 'Unlock Smart App Lock',
  }) =>
      _log('authenticateBiometric', () => _d.authenticateBiometric());

  @override
  Future<Result<CredentialChangeAttempt>> verifyPinForCredentialChange(
    String pin,
  ) =>
      _log('verifyPinForCredentialChange',
          () => _d.verifyPinForCredentialChange(pin));

  @override
  Future<Result<CredentialChangeAttempt>> verifyPatternForCredentialChange(
    List<int> nodes,
  ) =>
      _log('verifyPatternForCredentialChange',
          () => _d.verifyPatternForCredentialChange(nodes));

  @override
  void revokeCredentialChangeAuthorization(
    CredentialChangeAuthorization authorization,
  ) =>
      _log('revokeCredentialChangeAuthorization',
          () => _d.revokeCredentialChangeAuthorization(authorization));

  @override
  Future<Result<void>> enrollPin(
    String pin, {
    PinPolicy policy = PinPolicy.defaults,
    CredentialChangeAuthorization? authorization,
  }) =>
      _log('enrollPin', () => _d.enrollPin(pin, authorization: authorization));

  @override
  Future<Result<void>> enrollPattern(
    List<int> nodes, {
    PatternPolicy policy = PatternPolicy.defaults,
    CredentialChangeAuthorization? authorization,
  }) =>
      _log('enrollPattern',
          () => _d.enrollPattern(nodes, authorization: authorization));

  @override
  Future<Result<void>> updateBiometricOptions(BiometricOptions? options) =>
      _log('updateBiometricOptions', () => _d.updateBiometricOptions(options));

  @override
  Future<Result<void>> setRandomizedKeypadEnabled(bool enabled) => _log(
      'setRandomizedKeypadEnabled', () => _d.setRandomizedKeypadEnabled(enabled));

  @override
  Future<Result<void>> setPatternVisibilityEnabled(bool enabled) => _log(
      'setPatternVisibilityEnabled',
      () => _d.setPatternVisibilityEnabled(enabled));

  @override
  Future<Result<void>> clearAll() => _log('clearAll', _d.clearAll);
}

/// Holds the REAL PIN result until [release] is called, modelling a slow
/// verification (PBKDF2) during which the user presses Back.
class _GatedManager extends _SpyManager {
  _GatedManager(super.d);

  final Completer<void> _gate = Completer<void>();
  bool pending = false;
  AuthAttemptResult? lastResult;

  Future<void> release() async => _gate.complete();

  @override
  Future<Result<AuthAttemptResult>> authenticatePin(String pin) async {
    pending = true;
    await _gate.future;
    final Result<AuthAttemptResult> real = await super.authenticatePin(pin);
    lastResult = real.valueOrNull;
    return real;
  }
}

/// A manager whose status is unreadable (storage failure).
class _FailingStatusManager extends _SpyManager {
  _FailingStatusManager() : super(AppContainer.inMemory().auth);

  @override
  Future<Result<CredentialState>> status() async =>
      Result.failure(StateError('simulated storage failure'));
}

/// Fake OS biometric stack (local_auth_android 2.3.0 semantics).
class _FakeOs extends LocalAuthPlatform {
  bool hardware = true;
  bool deviceSecure = true;
  List<BiometricType> enrolled = <BiometricType>[];
  final List<AuthenticationOptions> prompts = <AuthenticationOptions>[];

  @override
  Future<bool> authenticate({
    required String localizedReason,
    required Iterable<AuthMessages> authMessages,
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    prompts.add(options);
    if (enrolled.isNotEmpty) return true;
    if (!options.biometricOnly && deviceSecure) return true;
    throw const LocalAuthException(
      code: LocalAuthExceptionCode.noBiometricsEnrolled,
    );
  }

  @override
  Future<bool> deviceSupportsBiometrics() async => hardware;

  @override
  Future<List<BiometricType>> getEnrolledBiometrics() async =>
      hardware ? enrolled : <BiometricType>[];

  @override
  Future<bool> isDeviceSupported() async =>
      deviceSecure || (hardware && enrolled.isNotEmpty);

  @override
  Future<bool> stopAuthentication() async => true;
}
