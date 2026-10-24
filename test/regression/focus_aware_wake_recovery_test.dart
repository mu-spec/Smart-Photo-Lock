import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/services/impl/static_native_challenge_contract.dart';
import 'package:smart_app_lock/services/pending_lock_challenge.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';

import '../support/focus_aware_wake_device.dart';

/// Phase 5 / Milestone 3 — Fix #3: CR-1 focus-deadlock regression.
///
/// Reproduces the physical failure recorded on an Oppo Android 9 device
/// (logcat 10-24 11:47:40–11:48:09, commit 930d5e6):
///  * generation 10 challenge handed off normally (focus moved to the
///    MainActivity window only after the shield hid);
///  * SCREEN_OFF issued generation 11 and raised the shield;
///  * after the device PIN, MainActivity resumed UNDER the focusable shield,
///    so Flutter reported `inactive`, never `resumed`;
///  * no protected package was detected after wake;
///  * Dart never recovered the ticket or acknowledged readiness, and the
///    shield kept focus until the user pressed "Return to Home".
///
/// The harness ([FocusAwareWakeDevice]) never delivers `resumed` while the
/// shield is visible or the keyguard is locked.
const String _pkg = 'com.intsig.camscanner';
const String _pin = '1234';

Future<FocusAwareWakeDevice> _launch(WidgetTester tester) =>
    launchFocusAwareDevice(
      tester,
      protectedPackage: _pkg,
      label: 'CamScanner',
      pin: _pin,
    );

/// Steps 1–5: the protected app is challenged and handed off, then the
/// screen turns off and the route is interrupted. Returns the pre-sleep
/// and wake tickets.
Future<(PendingLockChallenge, PendingLockChallenge)> _handOffThenSleep(
  FocusAwareWakeDevice device, {
  bool letPresentationSettle = true,
}) async {
  final StaticNativeChallengeContract native = device.native;

  // 1. The user opens the protected app from the launcher.
  await device.leaveToLauncher();
  await device.openProtectedApp();
  final PendingLockChallenge preSleep = native.pending!;
  expect(preSleep.packageName, _pkg);
  expect(native.shieldVisible, isTrue);

  // 2. MainActivity resumes under the shield (Flutter inactive). The
  //    rendered route is acknowledged, native hides the shield, the window
  //    gains focus and Flutter reaches resumed.
  await device.activityResumes();
  if (letPresentationSettle) {
    await device.pumpFor(const Duration(seconds: 1));
  }
  expect(find.byType(PinUnlockScreen), findsOneWidget);
  expect(native.readyChallenge, preSleep);
  expect(native.shieldVisible, isFalse);
  expect(device.flutterState, AppLifecycleState.resumed);

  // 3–4. Screen OFF: native invalidates the handoff and issues the wake
  //      generation; the keyguard engages; detection reports System UI.
  await device.screenOff();
  await device.reportForeground(systemUiPackage);
  final PendingLockChallenge wake = native.pending!;
  expect(wake.packageName, _pkg);
  expect(wake.generation, preSleep.generation + 1);
  expect(native.readyChallenge, isNull);
  expect(native.shieldVisible, isTrue);
  expect(native.keyguardLocked, isTrue);
  expect(device.flutterState, AppLifecycleState.paused);
  return (preSleep, wake);
}

/// Steps 6–7: display on behind the keyguard; native recovery runs; no
/// protected package is detected; Dart stays paused and does nothing.
Future<void> _wakeBehindKeyguard(FocusAwareWakeDevice device) async {
  final StaticNativeChallengeContract native = device.native;
  final int acknowledgements = native.readyAcknowledgements;
  final int presentations = device.overlay.showLockChallengeCalls;
  await device.screenOnBehindKeyguard();
  for (int second = 1; second <= 6; second++) {
    await device.pumpFor(const Duration(seconds: 1));
    if (second % 3 == 0) native.recoveryRetryTick();
  }
  expect(native.activityResumed, isFalse,
      reason: 'Android 9: MainActivity is not resumed behind the keyguard');
  expect(native.shieldVisible, isTrue);
  expect(device.flutterState, AppLifecycleState.paused);
  expect(native.readyAcknowledgements, acknowledgements);
  expect(device.overlay.showLockChallengeCalls, presentations,
      reason: 'no protected package was detected after wake, so Dart has '
          'no foreground trigger to present from');
}

/// Asserts the shield never released focus to a Flutter `resumed` state:
/// now, and at every lifecycle delivery so far.
void _expectNeverResumedUnderShield(FocusAwareWakeDevice device) {
  expect(device.flutterState == AppLifecycleState.resumed,
      !device.native.shieldVisible && !device.native.keyguardLocked);
  expect(device.resumedWhileUnfocused, isEmpty,
      reason: 'resumed must never be delivered while the shield or the '
          'keyguard owns focus');
}

/// Asserts that the Activity resume starting at delivery [from] reached
/// Dart as `hidden -> inactive` while the shield still owned focus and
/// before any new handoff was accepted.
void _expectResumedBeneathShieldAsInactive(
  FocusAwareWakeDevice device,
  int from, {
  required int acceptedBefore,
}) {
  final List<LifecycleDelivery> resume = device.deliveries.sublist(from);
  expect(resume.length, greaterThanOrEqualTo(2), reason: '$resume');
  expect(resume[0].state, AppLifecycleState.hidden, reason: '$resume');
  expect(resume[1].state, AppLifecycleState.inactive, reason: '$resume');
  expect(resume[1].shieldVisible, isTrue,
      reason: 'the shield owned focus when the Activity resumed');
  expect(resume[1].activityWindowFocused, isFalse);
  expect(resume[1].readyAcceptedBefore, acceptedBefore,
      reason: 'nothing was accepted before Dart saw the resume');
  _expectNeverResumedUnderShield(device);
}

Future<void> _unlockWith(
  FocusAwareWakeDevice device,
  PendingLockChallenge expected,
) async {
  final StaticNativeChallengeContract native = device.native;
  await device.enterPin(_pin);
  // Let the challenge route's pop transition finish (focus-aware pumps).
  await device.pumpFor(const Duration(seconds: 1));
  expect(find.byType(PinUnlockScreen), findsNothing);
  expect(native.authorizedPackages, contains(_pkg));
  expect(native.pending, isNull,
      reason: 'generation ${expected.generation} was consumed');
  expect(native.shieldVisible, isFalse);
  expect(device.dartSession(), isNotNull);
  expect(device.apps.launchedPackages, <String>[_pkg]);
  _expectNeverResumedUnderShield(device);
}

void main() {
  testWidgets(
      'CR-1 (physical, Oppo Android 9): resume beneath the focusable shield '
      'with Flutter inactive recovers the exact wake ticket and unlocks',
      (WidgetTester tester) async {
    final FocusAwareWakeDevice device = await _launch(tester);
    final StaticNativeChallengeContract native = device.native;

    final (PendingLockChallenge preSleep, PendingLockChallenge wake) =
        await _handOffThenSleep(device);
    // 5. The pre-sleep route was interrupted by the real leave.
    expect(device.challengeRouteOnStack(), isFalse);

    // 6–7.
    await _wakeBehindKeyguard(device);

    // 8. The device credential is accepted (USER_PRESENT).
    await device.dismissKeyguard();
    expect(native.keyguardLocked, isFalse);

    // 9. MainActivity resumes beneath the focusable shield. Flutter is
    //    told inactive, NOT resumed.
    final int acceptedBefore = native.readyAccepted;
    final int deliveredBefore = device.deliveredStates.length;
    await device.activityResumes(settle: Duration.zero);
    expect(native.activityResumed, isTrue);
    _expectResumedBeneathShieldAsInactive(device, deliveredBefore,
        acceptedBefore: acceptedBefore);
    expect(native.readyBlockers(wake), isEmpty,
        reason: 'every native precondition except the ack itself holds');

    // 10–12. Dart must recover generation 11, have the handoff accepted,
    //        and only then does the window regain focus (resumed).
    await device.pumpFor(const Duration(seconds: 2));
    expect(
      native.shieldVisible,
      isFalse,
      reason: 'CR-1 focus deadlock: the shield still owns focus. Flutter '
          'states since resume: '
          '${device.deliveredStates.sublist(deliveredBefore)}; '
          'ready acks=${native.readyAcknowledgements} '
          'rejections=${native.readyRejections}',
    );
    expect(native.pending, wake);
    expect(native.readyChallenge, wake);
    expect(device.overlay.lastReadyGeneration, wake.generation);
    expect(native.readyAccepted, greaterThan(acceptedBefore));
    expect(device.flutterState, AppLifecycleState.resumed);
    expect(
      device.deliveredStates.sublist(deliveredBefore),
      <AppLifecycleState>[
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ],
    );

    // 13. The PIN challenge is usable, and nothing was granted yet.
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(native.authorizedPackages, isEmpty);
    expect(device.dartSession(), isNull);
    expect(device.apps.launchAppCalls, 0);
    expect(native.authorizePackage(preSleep), isFalse,
        reason: 'the pre-sleep generation can never authorize');
    expect(native.readyChallenge, wake,
        reason: 'a stale attempt does not consume the current handoff');
    await _unlockWith(device, wake);
  });

  testWidgets(
      'route survives sleep: the existing route adopts the wake ticket '
      'without a second presentation', (WidgetTester tester) async {
    final FocusAwareWakeDevice device = await _launch(tester);
    final StaticNativeChallengeContract native = device.native;

    // Screen off inside the presentation settle window: the leave is
    // absorbed and the route stays on the navigator.
    final (_, PendingLockChallenge wake) =
        await _handOffThenSleep(device, letPresentationSettle: false);
    expect(device.challengeRouteOnStack(), isTrue);
    await _wakeBehindKeyguard(device);
    await device.dismissKeyguard();

    final int presentations = device.overlay.showLockChallengeCalls;
    final int from = device.deliveries.length;
    final int acceptedBefore = native.readyAccepted;
    await device.activityResumes(settle: Duration.zero);
    _expectResumedBeneathShieldAsInactive(device, from,
        acceptedBefore: acceptedBefore);
    await device.pumpFor(const Duration(seconds: 2));

    expect(native.shieldVisible, isFalse);
    expect(native.readyChallenge, wake);
    expect(device.overlay.lastReadyGeneration, wake.generation);
    expect(device.flutterState, AppLifecycleState.resumed);
    expect(device.overlay.showLockChallengeCalls, presentations,
        reason: 'the surviving route is reused, never re-presented');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    await _unlockWith(device, wake);
  });

  testWidgets(
      'late keyguard dismissal: resumed behind the keyguard, rejected acks '
      'retry while inactive and succeed once the keyguard is gone',
      (WidgetTester tester) async {
    final FocusAwareWakeDevice device = await _launch(tester);
    final StaticNativeChallengeContract native = device.native;
    final (_, PendingLockChallenge wake) = await _handOffThenSleep(device);
    await _wakeBehindKeyguard(device);

    // Some devices resume MainActivity while the keyguard is still locked.
    final int acceptedBefore = native.readyAccepted;
    await device.activityResumes(settle: Duration.zero);
    expect(device.flutterState, AppLifecycleState.inactive);
    await device.pumpFor(const Duration(seconds: 3));
    expect(native.readyRejections, isNotEmpty);
    for (final Set<NativeReadyRejection> blockers in native.readyRejections) {
      expect(blockers,
          <NativeReadyRejection>{NativeReadyRejection.keyguardLocked});
    }
    expect(native.readyAccepted, acceptedBefore);
    expect(native.shieldVisible, isTrue);
    expect(device.flutterState, AppLifecycleState.inactive);
    expect(native.authorizedPackages, isEmpty);
    _expectNeverResumedUnderShield(device);

    // The keyguard goes away; there is NO further Activity callback.
    await device.dismissKeyguard();
    await device.pumpFor(const Duration(milliseconds: 1500));
    expect(native.shieldVisible, isFalse);
    expect(native.readyChallenge, wake);
    expect(device.flutterState, AppLifecycleState.resumed);
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    await _unlockWith(device, wake);
  });

  testWidgets(
      'Home during recovery: retries stop, the route is dismissed, nothing '
      'is granted, and returning recovers again', (WidgetTester tester) async {
    final FocusAwareWakeDevice device = await _launch(tester);
    final StaticNativeChallengeContract native = device.native;
    final (_, PendingLockChallenge wake) = await _handOffThenSleep(device);
    final int acceptedAtSleep = native.readyAccepted;
    await _wakeBehindKeyguard(device);
    await device.activityResumes(settle: Duration.zero);
    await device.pumpFor(const Duration(seconds: 2));
    expect(native.readyAccepted, acceptedAtSleep,
        reason: 'nothing is accepted while the keyguard is locked');

    final int promotions = native.activityPromotions;
    await device.pressHome();
    expect(device.flutterState, AppLifecycleState.paused);
    expect(device.challengeRouteOnStack(), isFalse,
        reason: 'a recovery presented without a bring-to-front must not '
            'latch the own-presentation suppression');
    final int acknowledgements = native.readyAcknowledgements;
    await device.pumpFor(const Duration(seconds: 10));
    expect(native.readyAcknowledgements, acknowledgements);
    expect(native.activityPromotions, promotions,
        reason: 'Dart never pulls the task back over the Home press');
    expect(native.authorizedPackages, isEmpty);
    expect(device.dartSession(), isNull);
    expect(device.apps.launchAppCalls, 0);
    expect(native.pending, wake);

    // Later: keyguard gone, native recovery promotes the task again.
    await device.dismissKeyguard();
    native.recoveryRetryTick();
    final int from = device.deliveries.length;
    final int acceptedBefore = native.readyAccepted;
    await device.activityResumes(settle: Duration.zero);
    _expectResumedBeneathShieldAsInactive(device, from,
        acceptedBefore: acceptedBefore);
    await device.pumpFor(const Duration(seconds: 2));
    expect(native.shieldVisible, isFalse);
    expect(native.readyChallenge, wake);
    expect(device.flutterState, AppLifecycleState.resumed);
    await _unlockWith(device, wake);
  });

  testWidgets(
      'stale ticket: a generation replaced during recovery is adopted; the '
      'older generation can never authorize', (WidgetTester tester) async {
    final FocusAwareWakeDevice device = await _launch(tester);
    final StaticNativeChallengeContract native = device.native;
    final (PendingLockChallenge preSleep, PendingLockChallenge wake) =
        await _handOffThenSleep(device);
    await _wakeBehindKeyguard(device);
    await device.activityResumes(settle: Duration.zero);
    await device.pumpFor(const Duration(seconds: 2));
    expect(device.overlay.lastReadyGeneration, wake.generation);

    // Native re-issues the ticket (for example after a failed shield hide).
    final PendingLockChallenge newest = native.replacePendingChallenge(_pkg);
    expect(newest.generation, wake.generation + 1);
    await device.pumpFor(const Duration(seconds: 2));
    expect(device.overlay.lastReadyGeneration, newest.generation);

    await device.dismissKeyguard();
    await device.pumpFor(const Duration(milliseconds: 1500));
    expect(native.readyChallenge, newest);
    expect(native.shieldVisible, isFalse);
    expect(native.authorizePackage(wake), isFalse);
    expect(native.authorizePackage(preSleep), isFalse);
    expect(native.readyChallenge, newest);
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    await _unlockWith(device, newest);
  });

  testWidgets(
      'repeated lifecycle events: flapping resume/stop never stacks routes '
      'or grants', (WidgetTester tester) async {
    final FocusAwareWakeDevice device = await _launch(tester);
    final StaticNativeChallengeContract native = device.native;
    final (_, PendingLockChallenge wake) = await _handOffThenSleep(device);
    await _wakeBehindKeyguard(device);

    for (int i = 0; i < 3; i++) {
      await device.activityResumes(settle: Duration.zero);
      await device.pumpFor(const Duration(milliseconds: 200));
      await device.activityStops();
      await device.pumpFor(const Duration(milliseconds: 200));
    }
    await device.activityResumes(settle: Duration.zero);
    await device.activityResumes(settle: Duration.zero);
    await device.pumpFor(const Duration(seconds: 2));
    expect(native.authorizedPackages, isEmpty);
    expect(native.shieldVisible, isTrue);

    await device.dismissKeyguard();
    await device.pumpFor(const Duration(milliseconds: 1500));
    expect(native.shieldVisible, isFalse);
    expect(native.readyChallenge, wake);
    expect(device.flutterState, AppLifecycleState.resumed);
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(device.challengeRouteOnStack(), isTrue);
    await _unlockWith(device, wake);
    expect(device.challengeRouteOnStack(), isFalse,
        reason: 'exactly one challenge route existed');
  });

  testWidgets('disposal during an unfocused readiness retry cancels it',
      (WidgetTester tester) async {
    final FocusAwareWakeDevice device = await _launch(tester);
    final StaticNativeChallengeContract native = device.native;
    await _handOffThenSleep(device);
    await _wakeBehindKeyguard(device);
    await device.activityResumes(settle: Duration.zero);
    await device.pumpFor(const Duration(milliseconds: 1500));

    await tester.pumpWidget(const SizedBox());
    final int acknowledgements = native.readyAcknowledgements;
    native.dismissKeyguard();
    await tester.pump(const Duration(seconds: 6));
    expect(native.readyAcknowledgements, acknowledgements);
    expect(native.shieldVisible, isTrue,
        reason: 'nothing hides the shield on behalf of a disposed host');
    expect(native.authorizedPackages, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
