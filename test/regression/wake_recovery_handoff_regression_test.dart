import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_native_challenge_contract.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_screen_state_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/pending_lock_challenge.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';

/// Phase 5 / Milestone 3 — Fix #1: wake-recovery handoff regression (CR-1).
///
/// Every test here binds [StaticNativeChallengeContract], so the overlay
/// and watcher doubles reject a ready acknowledgement or authorization
/// under exactly the conditions native Android does:
/// `ChallengeReadyPolicy.canHandOff` and
/// `WatcherService.authorizePackage` at baseline `e20d525`.
///
/// Results confirmed by execution (Flutter 3.47.7):
///  * at baseline `e20d525`, `CR-1 ...` FAILS (red) on the shield-deadlock
///    assertion, and the two controls PASS. The controls show that the
///    contract and the authentication path work when native preconditions
///    are met, and that authorization fails closed when they are not;
///  * with Phase 5 / Milestone 3 Fix #2 (bounded readiness retry in
///    `LockChallengeHost`), every test here PASSES. The `Fix #2: ...` tests
///    pin the retry's cadence and cancellation (on completion, leave and
///    dispose) and its adoption of replaced tickets.
const String _protectedPackage = 'com.whatsapp';
const String _pin = '1234';

/// How long the test waits, after every native precondition is satisfied,
/// for the challenge to retry its ready handoff. This covers six Dart
/// heartbeats (2 s) and four native recovery retries (3 s).
const int _retryWindowSeconds = 12;

class _Device {
  _Device(this.tester, this.container, this.native);

  final WidgetTester tester;
  final AppContainer container;
  final StaticNativeChallengeContract native;

  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  static const List<AppLifecycleState> _ladder = <AppLifecycleState>[
    AppLifecycleState.resumed,
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ];

  StaticScreenStateService get _screen =>
      container.screenState as StaticScreenStateService;

  /// Moves the Flutter lifecycle one legal step at a time
  /// (resumed ↔ inactive ↔ hidden ↔ paused). Frames are disabled while
  /// hidden or paused, as on a real device.
  Future<void> flutterLifecycle(AppLifecycleState target) async {
    int index = _ladder.indexOf(_lifecycle);
    final int goal = _ladder.indexOf(target);
    while (index != goal) {
      index += goal > index ? 1 : -1;
      _lifecycle = _ladder[index];
      tester.binding.handleAppLifecycleStateChanged(_lifecycle);
      await tester.pump();
    }
  }

  /// The user opens a protected app. Production order: the Accessibility
  /// service reports to native first, then to Flutter's event sink.
  Future<void> openProtectedApp() async {
    native.reportForeground(_protectedPackage);
    (container.accessibility as StaticAccessibilityLockService)
        .emitForegroundPackage(_protectedPackage);
    await tester.pumpAndSettle();
  }

  /// Display off: the native receiver, the Dart screen channel, then the
  /// activity pauses and Flutter goes inactive → hidden → paused.
  Future<void> screenOff() async {
    native.screenOff();
    _screen.emitScreenOff();
    await tester.pump();
    native.onActivityPaused();
    await flutterLifecycle(AppLifecycleState.paused);
  }

  Future<void> screenOn() async {
    native.screenOn();
    _screen.emitScreenOn();
    await tester.pump();
  }

  /// MainActivity.onResume, then Flutter climbs back to resumed.
  Future<void> activityResumes() async {
    native.onActivityResumed();
    await flutterLifecycle(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  }

  Future<void> enterPin(String pin) async {
    for (final String digit in pin.split('')) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
  }

  Object? dartSession() =>
      (container.accessController as DefaultAccessController)
          .sessionFor(_protectedPackage);

  StaticInstalledAppsService get apps =>
      container.installedAppsService as StaticInstalledAppsService;
}

Future<_Device> _launch(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final AppContainer container = AppContainer.inMemory();
  final StaticNativeChallengeContract native =
      StaticNativeChallengeContract.bind(
    overlay: container.overlay as StaticOverlayLockService,
    watcher: container.watcher as StaticWatcherService,
  );
  await container.auth.enrollPin(_pin);
  await container.protectedApps.add(
    ProtectedApp(
      packageName: _protectedPackage,
      label: 'WhatsApp',
      addedAt: DateTime(2026, 10, 23),
    ),
  );
  // Protection is configured BEFORE the host mounts, as in production.
  // That arms the host's 2-second heartbeat/pending-recovery timer, so the
  // test exercises every existing Dart retry path.
  await container.protectionBootstrap.synchronize();
  expect(native.isProtected(_protectedPackage), isTrue);

  await tester.pumpWidget(SmartAppLockApp(container: container));
  await tester.pumpAndSettle();
  return _Device(tester, container, native);
}

/// Steps 1–7, shared by the red test and the fail-closed control.
/// Returns the post-screen-off wake ticket.
Future<PendingLockChallenge> _challengeThenSleepAndWakeBehindKeyguard(
  _Device device,
) async {
  final StaticNativeChallengeContract native = device.native;

  // 1–2. A protected app triggers authentication and the PIN challenge is
  //      handed off normally.
  await device.openProtectedApp();
  expect(find.byType(PinUnlockScreen), findsOneWidget);
  final PendingLockChallenge first = native.pending!;
  expect(first.packageName, _protectedPackage);
  expect(native.readyChallenge, first,
      reason: 'precondition: the initial handoff is accepted');
  expect(native.shieldVisible, isFalse);
  expect(native.readyRejections, isEmpty);

  // 3. Screen OFF. Native replaces the ticket generation and raises the
  //    shield.
  await device.screenOff();
  final PendingLockChallenge wake = native.pending!;
  expect(wake.packageName, _protectedPackage);
  expect(wake.generation, greaterThan(first.generation));
  expect(native.readyChallenge, isNull);
  expect(native.shieldVisible, isTrue);

  // 4. The device keyguard engages.
  native.lockKeyguard();

  // 5. Screen ON. Native recovery shields and promotes the task, but never
  //    calls into Dart.
  await device.screenOn();
  expect(native.shieldVisible, isTrue);

  // 6. MainActivity resumes while the keyguard is still reported locked.
  //    This is the SCREEN_ON-behind-keyguard / keyguard-going-away window.
  //    The rendered challenge acknowledges readiness here.
  await device.activityResumes();
  expect(find.byType(PinUnlockScreen), findsOneWidget,
      reason: 'the wake challenge route is restored, not stacked');
  expect(native.pending, wake);

  // 7. Native rejects readiness, and ONLY because the keyguard is locked.
  //    The ticket matched and the activity was resumed, so the mock is not
  //    rejecting for an unrelated reason.
  expect(native.readyRejections, isNotEmpty,
      reason: 'the challenge attempted a ready handoff behind keyguard');
  for (final Set<NativeReadyRejection> blockers in native.readyRejections) {
    expect(
      blockers,
      <NativeReadyRejection>{NativeReadyRejection.keyguardLocked},
    );
  }
  expect(native.readyAccepted, 1, reason: 'only the pre-sleep handoff');
  expect(native.readyChallenge, isNull);
  expect(native.shieldVisible, isTrue);
  return wake;
}

void main() {
  testWidgets(
      'CR-1: a ready handoff rejected behind keyguard is retried after the '
      'keyguard is dismissed (no permanent shield)',
      (WidgetTester tester) async {
    final _Device device = await _launch(tester);
    final StaticNativeChallengeContract native = device.native;

    final PendingLockChallenge wake =
        await _challengeThenSleepAndWakeBehindKeyguard(device);

    // 8. The user dismisses the keyguard. The activity is already resumed,
    //    so Android delivers NO further lifecycle callback; native only
    //    runs its USER_PRESENT recovery.
    native.dismissKeyguard();
    await tester.pump();

    // These checks show the failure below has the CORRECT cause: the native
    // preconditions are now all satisfied, so one ready acknowledgement for
    // the exact wake ticket would be accepted.
    expect(native.activityResumed, isTrue);
    expect(native.keyguardLocked, isFalse);
    expect(native.pending, wake);
    expect(native.readyBlockers(wake), isEmpty);
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    // 9. Let the existing retry machinery run: Dart heartbeats every 2 s and
    //    the native recovery retry every 3 s.
    final int acknowledgementsBefore = native.readyAcknowledgements;
    for (int second = 1; second <= _retryWindowSeconds; second++) {
      await tester.pump(const Duration(seconds: 1));
      if (second % 3 == 0) native.recoveryRetryTick();
    }
    await tester.pumpAndSettle();

    // 10. The challenge must have retried, so the shield clears and the PIN
    //     UI becomes usable. A permanent shield is the CR-1 deadlock.
    expect(
      native.shieldVisible,
      isFalse,
      reason: 'CR-1 permanent shield deadlock: every native precondition '
          'has been satisfied for ${_retryWindowSeconds}s, yet the challenge '
          'made ${native.readyAcknowledgements - acknowledgementsBefore} '
          'ready acknowledgement(s) after the keyguard was dismissed. '
          'Earlier rejections: ${native.readyRejections}. '
          'Native recovery attempts: ${native.recoveryAttempts}.',
    );
    expect(native.readyChallenge, wake);

    await device.enterPin(_pin);
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(native.pending, isNull);
    expect(native.authorizedPackages, contains(_protectedPackage));
    expect(native.shieldVisible, isFalse);
    expect(device.dartSession(), isNotNull);
    expect(device.apps.launchedPackages, <String>[_protectedPackage]);
  });

  testWidgets(
      'control: keyguard dismissed before resume hands off and unlocks '
      'through the strict native contract', (WidgetTester tester) async {
    final _Device device = await _launch(tester);
    final StaticNativeChallengeContract native = device.native;

    await device.openProtectedApp();
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(native.shieldVisible, isFalse);

    await device.screenOff();
    final PendingLockChallenge wake = native.pending!;
    native.lockKeyguard();
    await device.screenOn();

    // The keyguard is dismissed first; the activity resumes afterwards.
    native.dismissKeyguard();
    await tester.pump();
    await device.activityResumes();

    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(native.readyRejections, isEmpty);
    expect(native.readyChallenge, wake);
    expect(native.shieldVisible, isFalse);

    await device.enterPin(_pin);
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(native.pending, isNull);
    expect(native.authorizedPackages, contains(_protectedPackage));
    expect(device.dartSession(), isNotNull);
    expect(device.apps.launchedPackages, <String>[_protectedPackage]);
  });

  testWidgets(
      'control: a correct PIN entered while the handoff is rejected cannot '
      'authorize (fail closed)', (WidgetTester tester) async {
    final _Device device = await _launch(tester);
    final StaticNativeChallengeContract native = device.native;

    final PendingLockChallenge wake =
        await _challengeThenSleepAndWakeBehindKeyguard(device);

    // The keyguard is still locked. Authentication without an accepted
    // ready handoff must never authorize the package or launch it.
    await device.enterPin(_pin);

    expect(native.authorizeRejections, greaterThanOrEqualTo(1));
    expect(native.authorizedPackages, isEmpty);
    expect(native.pending, wake,
        reason: 'unresolved authentication stays pending');
    expect(native.shieldVisible, isTrue);
    expect(device.dartSession(), isNull);
    expect(device.apps.launchAppCalls, 0);
    expect(find.byType(PinUnlockScreen), findsOneWidget,
        reason: 'the challenge is re-presented, never abandoned');
  });
  // -- Phase 5 / Milestone 3 — Fix #2: focused readiness-retry tests -------

  testWidgets(
      'Fix #2: readiness retries stop once the challenge completes '
      'successfully', (WidgetTester tester) async {
    final _Device device = await _launch(tester);
    final StaticNativeChallengeContract native = device.native;
    await _challengeThenSleepAndWakeBehindKeyguard(device);

    native.dismissKeyguard();
    await tester.pump(const Duration(seconds: 2));
    expect(native.shieldVisible, isFalse);

    await device.enterPin(_pin);
    expect(native.authorizedPackages, contains(_protectedPackage));
    expect(native.pending, isNull);

    final int acknowledgements = native.readyAcknowledgements;
    final int rejections = native.readyRejections.length;
    await tester.pump(const Duration(seconds: 10));
    expect(native.readyAcknowledgements, acknowledgements,
        reason: 'no readiness acknowledgement after the challenge closed');
    expect(native.readyRejections.length, rejections);
  });

  testWidgets(
      'Fix #2: rejected handoffs retry at a bounded one-per-second cadence '
      'and stop when the user leaves', (WidgetTester tester) async {
    final _Device device = await _launch(tester);
    final StaticNativeChallengeContract native = device.native;
    final PendingLockChallenge wake =
        await _challengeThenSleepAndWakeBehindKeyguard(device);

    // The keyguard stays locked: every retry is rejected and fails closed.
    final int before = native.readyAcknowledgements;
    await tester.pump(const Duration(seconds: 5));
    final int during = native.readyAcknowledgements - before;
    expect(during, inInclusiveRange(4, 6),
        reason: 'one retry per second, never a tight loop');
    for (final Set<NativeReadyRejection> blockers in native.readyRejections) {
      expect(
          blockers, <NativeReadyRejection>{NativeReadyRejection.keyguardLocked});
    }
    expect(native.shieldVisible, isTrue);
    expect(native.readyChallenge, isNull);
    expect(native.pending, wake);
    expect(native.authorizedPackages, isEmpty);

    // Home: the activity pauses and Flutter leaves the foreground.
    native.onActivityPaused();
    await device.flutterLifecycle(AppLifecycleState.paused);
    final int afterLeave = native.readyAcknowledgements;
    await tester.pump(const Duration(seconds: 10));
    expect(native.readyAcknowledgements, afterLeave,
        reason: 'retries stop when the app leaves the foreground');
    expect(native.authorizedPackages, isEmpty);
    expect(device.dartSession(), isNull);
  });

  testWidgets(
      'Fix #2: a replaced native ticket is adopted; the stale ticket can '
      'never authorize', (WidgetTester tester) async {
    final _Device device = await _launch(tester);
    final StaticNativeChallengeContract native = device.native;

    // Native accepts the preconditions but fails to hide the shield, so
    // `onChallengeHandoffFailed` replaces the ticket generation.
    native.shieldHideSucceeds = false;
    await device.openProtectedApp();
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(native.readyAcknowledgements, greaterThanOrEqualTo(1));
    expect(native.readyAccepted, 0);
    expect(native.shieldVisible, isTrue);

    await tester.pump(const Duration(seconds: 3));
    expect(native.readyAccepted, 0);
    final PendingLockChallenge replaced = native.pending!;
    expect(replaced.generation, greaterThan(1),
        reason: 'native replaced the ticket at least once');

    // The shield can be hidden again; the next retry adopts the CURRENT
    // ticket and native accepts it.
    native.shieldHideSucceeds = true;
    await tester.pump(const Duration(seconds: 2));
    final PendingLockChallenge current = native.pending!;
    expect(native.shieldVisible, isFalse);
    expect(native.readyChallenge, current);

    // An older generation of the same package is refused by native and
    // does not consume the current handoff.
    final PendingLockChallenge stale = PendingLockChallenge(
      packageName: _protectedPackage,
      generation: current.generation - 1,
    );
    final int rejectionsBefore = native.authorizeRejections;
    expect(native.authorizePackage(stale), isFalse);
    expect(native.authorizeRejections, rejectionsBefore + 1);
    expect(native.readyChallenge, current);

    final int acknowledgements = native.readyAcknowledgements;
    await device.enterPin(_pin);
    expect(native.authorizedPackages, contains(_protectedPackage));
    expect(native.pending, isNull);
    expect(device.dartSession(), isNotNull);
    expect(device.apps.launchedPackages, <String>[_protectedPackage]);
    await tester.pump(const Duration(seconds: 5));
    expect(native.readyAcknowledgements, acknowledgements);
  });

  testWidgets(
      'Fix #2: disposing the host cancels a pending readiness retry',
      (WidgetTester tester) async {
    final _Device device = await _launch(tester);
    final StaticNativeChallengeContract native = device.native;
    await _challengeThenSleepAndWakeBehindKeyguard(device);
    await tester.pump(const Duration(milliseconds: 500));

    await tester.pumpWidget(const SizedBox());
    final int acknowledgements = native.readyAcknowledgements;
    native.dismissKeyguard();
    await tester.pump(const Duration(seconds: 5));
    expect(native.readyAcknowledgements, acknowledgements);
    expect(native.shieldVisible, isTrue,
        reason: 'nothing hides the shield on behalf of a disposed host');
    expect(native.authorizedPackages, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
