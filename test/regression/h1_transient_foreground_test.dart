import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/services/impl/static_native_challenge_contract.dart';
import 'package:smart_app_lock/services/pending_lock_challenge.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';

import '../support/focus_aware_wake_device.dart';

/// Phase 5 / H-1 (F1 + F2): transient foreground reports must not abandon a
/// rendered challenge ticket or forget the wake re-authentication identity.
///
/// SIMULATED. Every test here runs against [StaticNativeChallengeContract],
/// a Dart model of the Kotlin `WatcherService` / `ChallengeAbandonPolicy`
/// rules. Nothing here executes Kotlin, Android, Accessibility, UsageEvents
/// or a real overlay window, and nothing here is evidence of device
/// behaviour. The pure Kotlin policy is tested separately in
/// `android/app/src/test/.../ChallengeAbandonPolicyTest.kt`.
const String _pkg = 'com.intsig.camscanner';
const String _other = 'com.example.bank';
const String _launcher = 'com.oppo.launcher';
const String _ime = 'com.google.android.inputmethod.latin';
const String _pin = '1234';

void main() {
  StaticNativeChallengeContract configured() {
    final StaticNativeChallengeContract native =
        StaticNativeChallengeContract();
    native.configure(enabled: true, packages: <String>{_pkg, _other});
    native.inputMethodPackage = _ime;
    return native;
  }

  /// Protected app detected, challenge shown, route acknowledged: the shield
  /// is down and the exact ticket is ready (MainActivity resumed).
  PendingLockChallenge readyChallenge(StaticNativeChallengeContract native) {
    native.reportForeground(_pkg);
    final PendingLockChallenge ticket = native.showLockChallenge(_pkg)!;
    expect(native.markChallengeReady(ticket), isTrue);
    expect(native.readyChallenge, ticket);
    expect(native.shieldVisible, isFalse);
    return ticket;
  }

  group('SIMULATED F1: transient windows over a rendered challenge', () {
    for (final String transient in <String>[
      systemUiPackage,
      'android',
      _ime,
      '',
    ]) {
      test(
          'SIMULATED: "$transient" keeps the exact ticket, the handoff and '
          'the wake identity; the same ticket still authorizes', () {
        final StaticNativeChallengeContract native = configured();
        final PendingLockChallenge ticket = readyChallenge(native);
        final String? wakeBefore = native.wakeReauthPackage;

        native.reportForeground(transient);
        expect(native.pending, ticket);
        expect(native.readyChallenge, ticket);
        expect(native.abandonCandidate, isNull);
        expect(native.wakeReauthPackage, wakeBefore);

        // Correct credential: the exact ticket authorizes on the first try.
        expect(native.authorizePackage(ticket), isTrue);
        expect(native.authorizeRejections, 0);
        expect(native.pending, isNull);
      });
    }

    test(
        'SIMULATED: a transient window that pauses MainActivity (for example '
        'a framework dialog) still proves nothing', () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = readyChallenge(native);
      native.onActivityPaused();
      native.reportForeground('android');
      expect(native.pending, ticket);
      expect(native.readyChallenge, ticket);
    });

    test(
        'SIMULATED: the keyboard package is transient only while it is the '
        'default input method', () {
      final StaticNativeChallengeContract native = configured();
      native.inputMethodPackage = null;
      final PendingLockChallenge ticket = readyChallenge(native);
      native.onActivityPaused();
      native.reportForeground(_ime);
      expect(native.pending, isNull, reason: 'not the IME: a genuine target');
      expect(native.authorizePackage(ticket), isFalse);
    });
  });

  group('SIMULATED F1: genuine leave and event-order races', () {
    test('SIMULATED: Activity paused, then the launcher -> abandoned now', () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = readyChallenge(native);
      native.onActivityPaused();
      native.reportForeground(_launcher);
      expect(native.pending, isNull);
      expect(native.readyChallenge, isNull);
      expect(native.wakeReauthPackage, isNull);
      expect(native.authorizePackage(ticket), isFalse,
          reason: 'abandonment never authorizes');
    });

    test(
        'SIMULATED: launcher reported BEFORE onPause defers; the onPause '
        'inside the window confirms it', () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = readyChallenge(native);
      native.elapsedMs = 10000;
      native.reportForeground(_launcher);
      expect(native.pending, ticket, reason: 'still resumed: not proof yet');
      expect(native.abandonCandidate?.ticket, ticket);
      expect(native.wakeReauthPackage, isNull,
          reason: 'F2: a non-transient target forgets the wake identity');

      native.elapsedMs += StaticNativeChallengeContract.abandonConfirmWindowMs;
      native.onActivityPaused();
      expect(native.pending, isNull);
      expect(native.readyChallenge, isNull);
      expect(native.abandonCandidate, isNull);
      expect(native.shieldVisible, isFalse);
    });

    test(
        'SIMULATED: an onPause after the window does not confirm; the next '
        'genuine report while paused does', () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = readyChallenge(native);
      native.reportForeground(_launcher);
      native.elapsedMs +=
          StaticNativeChallengeContract.abandonConfirmWindowMs + 1;
      native.onActivityPaused();
      expect(native.pending, ticket, reason: 'expired: fail closed');
      expect(native.abandonCandidate, isNull);

      native.reportForeground(_launcher);
      expect(native.pending, isNull);
    });

    test(
        'SIMULATED: a trailing launcher event while the challenge stays '
        'resumed never clears the ticket (no pause follows)', () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = readyChallenge(native);
      native.reportForeground(_launcher);
      native.elapsedMs += 5000;
      expect(native.pending, ticket);
      expect(native.authorizePackage(ticket), isTrue);
    });

    test(
        'SIMULATED: an unlisted OEM overlay while resumed is only a '
        'candidate (documented residual: it forgets the wake identity)', () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = readyChallenge(native);
      native.reportForeground('com.coloros.gesture');
      expect(native.pending, ticket);
      expect(native.wakeReauthPackage, isNull);
      expect(native.authorizePackage(ticket), isTrue);
    });

    test('SIMULATED: a protected report cancels the candidate', () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = readyChallenge(native);
      native.reportForeground(_launcher);
      native.reportForeground(_pkg);
      expect(native.abandonCandidate, isNull);
      native.onActivityPaused();
      expect(native.pending, ticket);
      expect(native.wakeReauthPackage, _pkg);
    });

    test(
        'SIMULATED: a stale candidate never clears a newer generation '
        '(SCREEN_OFF / handoff-failure replacement)', () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = readyChallenge(native);
      native.reportForeground(_launcher); // candidate for `ticket`
      final PendingLockChallenge newer = native.replacePendingChallenge(_pkg);
      expect(newer.generation, greaterThan(ticket.generation));
      native.onActivityPaused();
      expect(native.pending, newer);
    });

    test(
        'SIMULATED: the pause caused by screen-off does not confirm a '
        'candidate; the unresolved ticket survives for wake recovery', () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = readyChallenge(native);
      native.reportForeground(_launcher); // candidate, still resumed
      native.screenOff(); // no wake target: the launcher was observed last
      native.onActivityPaused();
      expect(native.pending, ticket);
      native.lockKeyguard();
      native.screenOn();
      native.dismissKeyguard();
      expect(native.pending, ticket);
      expect(native.shieldVisible, isTrue);
    });

    test(
        'SIMULATED: a candidate for a ticket consumed by correct '
        'authentication has no effect', () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = readyChallenge(native);
      native.reportForeground(_launcher);
      expect(native.authorizePackage(ticket), isTrue);
      native.onActivityPaused();
      expect(native.pending, isNull);
      expect(native.authorizedPackages, <String>{_pkg});
    });

    test(
        'SIMULATED: rapid switching to another protected app replaces the '
        'ticket; the old candidate cannot touch it', () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = readyChallenge(native);
      native.reportForeground(_launcher); // candidate for _pkg
      native.onActivityPaused(); // confirmed: _pkg abandoned
      expect(native.pending, isNull);
      native.reportForeground(_other);
      final PendingLockChallenge next = native.pending!;
      expect(next.packageName, _other);
      expect(next.generation, greaterThan(ticket.generation));
      expect(native.shieldVisible, isTrue);
      expect(native.authorizePackage(ticket), isFalse);
    });
  });

  group('SIMULATED F2: wake identity across transient windows', () {
    /// Authorized session for _pkg, user inside the app.
    StaticNativeChallengeContract authorizedInside() {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = readyChallenge(native);
      expect(native.authorizePackage(ticket), isTrue);
      native.onActivityPaused();
      native.reportForeground(_pkg);
      expect(native.wakeReauthPackage, _pkg);
      return native;
    }

    test(
        'SIMULATED: shade over an authorized app, then SCREEN_OFF -> fresh '
        'wake ticket and shield; wake recovery re-challenges', () {
      final StaticNativeChallengeContract native = authorizedInside();
      native.reportForeground(systemUiPackage);
      expect(native.wakeReauthPackage, _pkg);
      expect(native.authorizedPackages, isEmpty,
          reason: 'immediate relock is unchanged (grace 0)');

      native.screenOff();
      native.lockKeyguard();
      expect(native.pending?.packageName, _pkg);
      expect(native.shieldVisible, isTrue);

      native.screenOn();
      native.dismissKeyguard();
      expect(native.recoveryAttempts, contains(NativeRecoverySignal.userPresent));
      expect(native.pending?.packageName, _pkg);
      expect(native.shieldVisible, isTrue);
    });

    test(
        'SIMULATED: keyboard and framework windows also keep the wake '
        'identity', () {
      for (final String transient in <String>[_ime, 'android']) {
        final StaticNativeChallengeContract native = authorizedInside();
        native.reportForeground(transient);
        native.screenOff();
        expect(native.pending?.packageName, _pkg, reason: transient);
      }
    });

    test(
        'SIMULATED: Home from an authorized app, then SCREEN_OFF -> no wake '
        'challenge over the launcher', () {
      final StaticNativeChallengeContract native = authorizedInside();
      native.reportForeground(_launcher);
      expect(native.wakeReauthPackage, isNull);
      native.screenOff();
      expect(native.pending, isNull);
      expect(native.shieldVisible, isFalse);
    });

    test(
        'SIMULATED: display-off transient reports keep the existing '
        'ScreenOffForegroundPolicy behaviour', () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = readyChallenge(native);
      native.screenInteractive = false;
      native.reportForeground(_launcher);
      expect(native.pending, ticket);
      expect(native.readyChallenge, isNull);
      expect(native.wakeReauthPackage, _pkg);
    });
  });

  group('SIMULATED end-to-end (Flutter app + native model)', () {
    Future<FocusAwareWakeDevice> launch(WidgetTester tester) =>
        launchFocusAwareDevice(
          tester,
          protectedPackage: _pkg,
          label: 'CamScanner',
          pin: _pin,
        );

    Future<PendingLockChallenge> challengeOnScreen(
        FocusAwareWakeDevice device) async {
      await device.leaveToLauncher();
      await device.openProtectedApp();
      final PendingLockChallenge ticket = device.native.pending!;
      await device.activityResumes();
      await device.pumpFor(const Duration(seconds: 1));
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(device.native.readyChallenge, ticket);
      return ticket;
    }

    testWidgets(
        'SIMULATED: a System UI report while the PIN screen is up does not '
        'reject the correct PIN; the same generation authorizes and launches',
        (WidgetTester tester) async {
      final FocusAwareWakeDevice device = await launch(tester);
      final StaticNativeChallengeContract native = device.native;
      final PendingLockChallenge ticket = await challengeOnScreen(device);
      final int presentations = device.overlay.showLockChallengeCalls;

      // Production order: native first, then the Flutter event sink.
      await device.reportForeground(systemUiPackage);
      await device.pumpFor(const Duration(milliseconds: 500));
      expect(native.pending, ticket);
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      await device.enterPin(_pin);
      await device.pumpFor(const Duration(seconds: 1));
      expect(native.authorizeRejections, 0);
      expect(native.authorizedPackages, <String>{_pkg});
      expect(native.pending, isNull);
      expect(device.apps.launchedPackages, <String>[_pkg]);
      expect(device.overlay.showLockChallengeCalls, presentations,
          reason: 'no re-challenge with a new generation');
    });

    testWidgets(
        'SIMULATED: Home from the PIN screen still abandons the ticket and '
        'grants nothing; reopening the app challenges a new generation',
        (WidgetTester tester) async {
      final FocusAwareWakeDevice device = await launch(tester);
      final StaticNativeChallengeContract native = device.native;
      final PendingLockChallenge ticket = await challengeOnScreen(device);

      await device.pressHome();
      expect(native.pending, isNull);
      expect(native.readyChallenge, isNull);
      expect(native.wakeReauthPackage, isNull);
      expect(device.challengeRouteOnStack(), isFalse);
      expect(native.authorizedPackages, isEmpty);
      expect(device.dartSession(), isNull);
      expect(device.apps.launchAppCalls, 0);

      await device.openProtectedApp();
      final PendingLockChallenge next = native.pending!;
      expect(next.packageName, _pkg);
      expect(next.generation, greaterThan(ticket.generation));
      expect(native.shieldVisible, isTrue);
    });
  });
}
