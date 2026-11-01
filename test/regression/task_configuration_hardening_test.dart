import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_native_challenge_contract.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/pending_lock_challenge.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';

import '../support/focus_aware_wake_device.dart';

/// Phase 6 / Milestone 2 — Task & Configuration Hardening.
///
/// SIMULATED. Nothing here executes Kotlin, Android, Recents, a launcher,
/// split screen, freeform windows, rotation, Activity recreation or a real
/// overlay window, and nothing here is evidence of device behaviour.
///
///  * Group A — [StaticNativeChallengeContract], the Dart model of the
///    Kotlin rules (the Kotlin policies themselves are in
///    `android/app/src/test/.../TaskConfigurationHardeningTest.kt`);
///  * Group B — the production Dart wiring (host → router → unlock screen)
///    against that model, through [FocusAwareWakeDevice], whose Flutter
///    lifecycle follows window focus (never `resumed` under the shield);
///  * Group C — rotation (window metrics) and Activity recreation.
///
/// What cannot be simulated: real multi-window placement, Android 10+
/// multi-resume pane focus changes (no lifecycle callback at all), OEM
/// split-screen / freeform implementations, the overlay's z-order over a
/// second window, Recents thumbnails and task-stack decisions. They are
/// listed for the combined Phase 6 device QA round.
const String _pkg = 'com.intsig.camscanner';
const String _other = 'com.example.bank';
const String _pin = '1234';

void main() {
  // -------------------------------------------------------------------
  // Group A — native model
  // -------------------------------------------------------------------
  group('SIMULATED A: native model — own UI and multi-window', () {
    StaticNativeChallengeContract configured() {
      final StaticNativeChallengeContract native =
          StaticNativeChallengeContract();
      native.configure(enabled: true, packages: <String>{_pkg, _other});
      return native;
    }

    /// Protected app challenged, handed off and authorized, then the
    /// launched app is in front (MainActivity paused).
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
      expect(native.pending, isNull);
      return native;
    }

    test('SIMULATED: protected -> Smart App Lock own UI -> protected is '
        'challenged (immediate re-lock; M1 Concern 3)', () {
      final StaticNativeChallengeContract native = authorizedAndLaunched();
      // Back / split pane / quick switch to our own task: onResume with no
      // ticket pending.
      native.onActivityResumed();
      expect(native.currentForegroundPackage,
          StaticNativeChallengeContract.ownPackage);
      expect(native.authorizedPackages, isEmpty);
      native.onActivityPaused();
      native.reportForeground(_pkg);
      expect(native.pending?.packageName, _pkg);
      expect(native.shieldVisible, isTrue);
      expect(native.authorizedPackages, isEmpty);
    });

    test('SIMULATED: own UI resuming over a pending ticket, or returning '
        'to a challenge host, is not a leave', () {
      final StaticNativeChallengeContract native = configured();
      native.activityResumed = false;
      native.reportForeground(_pkg);
      final PendingLockChallenge ticket = native.pending!;
      native.onActivityResumed();
      expect(native.currentForegroundPackage, _pkg);
      expect(native.markChallengeReady(ticket), isTrue);
      // A system credential screen covers the challenge (pause with the
      // ticket pending); authentication completes before onResume.
      native.onActivityPaused();
      expect(native.pendingPackageAtPause, _pkg);
      expect(native.authorizePackage(ticket), isTrue);
      native.onActivityResumed();
      expect(native.authorizedPackages, <String>{_pkg});
      expect(native.pendingPackageAtPause, isNull);
      // launchApp: the fresh grant is used.
      native.onActivityPaused();
      native.reportForeground(_pkg);
      expect(native.pending, isNull);
      expect(native.shieldVisible, isFalse);
    });

    test('SIMULATED (final gate): a stale pause-time snapshot never keeps '
        'another app\'s grant alive across an own-UI switch', () {
      final StaticNativeChallengeContract native = authorizedAndLaunched();
      // _pkg's grant was used; now _other is challenged and the user
      // leaves the rendered challenge (pause with _other pending).
      native.reportForeground(_other);
      final PendingLockChallenge other = native.pending!;
      native.onActivityResumed();
      expect(native.markChallengeReady(other), isTrue);
      native.onActivityPaused();
      expect(native.pendingPackageAtPause, _other);
      // Not expressible with grace 0 alone: a still-valid grant for _pkg
      // stands for the grace re-admission the model does not simulate.
      native.clearPendingChallenge(
        packageName: other.packageName,
        generation: other.generation,
      );
      native.authorizedPackages.add(_pkg);
      native.currentForegroundPackage = _pkg;
      // Direct switch _pkg -> own UI with the stale snapshot.
      native.onActivityResumed();
      expect(native.authorizedPackages, isEmpty);
      expect(native.currentForegroundPackage,
          StaticNativeChallengeContract.ownPackage);
    });

    test('SIMULATED: own UI never creates authorization and never touches '
        'tickets or the shield', () {
      final StaticNativeChallengeContract native = configured();
      for (int i = 0; i < 10; i++) {
        native.onActivityPaused();
        native.onActivityResumed();
      }
      expect(native.authorizedPackages, isEmpty);
      expect(native.pending, isNull);
      expect(native.shieldVisible, isFalse);
      native.configure(enabled: false, packages: <String>{_pkg});
      native.currentForegroundPackage = _pkg;
      native.onActivityResumed();
      expect(native.currentForegroundPackage, _pkg,
          reason: 'protection disabled: nothing is observed');
    });

    test('SIMULATED: rapid protected <-> own UI switching is challenged '
        'every time after the first leave', () {
      final StaticNativeChallengeContract native = authorizedAndLaunched();
      for (int i = 0; i < 10; i++) {
        native.onActivityResumed();
        native.onActivityPaused();
        native.reportForeground(_pkg);
        expect(native.authorizedPackages, isEmpty, reason: 'round $i');
        expect(native.pending?.packageName, _pkg);
      }
    });

    test('SIMULATED: a challenge resumed in split screen / freeform is '
        'refused and keeps the shield; full screen hands off again', () {
      final StaticNativeChallengeContract native = configured();
      native.activityResumed = false;
      native.reportForeground(_pkg);
      final PendingLockChallenge ticket = native.pending!;
      native.inMultiWindow = true;
      native.onActivityResumed();
      expect(native.shieldVisible, isTrue);
      expect(native.multiWindowNotice, isTrue);
      expect(native.markChallengeReady(ticket), isFalse);
      expect(native.readyRejections.last,
          <NativeReadyRejection>{NativeReadyRejection.multiWindow});
      expect(native.shieldVisible, isTrue);
      expect(native.authorizePackage(ticket), isFalse);
      expect(native.authorizedPackages, isEmpty);
      expect(native.pending, ticket, reason: 'the ticket is preserved');

      native.onMultiWindowModeChanged(false);
      expect(native.markChallengeReady(ticket), isTrue);
      expect(native.shieldVisible, isFalse);
      expect(native.multiWindowNotice, isFalse);
      expect(native.authorizePackage(ticket), isTrue);
    });

    test('SIMULATED: entering multi-window after an accepted hand-off '
        'withdraws it and re-raises the shield', () {
      final StaticNativeChallengeContract native = configured();
      native.reportForeground(_pkg);
      final PendingLockChallenge ticket = native.pending!;
      expect(native.markChallengeReady(ticket), isTrue);
      expect(native.shieldVisible, isFalse);

      native.onMultiWindowModeChanged(true);
      expect(native.readyChallenge, isNull);
      expect(native.shieldVisible, isTrue);
      expect(native.multiWindowNotice, isTrue);
      expect(native.authorizePackage(ticket), isFalse);
      expect(native.pending, ticket);
    });

    test('SIMULATED: the duplicate-recovery guard never skips re-covering a '
        'protected app reported beside a multi-window challenge', () {
      final StaticNativeChallengeContract native = configured();
      native.reportForeground(_pkg);
      final PendingLockChallenge ticket = native.pending!;
      expect(native.markChallengeReady(ticket), isTrue);

      // Full screen: an already rendered challenge is a duplicate.
      native.reportForeground(_pkg);
      expect(native.shieldVisible, isFalse);

      // Multi-resume lag: native already sees multi-window but no
      // onMultiWindowModeChanged has run yet; the ready ticket remains.
      native.inMultiWindow = true;
      final int attempts = native.recoveryAttempts.length;
      native.reportForeground(_pkg);
      expect(native.recoveryAttempts.length, attempts + 1);
      expect(native.shieldVisible, isTrue);
    });

    test('SIMULATED: multi-window without a protected ticket changes '
        'nothing', () {
      final StaticNativeChallengeContract native = configured();
      native.onMultiWindowModeChanged(true);
      expect(native.shieldVisible, isFalse);
      expect(native.multiWindowNotice, isFalse);
      native.activityResumed = false;
      native.reportForeground(_pkg);
      native.configure(enabled: true, packages: <String>{_other});
      native.shieldVisible = false;
      native.onMultiWindowModeChanged(true);
      expect(native.shieldVisible, isFalse,
          reason: 'the ticket\'s package is no longer protected');
    });
  });

  // -------------------------------------------------------------------
  // Group B — production wiring
  // -------------------------------------------------------------------
  group('SIMULATED B: production wiring — task switching and multi-window',
      () {
    Future<FocusAwareWakeDevice> launch(WidgetTester tester) =>
        launchFocusAwareDevice(
          tester,
          protectedPackage: _pkg,
          label: 'CamScanner',
          pin: _pin,
        );

    /// Launcher -> protected app -> challenge presented and handed off.
    Future<PendingLockChallenge> challenge(FocusAwareWakeDevice device) async {
      await device.leaveToLauncher();
      await device.openProtectedApp();
      final PendingLockChallenge ticket = device.native.pending!;
      await device.activityResumes();
      await device.pumpFor(const Duration(seconds: 1));
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      return ticket;
    }

    Future<void> unlock(FocusAwareWakeDevice device) async {
      await device.enterPin(_pin);
      await device.pumpFor(const Duration(seconds: 1));
    }

    testWidgets(
        'SIMULATED: protected -> own UI (Back) -> protected re-challenges '
        'and grants exactly once more', (WidgetTester tester) async {
      final FocusAwareWakeDevice device = await launch(tester);
      final StaticNativeChallengeContract native = device.native;
      await challenge(device);
      await unlock(device);
      expect(native.authorizedPackages, <String>{_pkg});
      expect(device.apps.launchAppCalls, 1);

      // The launched app is in front.
      await device.activityStops();
      await device.reportForeground(_pkg);
      expect(native.shieldVisible, isFalse);

      // Back returns to Smart App Lock's own task (no detector report).
      await device.activityResumes();
      expect(native.authorizedPackages, isEmpty);
      expect(native.currentForegroundPackage,
          StaticNativeChallengeContract.ownPackage);

      // Recents / quick switch back to the protected app.
      await device.activityStops();
      await device.reportForeground(_pkg);
      expect(native.shieldVisible, isTrue);
      final PendingLockChallenge again = native.pending!;
      expect(again.packageName, _pkg);
      await device.activityResumes();
      await device.pumpFor(const Duration(seconds: 1));
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(native.authorizedPackages, isEmpty);

      await unlock(device);
      expect(native.authorizedPackages, <String>{_pkg});
      expect(native.pending, isNull);
      expect(device.apps.launchAppCalls, 2);
      expect(device.resumedWhileUnfocused, isEmpty);
    });

    testWidgets(
        'SIMULATED: a challenge in split screen keeps the shield, never '
        'grants, and hands off after returning to full screen',
        (WidgetTester tester) async {
      final FocusAwareWakeDevice device = await launch(tester);
      final StaticNativeChallengeContract native = device.native;
      await device.leaveToLauncher();
      await device.openProtectedApp();
      final PendingLockChallenge ticket = native.pending!;

      // MainActivity resumes in a split-screen pane.
      native.inMultiWindow = true;
      await device.activityResumes();
      await device.pumpFor(const Duration(seconds: 3));
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(native.shieldVisible, isTrue);
      expect(native.multiWindowNotice, isTrue);
      expect(native.readyAccepted, 0);
      expect(
        native.readyRejections
            .where((Set<NativeReadyRejection> r) =>
                r.contains(NativeReadyRejection.multiWindow))
            .length,
        greaterThanOrEqualTo(2),
        reason: 'the bounded retry keeps asking; native keeps refusing',
      );
      expect(device.flutterState, isNot(AppLifecycleState.resumed));

      // Even a correct PIN typed behind the shield cannot authorize.
      await device.enterPin(_pin);
      expect(native.authorizedPackages, isEmpty);
      expect(native.pending, ticket);
      expect(device.apps.launchAppCalls, 0);
      expect(device.dartSession(), isNull);

      // Full screen again: the same ticket is handed off.
      native.onMultiWindowModeChanged(false);
      tester.view.physicalSize = const Size(800, 1601);
      await device.pumpFor(const Duration(seconds: 2));
      expect(native.shieldVisible, isFalse);
      expect(native.readyChallenge, native.pending);
      expect(native.pending?.packageName, _pkg);
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      await unlock(device);
      expect(native.authorizedPackages, <String>{_pkg});
      expect(device.apps.launchAppCalls, 1);
      expect(device.resumedWhileUnfocused, isEmpty);
    });

    testWidgets(
        'SIMULATED: entering split screen over a rendered challenge '
        're-raises the shield; the protected pane is re-covered',
        (WidgetTester tester) async {
      final FocusAwareWakeDevice device = await launch(tester);
      final StaticNativeChallengeContract native = device.native;
      final PendingLockChallenge ticket = await challenge(device);
      expect(native.readyChallenge, ticket);
      expect(native.shieldVisible, isFalse);

      native.onMultiWindowModeChanged(true);
      tester.view.physicalSize = const Size(800, 800);
      await device.pumpFor(const Duration(seconds: 2));
      expect(native.shieldVisible, isTrue);
      expect(native.readyChallenge, isNull);
      expect(native.authorizePackage(ticket), isFalse);

      // Android 10+ multi-resume: the protected app in the other pane is
      // reported while MainActivity stays resumed.
      final int attempts = native.recoveryAttempts.length;
      await device.reportForeground(_pkg);
      await device.pumpFor(const Duration(seconds: 1));
      expect(native.recoveryAttempts.length, greaterThan(attempts));
      expect(native.shieldVisible, isTrue);
      expect(native.authorizedPackages, isEmpty);

      native.onMultiWindowModeChanged(false);
      tester.view.physicalSize = const Size(800, 1600);
      await device.pumpFor(const Duration(seconds: 2));
      expect(native.shieldVisible, isFalse);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await unlock(device);
      expect(native.authorizedPackages, <String>{_pkg});
      expect(device.apps.launchAppCalls, 1);
      expect(device.resumedWhileUnfocused, isEmpty);
    });

    testWidgets(
        'SIMULATED (liveness limitation): a route closed under the '
        'multi-window shield stays fail-closed until the next Activity '
        'resume, which re-presents and grants once',
        (WidgetTester tester) async {
      final FocusAwareWakeDevice device = await launch(tester);
      final StaticNativeChallengeContract native = device.native;
      final PendingLockChallenge ticket = await challenge(device);
      native.onMultiWindowModeChanged(true);
      tester.view.physicalSize = const Size(800, 800);
      await device.pumpFor(const Duration(seconds: 2));
      expect(native.shieldVisible, isTrue);

      // The harness does not block taps under the shield (a device
      // overlay does). A correct PIN still cannot authorize; native
      // refuses and the host closes the route without a grant.
      await device.enterPin(_pin);
      expect(native.authorizedPackages, isEmpty);
      expect(native.pending, ticket);
      expect(device.apps.launchAppCalls, 0);
      expect(device.dartSession(), isNull);

      // Back to full screen: the downward `inactive` gives the host no
      // recovery trigger, so the shield simply stays (fail closed).
      native.onMultiWindowModeChanged(false);
      tester.view.physicalSize = const Size(800, 1600);
      await device.pumpFor(const Duration(seconds: 3));
      expect(native.shieldVisible, isTrue);
      expect(native.authorizedPackages, isEmpty);

      // Home / Recents and back: the next resume recovers the same ticket.
      await device.activityStops();
      await device.activityResumes();
      await device.pumpFor(const Duration(seconds: 1));
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(native.shieldVisible, isFalse);
      expect(native.pending, ticket);
      await unlock(device);
      expect(native.authorizedPackages, <String>{_pkg});
      expect(device.apps.launchAppCalls, 1);
    });

    testWidgets(
        'SIMULATED: leaving split screen is re-acknowledged on the metrics '
        'change itself, before the bounded retry', (WidgetTester tester) async {
      final FocusAwareWakeDevice device = await launch(tester);
      final StaticNativeChallengeContract native = device.native;
      final PendingLockChallenge ticket = await challenge(device);
      native.onMultiWindowModeChanged(true);
      tester.view.physicalSize = const Size(800, 800);
      await device.pumpFor(const Duration(seconds: 2));
      expect(native.shieldVisible, isTrue);

      native.onMultiWindowModeChanged(false);
      final int accepted = native.readyAccepted;
      tester.view.physicalSize = const Size(800, 1600);
      await tester.pump(); // the metrics frame
      await tester.pump(); // post-frame acknowledgement
      await tester.pump(const Duration(milliseconds: 50));
      expect(native.readyAccepted, accepted + 1);
      expect(native.readyChallenge, ticket);
      expect(native.shieldVisible, isFalse);
    });
  });

  // -------------------------------------------------------------------
  // Group C — rotation and Activity recreation
  // -------------------------------------------------------------------
  group('SIMULATED C: rotation and recreation', () {
    Future<FocusAwareWakeDevice> launch(WidgetTester tester) =>
        launchFocusAwareDevice(
          tester,
          protectedPackage: _pkg,
          label: 'CamScanner',
          pin: _pin,
        );

    testWidgets(
        'SIMULATED: rotation storm during a challenge keeps one route, one '
        'ticket generation and grants exactly once',
        (WidgetTester tester) async {
      final FocusAwareWakeDevice device = await launch(tester);
      final StaticNativeChallengeContract native = device.native;
      await device.leaveToLauncher();
      await device.openProtectedApp();
      final PendingLockChallenge ticket = native.pending!;
      await device.activityResumes();
      await device.pumpFor(const Duration(seconds: 1));
      final int shows = device.overlay.showLockChallengeCalls;

      // A wrong attempt before rotating is not forgotten or repeated.
      await device.enterPin('9999');
      expect(native.authorizedPackages, isEmpty);

      for (int i = 0; i < 6; i++) {
        tester.view.physicalSize =
            i.isEven ? const Size(1600, 800) : const Size(800, 1600);
        await device.pumpFor(const Duration(milliseconds: 300));
        expect(find.byType(PinUnlockScreen), findsOneWidget, reason: 'r$i');
        expect(native.pending, ticket, reason: 'rotation $i');
        expect(native.readyChallenge, ticket);
        expect(native.shieldVisible, isFalse);
        expect(native.authorizedPackages, isEmpty);
      }
      expect(device.overlay.showLockChallengeCalls, shows,
          reason: 'no re-presentation / stacking on rotation');
      expect(device.challengeRouteOnStack(), isTrue);

      await device.enterPin(_pin);
      await device.pumpFor(const Duration(seconds: 1));
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(native.authorizedPackages, <String>{_pkg});
      expect(native.pending, isNull);
      expect(device.apps.launchAppCalls, 1);
      expect(native.authorizeRejections, 0);

      // Rotating after the grant neither revokes nor duplicates it.
      tester.view.physicalSize = const Size(1600, 800);
      await device.pumpFor(const Duration(milliseconds: 300));
      expect(native.authorizedPackages, <String>{_pkg});
      expect(device.apps.launchAppCalls, 1);
      expect(device.resumedWhileUnfocused, isEmpty);
    });

    testWidgets(
        'SIMULATED: an active lockout survives rotation; the correct PIN '
        'stays refused', (WidgetTester tester) async {
      final FocusAwareWakeDevice device = await launch(tester);
      final StaticNativeChallengeContract native = device.native;
      await device.leaveToLauncher();
      await device.openProtectedApp();
      await device.activityResumes();
      await device.pumpFor(const Duration(seconds: 1));
      for (int i = 0; i < 5; i++) {
        await device.enterPin('9999');
      }
      tester.view.physicalSize = const Size(1600, 800);
      await device.pumpFor(const Duration(milliseconds: 500));
      tester.view.physicalSize = const Size(800, 1600);
      await device.pumpFor(const Duration(milliseconds: 500));
      await device.enterPin(_pin);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(native.authorizedPackages, isEmpty);
      expect(device.apps.launchAppCalls, 0);
      expect(device.dartSession(), isNull);
    });

    testWidgets(
        'SIMULATED: Activity recreation mid-challenge (process alive) keeps '
        'the native ticket, re-presents once and grants exactly once',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final InMemoryLocalDatabase database = InMemoryLocalDatabase();
      final InMemorySecretStore secretStore = InMemorySecretStore();

      AppContainer bootOver(StaticNativeChallengeContract? native) {
        final AppContainer c = AppContainer.inMemory(
          database: database,
          secretStore: secretStore,
        );
        if (native != null) {
          (c.overlay as StaticOverlayLockService).nativeContract = native;
          (c.watcher as StaticWatcherService).nativeContract = native;
        }
        return c;
      }

      final AppContainer first = bootOver(null);
      final StaticNativeChallengeContract native =
          StaticNativeChallengeContract.bind(
        overlay: first.overlay as StaticOverlayLockService,
        watcher: first.watcher as StaticWatcherService,
      );
      await first.auth.enrollPin(_pin);
      await first.protectedApps.add(
        ProtectedApp(
          packageName: _pkg,
          label: 'CamScanner',
          addedAt: DateTime(2026, 10, 31),
        ),
      );
      await first.protectionBootstrap.synchronize();
      await tester.pumpWidget(SmartAppLockApp(container: first));
      await tester.pumpAndSettle();

      native.activityResumed = false;
      native.reportForeground(_pkg);
      (first.accessibility as StaticAccessibilityLockService)
          .emitForegroundPackage(_pkg);
      native.onActivityResumed();
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      final PendingLockChallenge ticket = native.pending!;
      expect(native.readyChallenge, ticket);
      await tester.tap(find.byKey(const Key('pin_key_9')));
      await tester.pumpAndSettle();

      // Recreation: onPause/onDestroy, a fresh engine and widget tree; the
      // service process and its native state survive.
      native.onActivityPaused();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(native.pending, ticket);
      expect(native.authorizedPackages, isEmpty);

      final AppContainer second = bootOver(native);
      await second.protectionBootstrap.synchronize();
      await tester.pumpWidget(SmartAppLockApp(container: second));
      native.onActivityResumed(); // the recreated Activity resumes
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(native.pending, ticket, reason: 'same generation, no stacking');
      expect(native.authorizedPackages, isEmpty,
          reason: 'own-UI resume over a pending ticket changes nothing');

      for (final String digit in _pin.split('')) {
        await tester.tap(find.byKey(Key('pin_key_$digit')));
        await tester.pumpAndSettle();
      }
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(native.authorizedPackages, <String>{_pkg});
      expect(native.pending, isNull);
      expect(
        (second.accessController as DefaultAccessController).sessionFor(_pkg),
        isNotNull,
      );
      final StaticInstalledAppsService apps =
          second.installedAppsService as StaticInstalledAppsService;
      expect(apps.launchAppCalls, 1);
      expect(native.authorizeRejections, 0);
    });
  });
}
