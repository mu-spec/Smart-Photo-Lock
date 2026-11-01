import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/services/impl/static_native_challenge_contract.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/pending_lock_challenge.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';

import '../support/focus_aware_wake_device.dart';

/// Phase 6 / Milestone 3 — Background Resilience & Bypass Regression.
///
/// SIMULATED. Nothing here runs Kotlin, Android, Battery Saver, Doze, the
/// "Restricted" background-usage setting, ColorOS power management, a
/// foreground-service stop or a real screen. The Kotlin
/// `WatcherTeardownPolicy` and its `onDestroy` wiring are tested in
/// `android/app/src/test/.../BackgroundResilienceRegressionTest.kt`.
///
///  * Group A — [StaticNativeChallengeContract.serviceDestroyed], the Dart
///    model of `WatcherService.onDestroy` while protection is configured
///    (M3-F1), combined with the M1 recovery-intent and M2 task /
///    multi-window rules it must not disturb;
///  * Group B — the production Dart wiring (host → router → unlock screen,
///    lock trigger) against that model, through [FocusAwareWakeDevice].
///
/// Whether and when Android or an OEM actually stops the service, and what
/// the device shows meanwhile, needs the combined Phase 6 device QA round
/// (docs/regression.md, M3 rows).
const String _pkg = 'com.intsig.camscanner';
const String _other = 'com.example.bank';
const String _pin = '1234';

void main() {
  // -------------------------------------------------------------------
  // Group A — native model
  // -------------------------------------------------------------------
  group('SIMULATED A: native model — watcher interruption', () {
    StaticNativeChallengeContract configured() {
      final StaticNativeChallengeContract native =
          StaticNativeChallengeContract();
      native.configure(enabled: true, packages: <String>{_pkg, _other});
      return native;
    }

    /// Challenge handed off, authorized, launched app in front.
    StaticNativeChallengeContract authorizedAndLaunched() {
      final StaticNativeChallengeContract native = configured();
      native.activityResumed = false;
      native.reportForeground(_pkg);
      final PendingLockChallenge ticket = native.pending!;
      native.onActivityResumed();
      expect(native.markChallengeReady(ticket), isTrue);
      expect(native.authorizePackage(ticket), isTrue);
      native.onActivityPaused(); // launchApp
      native.reportForeground(_pkg);
      expect(native.authorizedPackages, <String>{_pkg});
      return native;
    }

    test(
        'SIMULATED: an interruption during authorized use revokes the '
        'session; the next report of the same app is challenged', () {
      final StaticNativeChallengeContract native = authorizedAndLaunched();
      native.serviceDestroyed();
      expect(native.serviceRunning, isFalse);
      expect(native.authorizedPackages, isEmpty);
      expect(
          native.lastError, StaticNativeChallengeContract.interruptedMessage);
      // Navigation inside the protected app (Accessibility keeps running).
      native.reportForeground(_pkg);
      expect(native.pending?.packageName, _pkg);
      expect(native.shieldVisible, isTrue);
      expect(native.authorizedPackages, isEmpty);
    });

    test(
        'SIMULATED: with the receiver gone, a missed screen cycle cannot '
        'leave a session behind (no grant on wake)', () {
      final StaticNativeChallengeContract native = authorizedAndLaunched();
      native.serviceDestroyed();
      native.screenOff();
      native.lockKeyguard();
      expect(native.pending, isNull,
          reason: 'no native receiver: no wake ticket is issued');
      native.screenOn();
      native.dismissKeyguard();
      expect(native.recoveryAttempts,
          isNot(contains(NativeRecoverySignal.screenOn)));
      // The protected app is reported again after unlock.
      native.reportForeground(_pkg);
      expect(native.authorizedPackages, isEmpty);
      expect(native.pending?.packageName, _pkg);
      expect(native.shieldVisible, isTrue);
    });

    test(
        'SIMULATED: a pending ticket survives the interruption and its '
        'restart; only the exact ticket with a hand-off authorizes', () {
      final StaticNativeChallengeContract native = configured();
      native.activityResumed = false;
      native.serviceStart(); // first start: the one restart decision
      expect(native.restartDecisions, 1);
      native.reportForeground(_pkg);
      final PendingLockChallenge ticket = native.pending!;
      native.serviceDestroyed();
      expect(native.pending, ticket);
      expect(native.shieldVisible, isTrue, reason: 'shield stays armed');
      final int attempts = native.recoveryAttempts.length;
      native.recoveryRetryTick();
      expect(native.recoveryAttempts.length, attempts,
          reason: 'the retry Handler died with the service');
      // Duplicate / rapid detector reports keep one generation.
      for (int i = 0; i < 5; i++) {
        native.reportForeground(_pkg);
      }
      expect(native.pending, ticket);

      native.serviceStart(); // restart in the same process
      expect(native.restartDecisions, 1, reason: 'one decision per process');
      expect(native.lastError, isNull);
      expect(native.pending, ticket);
      // Authentication without a hand-off, or for a stale generation,
      // never authorizes.
      expect(native.authorizePackage(ticket), isFalse);
      native.onActivityResumed();
      expect(
        native.authorizePackage(PendingLockChallenge(
          packageName: _pkg,
          generation: ticket.generation + 1,
        )),
        isFalse,
      );
      expect(native.markChallengeReady(ticket), isTrue);
      expect(native.authorizePackage(ticket), isTrue);
    });

    test(
        'SIMULATED: M2 rules hold after an interruption — the own-UI '
        'fresh-grant exception has nothing left to keep, and multi-window '
        'still refuses the hand-off', () {
      final StaticNativeChallengeContract native = configured();
      native.activityResumed = false;
      native.reportForeground(_pkg);
      final PendingLockChallenge ticket = native.pending!;
      native.onActivityResumed();
      expect(native.markChallengeReady(ticket), isTrue);
      native.onActivityPaused(); // system credential screen covers it
      expect(native.authorizePackage(ticket), isTrue);
      native.serviceDestroyed(); // before onResume / launchApp
      native.onActivityResumed(); // returns to the fresh-grant host
      expect(native.authorizedPackages, isEmpty);
      native.onActivityPaused();
      native.reportForeground(_pkg); // launchApp
      final PendingLockChallenge again = native.pending!;
      expect(again.packageName, _pkg);
      expect(native.shieldVisible, isTrue);

      native.inMultiWindow = true;
      native.onActivityResumed();
      expect(native.markChallengeReady(again), isFalse);
      expect(native.authorizePackage(again), isFalse);
      expect(native.shieldVisible, isTrue);
      expect(native.authorizedPackages, isEmpty);
    });

    test(
        'SIMULATED (R-M3-2): a grant made while the watcher is down does '
        'not survive engine teardown plus a screen cycle', () {
      final StaticNativeChallengeContract native = configured();
      native.serviceDestroyed(); // interrupted; restart did not take effect
      native.activityResumed = false;
      native.reportForeground(_pkg);
      final PendingLockChallenge ticket = native.pending!;
      native.onActivityResumed();
      expect(native.markChallengeReady(ticket), isTrue);
      expect(native.authorizePackage(ticket), isTrue); // via the live engine
      native.onActivityPaused(); // launchApp
      native.reportForeground(_pkg);
      expect(native.authorizedPackages, <String>{_pkg});

      // Engine teardown (Activity destroyed) with no watcher receiver.
      native.activityDestroyed();
      expect(native.authorizedPackages, isEmpty);
      expect(native.pending, isNull);
      native.screenOff(); // nothing observes it natively
      native.screenOn();
      native.reportForeground(_pkg);
      expect(native.authorizedPackages, isEmpty);
      expect(native.pending?.packageName, _pkg);
      expect(native.shieldVisible, isTrue);
    });

    test(
        'SIMULATED (R-M3-2 control): with the watcher running, engine '
        'teardown keeps the grant and the receiver ends it at screen-off', () {
      final StaticNativeChallengeContract native = authorizedAndLaunched();
      native.activityDestroyed();
      expect(native.authorizedPackages, <String>{_pkg});
      native.screenOff();
      expect(native.authorizedPackages, isEmpty);
      expect(native.pending?.packageName, _pkg);
    });

    test(
        'SIMULATED: a teardown with protection off revokes nothing new and '
        'records no interruption (pre-M3 behaviour)', () {
      final StaticNativeChallengeContract native = configured();
      native.configure(enabled: false, packages: <String>{_pkg});
      native.serviceDestroyed();
      expect(native.lastError, isNull);
      expect(native.shieldVisible, isFalse);
      expect(native.pending, isNull);
    });
  });

  // -------------------------------------------------------------------
  // Group B — production wiring
  // -------------------------------------------------------------------
  group('SIMULATED B: production wiring — watcher interruption', () {
    Future<FocusAwareWakeDevice> launch(WidgetTester tester) =>
        launchFocusAwareDevice(
          tester,
          protectedPackage: _pkg,
          label: 'CamScanner',
          pin: _pin,
        );

    Future<void> challengeAndUnlock(FocusAwareWakeDevice device) async {
      await device.leaveToLauncher();
      await device.openProtectedApp();
      await device.activityResumes();
      await device.pumpFor(const Duration(seconds: 1));
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await device.enterPin(_pin);
      await device.pumpFor(const Duration(seconds: 1));
      expect(device.native.authorizedPackages, <String>{_pkg});
      // The launched app is in front.
      await device.activityStops();
      await device.reportForeground(_pkg);
      expect(device.native.shieldVisible, isFalse);
    }

    testWidgets(
        'SIMULATED: interrupted during authorized use — a still-valid Dart '
        'session never substitutes for the credential',
        (WidgetTester tester) async {
      final FocusAwareWakeDevice device = await launch(tester);
      final StaticNativeChallengeContract native = device.native;
      await challengeAndUnlock(device);
      expect(device.dartSession(), isNotNull);

      native.serviceDestroyed();
      await device.reportForeground(_pkg); // navigation inside the app
      expect(native.shieldVisible, isTrue);
      final PendingLockChallenge ticket = native.pending!;
      await device.activityResumes();
      await device.pumpFor(const Duration(seconds: 3));
      expect(native.authorizedPackages, isEmpty,
          reason: 'no credential has been entered yet');
      expect(native.pending, ticket);
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      await device.enterPin(_pin);
      await device.pumpFor(const Duration(seconds: 1));
      expect(native.authorizedPackages, <String>{_pkg});
      expect(native.pending, isNull);
      expect(device.apps.launchAppCalls, 2);
      expect(device.resumedWhileUnfocused, isEmpty);
    });

    testWidgets(
        'SIMULATED (R-M3-2 reachability): a stopped watcher is restarted from '
        'the foreground during the challenge, before any credential',
        (WidgetTester tester) async {
      final FocusAwareWakeDevice device = await launch(tester);
      final StaticNativeChallengeContract native = device.native;
      final StaticWatcherService watcher =
          device.container.watcher as StaticWatcherService;
      await challengeAndUnlock(device);

      native.serviceDestroyed();
      watcher.running = false; // WatcherService.isRunning() after onDestroy
      final int startsBefore = watcher.startCalls;
      await device.reportForeground(_pkg);
      await device.activityResumes();
      await device.pumpFor(const Duration(seconds: 1));
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(native.authorizedPackages, isEmpty,
          reason: 'no credential has been entered yet');
      // SecurityScreen (kept alive under the challenge in the shell's
      // IndexedStack) reloads on `resumed` and ProtectionBootstrap starts
      // the configured, non-running watcher.
      expect(watcher.startCalls, greaterThan(startsBefore));
      expect(watcher.running, isTrue);
    });

    testWidgets(
        'SIMULATED: interrupted, then a screen cycle — the Dart lock trigger '
        'still ends both layers\' sessions and wake re-challenges',
        (WidgetTester tester) async {
      final FocusAwareWakeDevice device = await launch(tester);
      final StaticNativeChallengeContract native = device.native;
      await challengeAndUnlock(device);

      native.serviceDestroyed();
      await device.screenOff(); // native receiver gone; Dart still hears it
      expect(native.authorizedPackages, isEmpty);
      expect(device.dartSession(), isNull);
      await device.screenOnBehindKeyguard();
      await device.dismissKeyguard();
      // The protected app is in front again after unlock.
      device.apps.foregroundPackage = _pkg;
      await device.reportForeground(_pkg);
      await device.pumpFor(const Duration(milliseconds: 300));
      expect(native.shieldVisible, isTrue);
      expect(native.pending?.packageName, _pkg);
      await device.activityResumes();
      await device.pumpFor(const Duration(seconds: 1));
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(native.authorizedPackages, isEmpty);
      expect(device.resumedWhileUnfocused, isEmpty);
    });
  });
}
