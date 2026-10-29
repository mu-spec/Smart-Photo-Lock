import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// The OS layer is faked at the real plugin seam (LocalAuthPlatform.instance)
// so the production LocalAuthBiometricService runs unmodified.
// ignore: depend_on_referenced_packages
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/router.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/models/security_settings.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/credentials/biometric_options.dart';
import 'package:smart_app_lock/services/impl/local_auth_biometric_service.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/security/security_screen.dart';

/// H-3 (Phase 5 / Milestone 2): biometric unlock must be biometric-only.
/// The Android device PIN/pattern/password never satisfies Smart App Lock
/// authentication, cancelling a biometric prompt never costs an app
/// credential attempt, and "Biometric unlock" can only be enabled with a
/// genuinely enrolled biometric.
///
/// SIMULATED: the OS is a fake [LocalAuthPlatform] whose behaviour models
/// the documented AndroidX BiometricPrompt semantics. It proves the Dart
/// side; it is not device verification.
void main() {
  late _FakeOs os;

  setUp(() {
    os = _FakeOs();
    LocalAuthPlatform.instance = os;
  });

  const String appPin = '482916';

  /// Persists [legacyBiometricJson] as the stored biometric options, going
  /// through the real SecuritySettings JSON decoding path.
  Future<void> persistLegacyOptions(
    AppContainer c,
    Map<String, dynamic> legacyBiometricJson,
  ) async {
    final SecuritySettings current =
        (await c.securitySettings.getSettings()).valueOrNull!;
    final Map<String, dynamic> json = current.toJson()
      ..['biometricOptions'] = legacyBiometricJson;
    await c.securitySettings.saveSettings(SecuritySettings.fromJson(json));
  }

  // ---------------------------------------------------------------------
  // F1: biometricOnly is enforced at the platform bridge
  // ---------------------------------------------------------------------
  group('F1 bridge always requests a biometric-only prompt', () {
    test('default options', () async {
      await LocalAuthBiometricService()
          .authenticate(reason: 'r', options: BiometricOptions.defaults);
      await LocalAuthBiometricService().authenticate(reason: 'r');
      expect(os.biometricOnlyFlags, <bool>[true, true]);
    });

    test('explicit allowDeviceCredential:true is never honoured', () async {
      await LocalAuthBiometricService().authenticate(
        reason: 'r',
        options: const BiometricOptions(allowDeviceCredential: true),
      );
      await LocalAuthBiometricService().authenticate(
        reason: 'r',
        options: const BiometricOptions(
          allowStrongBiometrics: false,
          allowDeviceCredential: true,
        ),
      );
      expect(os.biometricOnlyFlags, <bool>[true, true]);
    });

    test('legacy decoded options (missing key, or true) stay biometric-only',
        () async {
      for (final Map<String, dynamic> legacy in <Map<String, dynamic>>[
        <String, dynamic>{},
        <String, dynamic>{'allowDeviceCredential': true},
        <String, dynamic>{
          'allowStrongBiometrics': true,
          'allowDeviceCredential': true,
          'requireConfirmation': true,
        },
      ]) {
        await LocalAuthBiometricService().authenticate(
          reason: 'r',
          options: BiometricOptions.fromJson(legacy),
        );
      }
      expect(os.biometricOnlyFlags, <bool>[true, true, true]);
    });

    test('requireConfirmation still maps to sensitiveTransaction', () async {
      await LocalAuthBiometricService().authenticate(
        reason: 'r',
        options: const BiometricOptions(requireConfirmation: false),
      );
      await LocalAuthBiometricService().authenticate(reason: 'r');
      expect(
        os.prompts.map((AuthenticationOptions o) => o.sensitiveTransaction),
        <bool>[false, true],
      );
    });
  });

  // ---------------------------------------------------------------------
  // The device PIN can never substitute (manager + real bridge)
  // ---------------------------------------------------------------------
  group('device-PIN-only success cannot authenticate', () {
    for (final MapEntry<String, Map<String, dynamic>> legacy
        in <String, Map<String, dynamic>>{
      'persisted device-credential-only options': <String, dynamic>{
        'allowStrongBiometrics': false,
        'allowDeviceCredential': true,
        'requireConfirmation': true,
      },
      'persisted pre-field options (missing key)': <String, dynamic>{},
    }.entries) {
      test(legacy.key, () async {
        // Screen lock set, fingerprint hardware, NOTHING enrolled: the only
        // way such a prompt can succeed is the device PIN.
        os
          ..enrolled = <BiometricType>[]
          ..deviceSecure = true;
        final AppContainer c =
            AppContainer.inMemory(biometrics: LocalAuthBiometricService());
        await c.auth.enrollPin(appPin);
        await persistLegacyOptions(c, legacy.value);
        await c.auth.authenticatePin('000000');
        await c.auth.authenticatePin('000000');

        final AuthAttemptResult r =
            (await c.auth.authenticateBiometric()).valueOrNull!;

        expect(r, isNot(isA<AuthSuccess>()));
        expect(os.deviceCredentialSuccesses, 0);
        expect(os.prompts.single.biometricOnly, isTrue);
        // The device-PIN path must not reset the app's failure counter.
        expect((await c.auth.status()).valueOrNull!.failedAttempts, 2);
      });
    }
  });

  // ---------------------------------------------------------------------
  // F2: defaults never allow the device credential
  // ---------------------------------------------------------------------
  group('F2 BiometricOptions defaults', () {
    test('constructor and JSON fallback default allowDeviceCredential:false',
        () {
      expect(const BiometricOptions().allowDeviceCredential, isFalse);
      expect(BiometricOptions.defaults.allowDeviceCredential, isFalse);
      expect(
        BiometricOptions.fromJson(const <String, dynamic>{})
            .allowDeviceCredential,
        isFalse,
      );
      expect(BiometricOptions.defaults.allowedKinds,
          <BiometricKind>{BiometricKind.strong});
    });

    test('legacy documents with allowDeviceCredential:true still decode', () {
      final BiometricOptions legacy = BiometricOptions.fromJson(
        const <String, dynamic>{'allowDeviceCredential': true},
      );
      expect(legacy.allowStrongBiometrics, isTrue);
      expect(BiometricOptions.fromJson(legacy.toJson()), legacy);
    });
  });

  // ---------------------------------------------------------------------
  // F3: enabling needs a genuinely enrolled biometric
  // ---------------------------------------------------------------------
  group('F3 Security screen enable flow', () {
    Future<AppContainer> pumpSecurity(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final AppContainer c =
          AppContainer.inMemory(biometrics: LocalAuthBiometricService());
      await c.auth.enrollPin(appPin);
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
      return c;
    }

    Future<void> tapBiometricRow(WidgetTester tester) async {
      final Finder row =
          find.widgetWithText(SecurityStatusItem, 'Biometric unlock');
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
    }

    testWidgets(
        'hardware present + secure screen lock but nothing enrolled is '
        'refused with a helpful message', (WidgetTester tester) async {
      os
        ..hardware = true
        ..enrolled = <BiometricType>[]
        ..deviceSecure = true;
      final AppContainer c = await pumpSecurity(tester);

      await tapBiometricRow(tester);

      expect(find.text('Biometric unlock enabled ✓'), findsNothing);
      expect(
        find.textContaining('No fingerprint or face unlock is enrolled'),
        findsOneWidget,
      );
      expect(
        (await c.securitySettings.getSettings()).valueOrNull!.biometricOptions,
        isNull,
      );
      expect(os.prompts, isEmpty);
    });

    testWidgets(
        'an enrolled biometric enables with allowDeviceCredential:false '
        '(even when the device is also secure)', (WidgetTester tester) async {
      os
        ..hardware = true
        ..enrolled = <BiometricType>[BiometricType.weak]
        ..deviceSecure = true;
      final AppContainer c = await pumpSecurity(tester);

      await tapBiometricRow(tester);

      // H-3 F4: the app PIN is verified before enabling.
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      for (final String d in appPin.split('')) {
        await tester.tap(find.byKey(Key('pin_key_$d')));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();

      expect(find.text('Biometric unlock enabled ✓'), findsOneWidget);
      final BiometricOptions stored =
          (await c.securitySettings.getSettings()).valueOrNull!
              .biometricOptions!;
      expect(stored.allowDeviceCredential, isFalse);
      expect(stored.allowStrongBiometrics, isTrue);
    });

    testWidgets('disabling needs no authentication',
        (WidgetTester tester) async {
      os.enrolled = <BiometricType>[BiometricType.strong];
      final AppContainer c = await pumpSecurity(tester);
      await c.auth.updateBiometricOptions(BiometricOptions.defaults);
      // Rebuild so the row reflects the enabled state.
      await tester.pumpWidget(const SizedBox());
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

      await tapBiometricRow(tester);

      expect(find.text('Biometric unlock disabled.'), findsOneWidget);
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(
        (await c.securitySettings.getSettings()).valueOrNull!.biometricOptions,
        isNull,
      );
      expect(os.prompts, isEmpty);
    });

    testWidgets('no biometric hardware is refused',
        (WidgetTester tester) async {
      os
        ..hardware = false
        ..enrolled = <BiometricType>[]
        ..deviceSecure = true;
      final AppContainer c = await pumpSecurity(tester);

      await tapBiometricRow(tester);

      expect(find.text('Biometric unlock enabled ✓'), findsNothing);
      expect(
        (await c.securitySettings.getSettings()).valueOrNull!.biometricOptions,
        isNull,
      );
    });
  });

  // ---------------------------------------------------------------------
  // F5: cancellation, system cancellation and timeout never count
  // ---------------------------------------------------------------------
  group('F5 biometric cancellation never costs an app credential attempt', () {
    Future<AppContainer> enabledContainer() async {
      os.enrolled = <BiometricType>[BiometricType.strong];
      final AppContainer c =
          AppContainer.inMemory(biometrics: LocalAuthBiometricService());
      await c.auth.enrollPin(appPin);
      await c.auth.updateBiometricOptions(BiometricOptions.defaults);
      return c;
    }

    for (final LocalAuthExceptionCode code in <LocalAuthExceptionCode>[
      LocalAuthExceptionCode.userCanceled,
      LocalAuthExceptionCode.systemCanceled,
      LocalAuthExceptionCode.timeout,
    ]) {
      test('${code.name} x3: no lockout, nothing counted, PIN still works',
          () async {
        final AppContainer c = await enabledContainer();
        os.throwCode = code;

        for (int i = 0; i < 3; i++) {
          final AuthAttemptResult r =
              (await c.auth.authenticateBiometric()).valueOrNull!;
          expect(r, isA<AuthFailure>(), reason: 'attempt ${i + 1}');
          expect((r as AuthFailure).reason, AuthFailureReason.cancelled);
        }
        final SecuritySettings s =
            (await c.securitySettings.getSettings()).valueOrNull!;
        expect(s.failedAttempts, 0);
        expect(s.lockedOutUntil, isNull);
        expect(s.lockoutStreak, 0);

        os.throwCode = null;
        expect((await c.auth.authenticatePin(appPin)).valueOrNull,
            isA<AuthSuccess>());
      });

      test('${code.name} neither increments nor resets earlier failures',
          () async {
        final AppContainer c = await enabledContainer();
        await c.auth.authenticatePin('000000');
        await c.auth.authenticatePin('000000');
        os.throwCode = code;

        final AuthAttemptResult r =
            (await c.auth.authenticateBiometric()).valueOrNull!;
        expect(r, isA<AuthFailure>());
        expect((r as AuthFailure).reason, AuthFailureReason.cancelled);
        expect((await c.auth.status()).valueOrNull!.failedAttempts, 2);

        // Wrong app PIN attempts still count normally: the third one locks.
        expect((await c.auth.authenticatePin('000000')).valueOrNull,
            isA<AuthLockedOut>());
      });
    }

    test('an active lockout is kept: no prompt, no change', () async {
      final AppContainer c = await enabledContainer();
      for (int i = 0; i < 3; i++) {
        await c.auth.authenticatePin('000000');
      }
      final SecuritySettings locked =
          (await c.securitySettings.getSettings()).valueOrNull!;
      expect(locked.lockedOutUntil, isNotNull);
      os.throwCode = LocalAuthExceptionCode.userCanceled;

      expect((await c.auth.authenticateBiometric()).valueOrNull,
          isA<AuthLockedOut>());
      final SecuritySettings after =
          (await c.securitySettings.getSettings()).valueOrNull!;
      expect(after.lockedOutUntil, locked.lockedOutUntil);
      expect(after.lockoutStreak, locked.lockoutStreak);
      expect(os.prompts, isEmpty);
    });

    test('a genuine non-cancel platform error still counts and never unlocks',
        () async {
      final AppContainer c = await enabledContainer();
      os.throwCode = LocalAuthExceptionCode.deviceError;
      final AuthAttemptResult r =
          (await c.auth.authenticateBiometric()).valueOrNull!;
      expect(r, isA<AuthFailure>());
      expect((r as AuthFailure).reason, AuthFailureReason.wrongCredential);
      expect((await c.auth.status()).valueOrNull!.failedAttempts, 1);
    });

    test('a rejected prompt (false) still counts and never unlocks', () async {
      final AppContainer c = await enabledContainer();
      os.biometricMatches = false;
      final AuthAttemptResult r =
          (await c.auth.authenticateBiometric()).valueOrNull!;
      expect(r, isA<AuthFailure>());
      expect((await c.auth.status()).valueOrNull!.failedAttempts, 1);
    });

    test('an OS biometric lockout is not counted and offers no device PIN',
        () async {
      final AppContainer c = await enabledContainer();
      os.throwCode = LocalAuthExceptionCode.temporaryLockout;
      final AuthAttemptResult r =
          (await c.auth.authenticateBiometric()).valueOrNull!;
      expect((r as AuthFailure).reason, AuthFailureReason.notAvailable);
      expect((await c.auth.status()).valueOrNull!.failedAttempts, 0);
      expect(os.prompts.single.biometricOnly, isTrue);
    });

    test('genuine biometric success still authenticates and resets counters',
        () async {
      final AppContainer c = await enabledContainer();
      await c.auth.authenticatePin('000000');
      final AuthAttemptResult r =
          (await c.auth.authenticateBiometric()).valueOrNull!;
      expect(r, isA<AuthSuccess>());
      expect((r as AuthSuccess).type, AuthType.biometric);
      expect((await c.auth.status()).valueOrNull!.failedAttempts, 0);
      expect(os.prompts.single.biometricOnly, isTrue);
    });
  });

  // ---------------------------------------------------------------------
  // End to end: the protected-app challenge (production wiring)
  // ---------------------------------------------------------------------
  group('protected-app challenge', () {
    Future<AppContainer> pumpApp(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final AppContainer c =
          AppContainer.inMemory(biometrics: LocalAuthBiometricService());
      await tester.pumpWidget(SmartAppLockApp(container: c));
      await tester.pumpAndSettle();
      return c;
    }

    Future<void> protectAndOpen(WidgetTester tester, AppContainer c) async {
      await c.protectedApps.add(
        ProtectedApp(
          packageName: 'com.whatsapp',
          label: 'com.whatsapp',
          addedAt: DateTime(2026, 10, 29),
        ),
      );
      await c.protectionBootstrap.synchronize();
      (c.accessibility as StaticAccessibilityLockService)
          .emitForegroundPackage('com.whatsapp');
      await tester.pumpAndSettle();
    }

    Object? sessionFor(AppContainer c) =>
        (c.accessController as DefaultAccessController)
            .sessionFor('com.whatsapp');

    Future<void> tapDigits(WidgetTester tester, String digits) async {
      await tester.pump(const Duration(milliseconds: 250));
      for (final String d in digits.split('')) {
        await tester.tap(find.byKey(Key('pin_key_$d')));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
    }

    testWidgets(
        'device-PIN-only prompt never unlocks (legacy device-credential '
        'options)', (WidgetTester tester) async {
      os
        ..enrolled = <BiometricType>[]
        ..deviceSecure = true;
      final AppContainer c = await pumpApp(tester);
      await c.auth.enrollPin(appPin);
      await persistLegacyOptions(c, <String, dynamic>{
        'allowStrongBiometrics': false,
        'allowDeviceCredential': true,
        'requireConfirmation': true,
      });
      await protectAndOpen(tester, c);
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      await tester.tap(find.byKey(const Key('pin_key_biometric')));
      await tester.pumpAndSettle();

      final StaticOverlayLockService overlay =
          c.overlay as StaticOverlayLockService;
      final StaticInstalledAppsService apps =
          c.installedAppsService as StaticInstalledAppsService;
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(sessionFor(c), isNull);
      expect(apps.launchAppCalls, 0);
      expect(overlay.hideLockChallengeCalls, 0);
      expect(os.deviceCredentialSuccesses, 0);
    });

    testWidgets(
        'three cancelled biometric prompts keep the challenge, grant nothing '
        'and leave the app PIN usable', (WidgetTester tester) async {
      os.enrolled = <BiometricType>[BiometricType.strong];
      final AppContainer c = await pumpApp(tester);
      await c.auth.enrollPin(appPin);
      await c.auth.updateBiometricOptions(BiometricOptions.defaults);
      await protectAndOpen(tester, c);
      os.throwCode = LocalAuthExceptionCode.userCanceled;

      for (int i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const Key('pin_key_biometric')));
        await tester.pumpAndSettle();
        expect(find.text('Biometric cancelled.'), findsOneWidget);
      }
      final StaticInstalledAppsService apps =
          c.installedAppsService as StaticInstalledAppsService;
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(sessionFor(c), isNull);
      expect(apps.launchAppCalls, 0);
      expect((await c.auth.status()).valueOrNull!.failedAttempts, 0);

      // Not locked out: the correct app PIN still unlocks normally.
      await tapDigits(tester, appPin);
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(sessionFor(c), isNotNull);
      expect(apps.launchedPackages, <String>['com.whatsapp']);
    });

    testWidgets('pattern challenge: cancellation keeps the challenge',
        (WidgetTester tester) async {
      os.enrolled = <BiometricType>[BiometricType.strong];
      final AppContainer c = await pumpApp(tester);
      await c.auth.enrollPattern(const <int>[3, 6, 9, 8]);
      await c.auth.updateBiometricOptions(BiometricOptions.defaults);
      await protectAndOpen(tester, c);
      os.throwCode = LocalAuthExceptionCode.systemCanceled;

      for (int i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const Key('pattern_key_biometric')));
        await tester.pumpAndSettle();
      }
      expect(find.byType(PatternUnlockScreen), findsOneWidget);
      expect(sessionFor(c), isNull);
      final SecuritySettings s =
          (await c.securitySettings.getSettings()).valueOrNull!;
      expect(s.failedAttempts, 0);
      expect(s.lockedOutUntil, isNull);
    });

    testWidgets('genuine biometric success still unlocks the protected app',
        (WidgetTester tester) async {
      os.enrolled = <BiometricType>[BiometricType.weak];
      final AppContainer c = await pumpApp(tester);
      await c.auth.enrollPin(appPin);
      await c.auth.updateBiometricOptions(BiometricOptions.defaults);
      await protectAndOpen(tester, c);

      await tester.tap(find.byKey(const Key('pin_key_biometric')));
      await tester.pumpAndSettle();

      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(sessionFor(c), isNotNull);
      expect(
        (c.installedAppsService as StaticInstalledAppsService)
            .launchedPackages,
        <String>['com.whatsapp'],
      );
      expect(os.prompts.single.biometricOnly, isTrue);
    });
  });
}

/// Fake OS biometric stack, modelling AndroidX BiometricPrompt semantics
/// as surfaced by local_auth_android 2.3.0:
///  * `deviceSupportsBiometrics` = biometric hardware present;
///  * `getEnrolledBiometrics` = enrolled AND usable biometrics;
///  * `isDeviceSupported` = device secure OR biometric usable;
///  * a prompt WITHOUT `biometricOnly` on a secure device can be satisfied
///    by the device PIN; a biometric-only prompt needs an enrolled biometric.
class _FakeOs extends LocalAuthPlatform {
  bool hardware = true;
  bool deviceSecure = true;
  List<BiometricType> enrolled = <BiometricType>[];

  /// Whether an enrolled biometric matches (false = OS rejection).
  bool biometricMatches = true;

  /// When set, every prompt ends with this platform error.
  LocalAuthExceptionCode? throwCode;

  final List<AuthenticationOptions> prompts = <AuthenticationOptions>[];
  int deviceCredentialSuccesses = 0;

  List<bool> get biometricOnlyFlags =>
      prompts.map((AuthenticationOptions o) => o.biometricOnly).toList();

  @override
  Future<bool> authenticate({
    required String localizedReason,
    required Iterable<AuthMessages> authMessages,
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    prompts.add(options);
    final LocalAuthExceptionCode? code = throwCode;
    if (code != null) {
      throw LocalAuthException(code: code);
    }
    if (enrolled.isNotEmpty) {
      return biometricMatches;
    }
    if (!options.biometricOnly && deviceSecure) {
      deviceCredentialSuccesses++;
      return true; // the user typed the phone's own PIN
    }
    throw LocalAuthException(
      code: hardware
          ? LocalAuthExceptionCode.noBiometricsEnrolled
          : LocalAuthExceptionCode.noBiometricHardware,
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
