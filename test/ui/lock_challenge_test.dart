import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/security/credentials/biometric_options.dart';
import 'package:smart_app_lock/services/biometric_service.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_screen_state_service.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/utilities/result.dart';

/// Phase 5D: the basic lock trigger end-to-end — when a protected
/// application becomes active, Smart App Lock presents the unlock
/// challenge through the production app wiring (monitor -> matcher ->
/// access controller -> challenge host -> router -> unlock screen).
void main() {
  Future<AppContainer> pumpApp(
    WidgetTester tester, {
    AppContainer? container,
    BiometricService? biometrics,
    DateTime Function()? accessClock,
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final AppContainer c = container ??
        AppContainer.inMemory(
          biometrics: biometrics,
          accessClock: accessClock,
        );
    await tester.pumpWidget(SmartAppLockApp(container: c));
    await tester.pumpAndSettle();
    return c;
  }

  /// The user opens another app: the detection-only accessibility
  /// service reports a window-state change (production fallback path).
  Future<void> openApp(
    WidgetTester tester,
    AppContainer container,
    String package,
  ) async {
    (container.accessibility as StaticAccessibilityLockService)
        .emitForegroundPackage(package);
    await tester.pumpAndSettle();
  }

  Future<void> protect(AppContainer container, String package) =>
      container.protectedApps.add(
        ProtectedApp(
          packageName: package,
          label: package,
          addedAt: DateTime(2026, 8, 21),
        ),
      );

  /// Phase 5I: the unlock session currently open for [package] (null =
  /// no session was granted — failed authentication must never create
  /// one).
  Object? sessionFor(AppContainer container, String package) =>
      (container.accessController as DefaultAccessController)
          .sessionFor(package);

  testWidgets(
      'leaving a protected app re-locks it immediately (Phase 5J)',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    // First activation challenges.
    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    final StaticOverlayLockService overlay =
        container.overlay as StaticOverlayLockService;
    expect(overlay.showLockChallengeCalls, 1);
    expect(overlay.lastLockPackage, 'com.whatsapp');
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(overlay.hideLockChallengeCalls, 1);
    final StaticInstalledAppsService apps =
        container.installedAppsService as StaticInstalledAppsService;
    expect(apps.launchAppCalls, 1);
    expect(apps.launchedPackages, <String>['com.whatsapp']);
    // Phase 5I positive control: ONLY the authenticated path grants.
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);

    // The user leaves WhatsApp for the launcher: the unlock session is
    // revoked IMMEDIATELY (no re-challenge for the launcher itself).
    await openApp(tester, container, 'com.example.launcher');
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNull);

    // Returning to WhatsApp challenges again right away.
    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
  });

  testWidgets(
      'screen-off revokes the session and resume re-challenges (Phase 5K)',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    // Unlock the protected app normally.
    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);

    // The device screen turns off: every session dies immediately.
    (container.screenState as StaticScreenStateService).emitScreenOff();
    await tester.pump();
    expect(sessionFor(container, 'com.whatsapp'), isNull);

    // The screen turns back on and the user returns to Smart App Lock:
    // the re-lock is enforced — the protected app is challenged again.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    // Authenticating again re-opens the session.
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);
  });

  testWidgets(
      'resume without a screen-off never re-challenges (Phase 5K)',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);

    // A plain return to the app (no screen-off in between) must NOT
    // re-challenge: the still-valid session stays intact.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);
  });

  testWidgets(
      'a configured grace period delays re-lock after leaving (Phase 5L)',
      (WidgetTester tester) async {
    DateTime clock = DateTime(2026, 8, 21, 9, 0);
    final AppContainer container = await pumpApp(
      tester,
      accessClock: () => clock,
    );
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');
    container.accessController.setGracePeriod(const Duration(seconds: 30));

    // Unlock the protected app.
    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);

    // Leave WhatsApp, then return 20 seconds later — within the grace
    // period: no re-challenge.
    await openApp(tester, container, 'com.example.launcher');
    clock = DateTime(2026, 8, 21, 9, 0, 20);
    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);

    // Leave again; now return AFTER the 30-second grace: the challenge
    // appears.
    await openApp(tester, container, 'com.example.launcher');
    clock = DateTime(2026, 8, 21, 9, 1, 10);
    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
  });

  testWidgets(
      're-lock is immediate — no grace window after leaving (Phase 5J)',
      (WidgetTester tester) async {
    // A controllable clock proves the re-lock happens well INSIDE the
    // old 2-minute session window: leaving ends the session at once.
    DateTime clock = DateTime(2026, 8, 21, 9, 0);
    final AppContainer container = await pumpApp(
      tester,
      accessClock: () => clock,
    );
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);

    // Only 30 seconds pass — deep inside the old inactivity window —
    // yet leaving and returning must challenge immediately.
    clock = DateTime(2026, 8, 21, 9, 0, 30);
    await openApp(tester, container, 'com.example.launcher');
    expect(sessionFor(container, 'com.whatsapp'), isNull);
    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
  });

  testWidgets('an unprotected app produces no challenge',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');

    await openApp(tester, container, 'com.example.chat');

    expect(find.byType(PinUnlockScreen), findsNothing);
    final StaticOverlayLockService overlay =
        container.overlay as StaticOverlayLockService;
    expect(overlay.showLockChallengeCalls, 0);
  });

  testWidgets('no enrolled credential: no challenge (fail-safe)',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');

    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(find.byType(PatternUnlockScreen), findsNothing);
  });

  testWidgets('a pattern-only user is challenged with the pattern screen',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPattern(const <int>[3, 6, 9, 8]);
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');

    expect(find.byType(PatternUnlockScreen), findsOneWidget);
    expect(find.byType(PinUnlockScreen), findsNothing);
  });

  testWidgets('the PRIMARY credential decides the challenge screen: '
      'pattern-primary users get the pattern (Phase 5F)',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    // PIN enrolled first, pattern second -> primary is the pattern.
    await container.auth.enrollPin('1234');
    await container.auth.enrollPattern(const <int>[3, 6, 9, 8]);
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');

    expect(find.byType(PatternUnlockScreen), findsOneWidget);
    expect(find.byType(PinUnlockScreen), findsNothing);
  });

  testWidgets('the PRIMARY credential decides the challenge screen: '
      'PIN-primary users get the PIN (Phase 5F)',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    // Pattern enrolled first, PIN second -> primary is the PIN.
    await container.auth.enrollPattern(const <int>[3, 6, 9, 8]);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');

    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(find.byType(PatternUnlockScreen), findsNothing);
  });

  testWidgets(
      'a correct pattern unlocks the session and launches the app '
      '(Phase 5F)', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPattern(const <int>[3, 6, 9, 8]);
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PatternUnlockScreen), findsOneWidget);

    await drawPattern(tester, const <int>[3, 6, 9, 8]);
    await tester.pumpAndSettle();

    expect(find.byType(PatternUnlockScreen), findsNothing);
    final StaticOverlayLockService overlay =
        container.overlay as StaticOverlayLockService;
    expect(overlay.hideLockChallengeCalls, 1);
    final StaticInstalledAppsService apps =
        container.installedAppsService as StaticInstalledAppsService;
    expect(apps.launchAppCalls, 1);
    expect(apps.launchedPackages, <String>['com.whatsapp']);

    // The open unlock window suppresses an immediate re-challenge.
    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PatternUnlockScreen), findsNothing);
  });

  testWidgets('a wrong pattern keeps the challenge up and the app blocked '
      '(Phase 5F)', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPattern(const <int>[3, 6, 9, 8]);
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PatternUnlockScreen), findsOneWidget);

    await drawPattern(tester, const <int>[1, 2, 3, 5]);
    await tester.pumpAndSettle();

    expect(find.byType(PatternUnlockScreen), findsOneWidget);
    final StaticInstalledAppsService apps =
        container.installedAppsService as StaticInstalledAppsService;
    expect(apps.launchAppCalls, 0);
    // Phase 5I: failed authentication never grants a session.
    expect(sessionFor(container, 'com.whatsapp'), isNull);
  });

  testWidgets('cancelling the pattern challenge leaves the app blocked '
      '(Phase 5F)', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPattern(const <int>[3, 6, 9, 8]);
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PatternUnlockScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(PatternUnlockScreen), findsNothing);
    final StaticInstalledAppsService apps =
        container.installedAppsService as StaticInstalledAppsService;
    expect(apps.launchAppCalls, 0);
    // Phase 5I: a cancelled challenge never grants a session.
    expect(sessionFor(container, 'com.whatsapp'), isNull);

    // No unlock window either: the next activation challenges again.
    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PatternUnlockScreen), findsOneWidget);
  });


  testWidgets('a wrong PIN keeps the challenge up and the app blocked '
      '(Phase 5E)', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    for (final String digit in <String>['9', '9', '9', '9']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }

    // Still locked: the screen stays, the error is visible, and the
    // protected app was never launched.
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(find.textContaining(PinUnlockScreen.wrongPinPrefix),
        findsOneWidget);
    final StaticInstalledAppsService apps =
        container.installedAppsService as StaticInstalledAppsService;
    expect(apps.launchAppCalls, 0);
    // Phase 5I: failed authentication never grants a session.
    expect(sessionFor(container, 'com.whatsapp'), isNull);
  });

  testWidgets('cancelling the challenge leaves the app blocked '
      '(Phase 5E)', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    // The user backs out instead of entering the PIN.
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(PinUnlockScreen), findsNothing);
    final StaticInstalledAppsService apps =
        container.installedAppsService as StaticInstalledAppsService;
    expect(apps.launchAppCalls, 0);
    // Phase 5I: a cancelled challenge never grants a session.
    expect(sessionFor(container, 'com.whatsapp'), isNull);
    // No unlock window either: the next activation challenges again.
    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
  });

  testWidgets('a failed bring-to-front presents no challenge',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');
    (container.overlay as StaticOverlayLockService).showLockChallengeSucceeds =
        false;

    await openApp(tester, container, 'com.whatsapp');

    expect(find.byType(PinUnlockScreen), findsNothing);
  });

  // -- biometric (Phase 5G) ------------------------------------------------

  testWidgets(
      'biometric success on the PIN challenge unlocks and launches the '
      'app', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(
      tester,
      biometrics: const _FakeBiometricService(supported: true, passes: true),
    );
    await container.auth.enrollPin('1234');
    await container.auth.updateBiometricOptions(const BiometricOptions());
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(find.byKey(const Key('pin_key_biometric')), findsOneWidget);

    await tester.tap(find.byKey(const Key('pin_key_biometric')));
    await tester.pumpAndSettle();

    // Biometric passed: the challenge popped, the session is open and
    // the protected app was launched.
    expect(find.byType(PinUnlockScreen), findsNothing);
    final StaticInstalledAppsService apps =
        container.installedAppsService as StaticInstalledAppsService;
    expect(apps.launchAppCalls, 1);
    expect(apps.launchedPackages, <String>['com.whatsapp']);

    // The open unlock window suppresses an immediate re-challenge.
    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsNothing);
  });

  testWidgets(
      'biometric success on the pattern challenge unlocks and launches '
      'the app', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(
      tester,
      biometrics: const _FakeBiometricService(supported: true, passes: true),
    );
    await container.auth.enrollPattern(const <int>[3, 6, 9, 8]);
    await container.auth.updateBiometricOptions(const BiometricOptions());
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PatternUnlockScreen), findsOneWidget);
    expect(find.byKey(const Key('pattern_key_biometric')), findsOneWidget);

    await tester.tap(find.byKey(const Key('pattern_key_biometric')));
    await tester.pumpAndSettle();

    expect(find.byType(PatternUnlockScreen), findsNothing);
    final StaticInstalledAppsService apps =
        container.installedAppsService as StaticInstalledAppsService;
    expect(apps.launchAppCalls, 1);
    expect(apps.launchedPackages, <String>['com.whatsapp']);
  });

  testWidgets('biometric failure keeps the protected app blocked '
      '(Phase 5G)', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(
      tester,
      biometrics: const _FakeBiometricService(supported: true, passes: false),
    );
    await container.auth.enrollPin('1234');
    await container.auth.updateBiometricOptions(const BiometricOptions());
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    await tester.tap(find.byKey(const Key('pin_key_biometric')));
    await tester.pumpAndSettle();

    // Failed biometrics leave the challenge up and the app blocked.
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    final StaticInstalledAppsService apps =
        container.installedAppsService as StaticInstalledAppsService;
    expect(apps.launchAppCalls, 0);
    // Phase 5I: failed authentication never grants a session.
    expect(sessionFor(container, 'com.whatsapp'), isNull);
  });

  testWidgets('biometric not enrolled -> no biometric key on the '
      'challenge', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');

    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(find.byKey(const Key('pin_key_biometric')), findsNothing);
  });
  /// Draws [nodes] on the unlock screen's pattern grid: bounds-derived
  /// node centers, a small horizontal arena-winning move first, then
  /// micro-stepped device-like strokes (mirrors the pattern-suite
  /// helper — the challenge flow uses the same production grid).
  Future<void> drawPattern(WidgetTester tester, List<int> nodes) async {
    // Settle ALL pending animations before reading bounds (shake
    // feedback runs 420ms and the view switcher fades 200ms).
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

    final TestGesture gesture =
        await tester.startGesture(center(nodes.first));
    await tester.pump();
    // Win the gesture arena from the enclosing scrollable with a small
    // HORIZONTAL movement before any vertical leg is drawn.
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();

    Offset current = center(nodes.first).translate(20, 0);
    for (final int node in nodes.skip(1)) {
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
  }
}

/// Deterministic biometric fake for the challenge-flow tests (Phase 5G).
class _FakeBiometricService implements BiometricService {
  const _FakeBiometricService({required this.supported, required this.passes});

  final bool supported;
  final bool passes;

  @override
  Future<Result<bool>> isSupported() async => Result.success(supported);

  @override
  Future<Result<Set<BiometricKind>>> availableKinds() async =>
      Result.success(const <BiometricKind>{BiometricKind.strong});

  @override
  Future<Result<bool>> authenticate({
    required String reason,
    BiometricOptions? options,
  }) async =>
      Result.success(passes);
}
