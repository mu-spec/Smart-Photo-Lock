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

  testWidgets('Back cannot dismiss the pattern challenge (Phase 5N)',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPattern(const <int>[3, 6, 9, 8]);
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PatternUnlockScreen), findsOneWidget);

    // Back-press: the challenge RE-PRESENTS instead of exposing the
    // app UI — and it never grants a session or launches the app.
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(PatternUnlockScreen), findsOneWidget);
    final StaticInstalledAppsService apps =
        container.installedAppsService as StaticInstalledAppsService;
    expect(apps.launchAppCalls, 0);
    // Phase 5I: a dismissed challenge never grants a session.
    expect(sessionFor(container, 'com.whatsapp'), isNull);

    // The challenge survives repeated back presses too.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(PatternUnlockScreen), findsOneWidget);
    expect(apps.launchAppCalls, 0);

    // Only the correct pattern ends the loop and unlocks.
    await drawPattern(tester, const <int>[3, 6, 9, 8]);
    await tester.pumpAndSettle();
    expect(find.byType(PatternUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);
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

  testWidgets('Back cannot dismiss the PIN challenge (Phase 5N)',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    // The user backs out instead of entering the PIN: the challenge
    // re-presents — Back can never walk past it into the app UI.
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(PinUnlockScreen), findsOneWidget);
    final StaticInstalledAppsService apps =
        container.installedAppsService as StaticInstalledAppsService;
    expect(apps.launchAppCalls, 0);
    // Phase 5I: a dismissed challenge never grants a session.
    expect(sessionFor(container, 'com.whatsapp'), isNull);

    // Only the correct PIN ends the loop.
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);
    expect(apps.launchAppCalls, 1);
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
  // -- Home-button hardening (Phase 5M) --------------------------------------

  /// Simulates the Home button / a COMPLETED home-swipe gesture:
  /// Android fires `inactive` when the swipe starts and `paused` once
  /// the task is actually covered. Only the `paused` counts as a leave
  /// (Phase 5P).
  Future<void> pressHome(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
  }

  /// Simulates a CANCELLED gesture (or the notification shade, a
  /// permission dialog, or split-screen peeking): `inactive` fires and
  /// the app returns to `resumed` WITHOUT ever pausing. The challenge
  /// must stay untouched (Phase 5P).
  Future<void> cancelledGesture(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  }

  /// Simulates returning to Smart App Lock.
  Future<void> returnToApp(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  }

  testWidgets(
      'pressing Home while the challenge is up dismisses it without '
      'granting (Phase 5M)', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    await pressHome(tester);

    // The challenge is dismissed, and Home-press dismissal never
    // grants a session or launches the app (5I: pop resolves null).
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNull);
    final StaticInstalledAppsService apps =
        container.installedAppsService as StaticInstalledAppsService;
    expect(apps.launchAppCalls, 0);
  });

  testWidgets(
      're-opening the protected app after Home re-challenges instead of '
      'dropping the requirement (Phase 5M)', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    // Home press dismisses the challenge.
    await pressHome(tester);
    expect(find.byType(PinUnlockScreen), findsNothing);

    // While away, the user goes Home then opens WhatsApp again: the
    // accessibility path reports the transition and the challenge must
    // come back — NOT be dropped by a stuck busy flag.
    await openApp(tester, container, 'com.example.launcher');
    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    // Returning to the app keeps the challenge presented.
    await returnToApp(tester);
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    // The correct PIN grants and launches exactly once.
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);
    final StaticInstalledAppsService apps =
        container.installedAppsService as StaticInstalledAppsService;
    expect(apps.launchAppCalls, 1);
    expect(apps.launchedPackages, <String>['com.whatsapp']);
  });

  testWidgets(
      'a requirement arriving during a challenge re-presents after it '
      'closes (Phase 5M)', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');
    await protect(container, 'com.example.maps');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    // While the WhatsApp challenge is up, Maps becomes foreground: the
    // requirement is re-queued, not dropped.
    await openApp(tester, container, 'com.example.maps');
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    // Complete the WhatsApp challenge with the correct PIN.
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    await tester.pumpAndSettle(); // post-frame re-presentation

    // The queued Maps challenge appears.
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    final StaticOverlayLockService overlay =
        container.overlay as StaticOverlayLockService;
    expect(overlay.lastLockPackage, 'com.example.maps');

    // Phase 5N: Back cannot dismiss the re-presented challenge either —
    // no Maps session, no Maps launch, and the challenge stays up.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(sessionFor(container, 'com.example.maps'), isNull);
    final StaticInstalledAppsService apps =
        container.installedAppsService as StaticInstalledAppsService;
    expect(apps.launchAppCalls, 1); // WhatsApp only
  });

  // -- recents hardening (Phase 5O) ------------------------------------------

  testWidgets(
      'the secure window arms while a challenge is up and clears after '
      'the lock loop ends (Phase 5O)', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');
    final StaticOverlayLockService overlay =
        container.overlay as StaticOverlayLockService;

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(overlay.secureWindow, isTrue);

    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(overlay.secureWindow, isFalse);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);
  });

  testWidgets(
      'tapping OUR task in recents re-presents the interrupted challenge '
      '(Phase 5O)', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');
    final StaticOverlayLockService overlay =
        container.overlay as StaticOverlayLockService;

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(overlay.secureWindow, isTrue);

    // Recents: the task switcher covers Smart App Lock (inactive),
    // then the user taps OUR task again (resumed).
    await pressHome(tester);
    expect(find.byType(PinUnlockScreen), findsNothing);
    await returnToApp(tester);

    // The interrupted challenge re-presents; the secure window stays
    // armed through the cycle.
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(overlay.secureWindow, isTrue);
    expect(sessionFor(container, 'com.whatsapp'), isNull);

    // Completing it clears the secure window and grants normally.
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(overlay.secureWindow, isFalse);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);
  });

  testWidgets(
      'tapping the PROTECTED app task in recents while backgrounded '
      'brings the challenge back (Phase 5O)', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');
    final StaticOverlayLockService overlay =
        container.overlay as StaticOverlayLockService;

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    // Recents dismisses the challenge (no grant, no launch).
    await pressHome(tester);
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNull);
    final StaticInstalledAppsService apps =
        container.installedAppsService as StaticInstalledAppsService;
    expect(apps.launchAppCalls, 0);

    // While Smart App Lock is still backgrounded, the user taps
    // WhatsApp's task in recents: detection fires and the challenge
    // comes straight back — the protected app is never exposed.
    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(overlay.secureWindow, isTrue);
    expect(overlay.showLockChallengeCalls, greaterThanOrEqualTo(2));
    expect(sessionFor(container, 'com.whatsapp'), isNull);
    expect(apps.launchAppCalls, 0);

    // Returning to our task keeps the challenge presented.
    await returnToApp(tester);
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    // Only the PIN ends it.
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(overlay.secureWindow, isFalse);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);
  });

  // -- gesture navigation hardening (Phase 5P) --------------------------------

  testWidgets(
      'a CANCELLED home-swipe gesture never dismisses the challenge '
      '(Phase 5P)', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');
    final StaticOverlayLockService overlay =
        container.overlay as StaticOverlayLockService;

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    final int showCalls = overlay.showLockChallengeCalls;

    // Gesture starts (inactive) and the user lets go without leaving
    // (resumed): the challenge must stay exactly where it is — no
    // dismiss flicker, no re-presentation, no extra bring-to-front.
    await cancelledGesture(tester);

    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(overlay.secureWindow, isTrue);
    expect(overlay.showLockChallengeCalls, showCalls);
    expect(sessionFor(container, 'com.whatsapp'), isNull);

    // The PIN still completes the untouched challenge.
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);
  });

  testWidgets(
      'the notification shade (transient inactive) never dismisses the '
      'challenge (Phase 5P)', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');
    final StaticOverlayLockService overlay =
        container.overlay as StaticOverlayLockService;

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    // Shade down, shade up — two transient inactive/resumed cycles.
    await cancelledGesture(tester);
    await cancelledGesture(tester);

    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(overlay.secureWindow, isTrue);
    expect(sessionFor(container, 'com.whatsapp'), isNull);
  });

  testWidgets(
      'a COMPLETED home-swipe (inactive -> paused) dismisses and '
      're-challenges on return (Phase 5P)', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');
    final StaticOverlayLockService overlay =
        container.overlay as StaticOverlayLockService;

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    await pressHome(tester);
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNull);

    await returnToApp(tester);
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(overlay.secureWindow, isTrue);
    expect(sessionFor(container, 'com.whatsapp'), isNull);
  });

  testWidgets(
      'the hidden state counts as a real leave (Phase 5P)',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pumpAndSettle();

    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNull);

    await returnToApp(tester);
    expect(find.byType(PinUnlockScreen), findsOneWidget);
  });

  testWidgets(
      'the edge-back gesture on the challenge re-presents it (5N + 5P '
      'interaction)', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');
    final StaticOverlayLockService overlay =
        container.overlay as StaticOverlayLockService;

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    // An edge-back gesture pops the route exactly like the Back button:
    // the challenge re-presents, the secure window stays armed, and no
    // session is ever created.
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(overlay.secureWindow, isTrue);
    expect(sessionFor(container, 'com.whatsapp'), isNull);

    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);
  });

  testWidgets(
      'a rapid cancel-then-complete gesture sequence stays secure '
      '(Phase 5P)', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    // Cancel once (challenge stays), then complete the gesture.
    await cancelledGesture(tester);
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    await pressHome(tester);
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNull);

    // Returning brings the challenge back — and only the PIN ends it.
    await returnToApp(tester);
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    final StaticInstalledAppsService apps =
        container.installedAppsService as StaticInstalledAppsService;
    expect(apps.launchAppCalls, 0);

    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);
    expect(apps.launchAppCalls, 1);
  });

  // -- rapid switching (Phase 5Q) --------------------------------------------

  testWidgets(
      'rapid protected->unprotected->protected never stacks challenges '
      '(Phase 5Q)', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');
    final StaticOverlayLockService overlay =
        container.overlay as StaticOverlayLockService;
    final StaticAccessibilityLockService a11y =
        container.accessibility as StaticAccessibilityLockService;

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    final int shows = overlay.showLockChallengeCalls;

    // Fire the whole protected -> unprotected -> protected -> ... storm
    // with no frames in between: nothing may stack a second challenge.
    a11y.emitForegroundPackage('com.example.launcher');
    a11y.emitForegroundPackage('com.whatsapp');
    a11y.emitForegroundPackage('com.example.launcher');
    a11y.emitForegroundPackage('com.whatsapp');
    await tester.pumpAndSettle();

    // Exactly ONE challenge at any moment; no extra bring-to-fronts
    // while the current challenge is still up.
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(overlay.showLockChallengeCalls, shows);

    // Completing the challenge ends the loop: the queued WhatsApp
    // requirement re-evaluates against the fresh grant (allow), so no
    // double challenge — and the secure window clears.
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(overlay.secureWindow, isFalse);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);
    final StaticInstalledAppsService apps =
        container.installedAppsService as StaticInstalledAppsService;
    expect(apps.launchAppCalls, 1);
    expect(apps.launchedPackages, <String>['com.whatsapp']);
  });

  testWidgets(
      'rapid switching with a grace period never re-challenges inside '
      'the window (Phase 5Q)', (WidgetTester tester) async {
    DateTime clock = DateTime(2026, 8, 21, 9, 0);
    final AppContainer container = await pumpApp(
      tester,
      accessClock: () => clock,
    );
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');
    container.accessController.setGracePeriod(const Duration(seconds: 30));
    final StaticAccessibilityLockService a11y =
        container.accessibility as StaticAccessibilityLockService;

    // Unlock once.
    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);

    // Three rapid leave/return cycles, each 10s apart — all inside the
    // 30-second grace: no challenge may appear.
    for (int i = 0; i < 3; i++) {
      a11y.emitForegroundPackage('com.example.launcher');
      await tester.pumpAndSettle(); // departure processed at the old clock
      clock = clock.add(const Duration(seconds: 10));
      a11y.emitForegroundPackage('com.whatsapp');
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsNothing,
          reason: 'cycle ${i + 1} must stay inside the grace window');
    }

    // One more leave, then a return past the grace: the challenge
    // returns — exactly once, never stacked.
    a11y.emitForegroundPackage('com.example.launcher');
    await tester.pumpAndSettle(); // departure processed at the old clock
    clock = clock.add(const Duration(seconds: 40));
    a11y.emitForegroundPackage('com.whatsapp');
    await tester.pumpAndSettle();
    expect(find.byType(PinUnlockScreen), findsOneWidget);
  });

  // -- screen sleep/wake (Phase 5R) -------------------------------------------

  /// Turns the device screen off and back on.
  Future<void> sleepWake(WidgetTester tester, AppContainer container) async {
    final StaticScreenStateService screen =
        container.screenState as StaticScreenStateService;
    screen.emitScreenOff();
    await tester.pump();
    screen.emitScreenOn();
    await tester.pumpAndSettle();
  }

  testWidgets(
      'waking into the protected app re-challenges immediately '
      '(Phase 5R)', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    // Unlock WhatsApp normally.
    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);

    // The screen sleeps and wakes with WhatsApp still the foreground:
    // the wake enforcement presents the challenge immediately.
    await sleepWake(tester, container);
    expect(sessionFor(container, 'com.whatsapp'), isNull);
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    final StaticInstalledAppsService apps =
        container.installedAppsService as StaticInstalledAppsService;
    expect(apps.launchAppCalls, 1); // only the original unlock launched

    // The correct PIN ends the wake challenge.
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);
  });

  testWidgets(
      'sleep/wake while a challenge is up never stacks (Phase 5R)',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');
    final StaticOverlayLockService overlay =
        container.overlay as StaticOverlayLockService;

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    await sleepWake(tester, container);
    await sleepWake(tester, container);

    // Exactly one challenge at all times — no stacked screens.
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(sessionFor(container, 'com.whatsapp'), isNull);

    // Only the PIN ends it.
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);
    expect(overlay.secureWindow, isFalse);
  });

  testWidgets(
      'rapid sleep/wake cycles stay consistent (Phase 5R)',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');
    final StaticScreenStateService screen =
        container.screenState as StaticScreenStateService;

    // Unlock once.
    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);

    // Three rapid sleep/wake cycles.
    for (int i = 0; i < 3; i++) {
      screen.emitScreenOff();
      await tester.pump();
      screen.emitScreenOn();
      await tester.pump();
    }
    await tester.pumpAndSettle();

    // Exactly one challenge, no grants, no stacking.
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(sessionFor(container, 'com.whatsapp'), isNull);

    // The PIN ends the whole storm.
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);
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
