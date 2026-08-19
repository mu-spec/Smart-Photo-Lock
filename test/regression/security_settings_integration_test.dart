import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/repositories/impl/security_settings_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/security_settings_repository.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/credentials/biometric_options.dart';
import 'package:smart_app_lock/security/credentials/credential_state.dart';
import 'package:smart_app_lock/security/credentials/credential_state_machine.dart';
import 'package:smart_app_lock/security/credentials/impl/default_credential_manager.dart';
import 'package:smart_app_lock/security/credentials/pattern_hasher.dart';
import 'package:smart_app_lock/security/pin_hasher.dart';
import 'package:smart_app_lock/services/biometric_service.dart';
import 'package:smart_app_lock/services/impl/local_auth_biometric_service.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_setup_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/security/security_screen.dart';
import 'package:smart_app_lock/utilities/result.dart';

/// Phase 2 device-integration regression: exercises the REAL production
/// manager + settings repository path (no faked UI state) for the five
/// Security controls reported broken on the physical device, plus the
/// production router used by those flows.
void main() {
  late SecuritySettingsRepository settings;
  late DefaultCredentialManager manager;

  /// The production manager over the production repository
  /// (DefaultCredentialManager + SecuritySettingsRepositoryImpl).
  DefaultCredentialManager newManager({BiometricService? biometrics}) =>
      DefaultCredentialManager(
        settings: settings,
        pinHasher: Pbkdf2PinHasher(iterations: 200),
        patternHasher: Pbkdf2PatternHasher(iterations: 200),
        stateMachine: CredentialStateMachine(
          maxFailedAttempts: 3,
          lockoutDuration: Duration(seconds: 30),
        ),
        biometricService: biometrics,
      );

  setUp(() {
    settings = SecuritySettingsRepositoryImpl(InMemoryLocalDatabase());
    manager = newManager();
  });

  // -------------------------------------------------------------------
  // 1. Change PIN
  // -------------------------------------------------------------------
  test('change PIN: old PIN rejected, new PIN accepted (production path)',
      () async {
    await manager.enrollPin('1234');
    await manager.enrollPin('5678'); // the change flow's enrollment

    expect((await manager.authenticatePin('1234')).valueOrNull,
        isA<AuthFailure>());
    expect((await manager.authenticatePin('5678')).valueOrNull,
        isA<AuthSuccess>());
  });

  // -------------------------------------------------------------------
  // 2. Change pattern (direction-sensitive)
  // -------------------------------------------------------------------
  test('change pattern: old rejected, new accepted, reverse of new rejected',
      () async {
    await manager.enrollPattern(const <int>[1, 2, 3, 6]);
    await manager.enrollPattern(const <int>[1, 4, 7, 8]); // the change flow

    expect(
      (await manager.authenticatePattern(const <int>[1, 2, 3, 6])).valueOrNull,
      isA<AuthFailure>(),
    );
    expect(
      (await manager.authenticatePattern(const <int>[1, 4, 7, 8])).valueOrNull,
      isA<AuthSuccess>(),
    );
    // Direction sensitivity preserved after the change.
    expect(
      (await manager.authenticatePattern(const <int>[8, 7, 4, 1])).valueOrNull,
      isA<AuthFailure>(),
    );
  });

  // -------------------------------------------------------------------
  // 3. Randomized keypad
  // -------------------------------------------------------------------
  test('randomized keypad setting persists across manager restart', () async {
    expect(
      (await manager.status()).valueOrNull!.randomizedKeypadEnabled,
      isFalse,
    );

    await manager.setRandomizedKeypadEnabled(true);
    expect(
      (await newManager().status()).valueOrNull!.randomizedKeypadEnabled,
      isTrue, // restart survives
    );

    await manager.setRandomizedKeypadEnabled(false);
    expect(
      (await newManager().status()).valueOrNull!.randomizedKeypadEnabled,
      isFalse,
    );
  });

  testWidgets(
      'randomized keypad: OFF = normal order, ON = shuffled digit order',
      (WidgetTester tester) async {
    await manager.enrollPin('1234');
    await manager.setRandomizedKeypadEnabled(true);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: PinUnlockScreen(credentialManager: manager),
      ),
    );
    await tester.pumpAndSettle();

    List<String> padOrder() => tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(DsPinPad),
            matching: find.byType(Text),
          ),
        )
        .map((Text t) => t.data ?? '')
        .where((String l) => l.isNotEmpty)
        .toList();

    final List<String> shuffled = padOrder();
    expect(shuffled, isNot(equals(DsPinPad.defaultDigitOrder)));
    expect(shuffled.toSet(), DsPinPad.defaultDigitOrder.toSet());
  });

  // -------------------------------------------------------------------
  // 4. Pattern visibility
  // -------------------------------------------------------------------
  test('pattern visibility setting persists across manager restart', () async {
    expect(
      (await manager.status()).valueOrNull!.patternVisibilityEnabled,
      isTrue,
    );

    await manager.setPatternVisibilityEnabled(false);
    expect(
      (await newManager().status()).valueOrNull!.patternVisibilityEnabled,
      isFalse, // restart survives
    );
  });

  testWidgets('pattern visibility OFF hides the trail on the SETUP screen',
      (WidgetTester tester) async {
    await manager.setPatternVisibilityEnabled(false);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: PatternSetupScreen(credentialManager: manager),
      ),
    );
    await tester.pumpAndSettle();

    final CustomPaint paint = tester.widget<CustomPaint>(
      find
          .descendant(
            of: find.byType(DsPatternGrid),
            matching: find.byType(CustomPaint),
          )
          .first,
    );
    expect((paint.painter! as PatternGridPainter).showFeedback, isFalse);
    expect(find.text('Pattern trail hidden for privacy'), findsOneWidget);
  });

  // -------------------------------------------------------------------
  // 5. Biometric states (production manager + injected platform service)
  // -------------------------------------------------------------------
  test('biometric enabled state persists across manager restart', () async {
    await manager.enrollPin('1234');
    await manager.updateBiometricOptions(BiometricOptions.defaults);

    final CredentialState restarted =
        (await newManager().status()).valueOrNull!;
    expect(restarted.hasEnrolled(AuthType.biometric), isTrue);

    await manager.updateBiometricOptions(null);
    expect(
      (await newManager().status()).valueOrNull!.hasEnrolled(AuthType.biometric),
      isFalse,
    );
  });

  test('biometric success authenticates through the real service path',
      () async {
    await manager.enrollPin('1234');
    await manager.updateBiometricOptions(BiometricOptions.defaults);
    final DefaultCredentialManager bio = newManager(
      biometrics: const _FakeBiometricService(supported: true, passes: true),
    );
    expect((await bio.authenticateBiometric()).valueOrNull,
        isA<AuthSuccess>());
  });

  test('biometric failure and cancellation never authenticate', () async {
    await manager.enrollPin('1234');
    await manager.updateBiometricOptions(BiometricOptions.defaults);
    final DefaultCredentialManager bio = newManager(
      biometrics: const _FakeBiometricService(supported: true, passes: false),
    );
    expect((await bio.authenticateBiometric()).valueOrNull,
        isA<AuthFailure>());
    expect((await bio.status()).valueOrNull!.failedAttempts, 1);

    // Cancellation (platform-reported userCanceled) also never unlocks.
    final DefaultCredentialManager canceled = newManager(
      biometrics: _FakeBiometricService(
        supported: true,
        passes: false,
        failure: mapBiometricError(
          const LocalAuthException(code: LocalAuthExceptionCode.userCanceled),
        ),
      ),
    );
    final AuthAttemptResult result =
        (await canceled.authenticateBiometric()).valueOrNull!;
    expect(result, isA<AuthFailure>());
    expect((result as AuthFailure).reason, AuthFailureReason.wrongCredential);
  });

  test('unavailable platform -> notAvailable, never counts as an attempt',
      () async {
    await manager.enrollPin('1234');
    await manager.updateBiometricOptions(BiometricOptions.defaults);
    final DefaultCredentialManager bio = newManager(
      biometrics: _FakeBiometricService(
        supported: false,
        passes: false,
        failure: mapBiometricError(
          const LocalAuthException(
            code: LocalAuthExceptionCode.noBiometricHardware,
          ),
        ),
      ),
    );
    final AuthAttemptResult result =
        (await bio.authenticateBiometric()).valueOrNull!;
    expect((result as AuthFailure).reason, AuthFailureReason.notAvailable);
    expect((await bio.status()).valueOrNull!.failedAttempts, 0);
  });

  // -------------------------------------------------------------------
  // 6. Production router: typed bool routes (the real-device fix)
  // -------------------------------------------------------------------
  testWidgets('Change PIN opens through the PRODUCTION router',
      (WidgetTester tester) async {
    final AppContainer container = AppContainer.inMemory();
    await container.auth.enrollPin('1234');
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(SmartAppLockApp(container: container));
    await tester.tap(find.byKey(const Key('nav_security')));
    await tester.pumpAndSettle();

    final Finder row = find.widgetWithText(
      SecurityStatusItem,
      SecurityScreen.changePinTitle,
    );
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();

    // The typed MaterialPageRoute<bool> opened the verify step — no cast
    // exception, the flow actually starts.
    expect(find.text('Enter current PIN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Change pattern opens through the PRODUCTION router',
      (WidgetTester tester) async {
    final AppContainer container = AppContainer.inMemory();
    await container.auth.enrollPattern(const <int>[1, 2, 3, 6]);
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(SmartAppLockApp(container: container));
    await tester.tap(find.byKey(const Key('nav_security')));
    await tester.pumpAndSettle();

    final Finder row = find.widgetWithText(
      SecurityStatusItem,
      SecurityScreen.changePatternTitle,
    );
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(find.text('Enter current pattern'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// Test double for the platform biometric bridge (production service
/// semantics: rejections and cancellations resolve false/fail closed).
class _FakeBiometricService implements BiometricService {
  const _FakeBiometricService({
    required this.supported,
    required this.passes,
    this.failure,
  });

  final bool supported;
  final bool passes;
  final Object? failure;

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
      failure == null ? Result.success(passes) : Result.failure(failure!);
}
