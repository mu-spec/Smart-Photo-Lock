import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/services/impl/static_native_challenge_contract.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/pending_lock_challenge.dart';

/// Phase 5 / Milestone 3 — Fix #1 (H-4): the strict native-contract
/// double must accept and reject exactly as the Kotlin sources do at
/// baseline `e20d525`. The Kotlin references are listed in
/// `static_native_challenge_contract.dart`.
void main() {
  const String app = 'com.whatsapp';
  const String other = 'com.example.bank';

  StaticNativeChallengeContract configured() {
    final StaticNativeChallengeContract native =
        StaticNativeChallengeContract();
    native.configure(enabled: true, packages: <String>{app, other});
    return native;
  }

  group('ticket store (ProtectionStateStore)', () {
    test('the same package keeps its generation; replacement mints a new one',
        () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge a = native.ensurePendingChallenge(app);
      expect(native.ensurePendingChallenge(app), a);
      final PendingLockChallenge b = native.replacePendingChallenge(app);
      expect(b.packageName, app);
      expect(b.generation, greaterThan(a.generation));
      final PendingLockChallenge c = native.ensurePendingChallenge(other);
      expect(c.generation, greaterThan(b.generation));
    });

    test('replacement invalidates an accepted handoff', () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = native.showLockChallenge(app)!;
      expect(native.markChallengeReady(ticket), isTrue);
      native.replacePendingChallenge(app);
      expect(native.readyChallenge, isNull);
    });
  });

  group('markChallengeReady (OverlayStatusChannel + ChallengeReadyPolicy)',
      () {
    test('accepted only for the exact ticket, resumed, keyguard unlocked',
        () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = native.showLockChallenge(app)!;
      expect(native.shieldVisible, isTrue);

      expect(native.markChallengeReady(ticket), isTrue);
      expect(native.readyChallenge, ticket);
      expect(native.shieldVisible, isFalse);
      expect(native.pending, ticket,
          reason: 'a ready acknowledgement never clears the ticket');
    });

    test('rejected while the keyguard is locked, with no state change', () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = native.showLockChallenge(app)!;
      native.lockKeyguard();

      expect(native.markChallengeReady(ticket), isFalse);
      expect(native.readyRejections.single,
          <NativeReadyRejection>{NativeReadyRejection.keyguardLocked});
      expect(native.readyChallenge, isNull);
      expect(native.shieldVisible, isTrue);
      expect(native.pending, ticket);
    });

    test('rejected while the activity is not resumed', () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = native.showLockChallenge(app)!;
      native.onActivityPaused();

      expect(native.markChallengeReady(ticket), isFalse);
      expect(native.readyRejections.single,
          <NativeReadyRejection>{NativeReadyRejection.activityNotResumed});
      expect(native.shieldVisible, isTrue);
    });

    test('rejected for a stale generation, another package, a negative '
        'generation, or no pending ticket', () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = native.showLockChallenge(app)!;
      final List<PendingLockChallenge> wrong = <PendingLockChallenge>[
        PendingLockChallenge(
          packageName: app,
          generation: ticket.generation - 1,
        ),
        PendingLockChallenge(packageName: other, generation: ticket.generation),
        const PendingLockChallenge(packageName: app, generation: -1),
        const PendingLockChallenge(packageName: '', generation: 1),
      ];
      for (final PendingLockChallenge candidate in wrong) {
        expect(native.markChallengeReady(candidate), isFalse);
      }
      native.clearPendingChallenge();
      expect(native.markChallengeReady(ticket), isFalse);
      expect(
        native.readyRejections.every(
          (Set<NativeReadyRejection> r) =>
              r.length == 1 && r.contains(NativeReadyRejection.ticketMismatch),
        ),
        isTrue,
      );
      expect(native.readyChallenge, isNull);
    });

    test('a failed shield hide replaces the ticket (onChallengeHandoffFailed)',
        () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = native.showLockChallenge(app)!;
      native.shieldHideSucceeds = false;

      expect(native.markChallengeReady(ticket), isFalse);
      expect(native.readyChallenge, isNull);
      expect(native.pending!.packageName, app);
      expect(native.pending!.generation, greaterThan(ticket.generation));
    });
  });

  group('authorizePackage (WatcherService.authorizePackage)', () {
    test('an exact pending ticket WITHOUT a ready handoff cannot authorize',
        () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = native.showLockChallenge(app)!;

      expect(native.authorizePackage(ticket), isFalse);
      expect(native.authorizedPackages, isEmpty);
      expect(native.pending, ticket);
    });

    test('after an accepted handoff it authorizes once and clears the ticket',
        () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = native.showLockChallenge(app)!;
      expect(native.markChallengeReady(ticket), isTrue);

      expect(native.authorizePackage(ticket), isTrue);
      expect(native.authorizedPackages, <String>{app});
      expect(native.pending, isNull);
      expect(native.readyChallenge, isNull, reason: 'handoff is consumed');
      expect(native.hideLockChallenge(), isTrue);
    });

    test('rejected for an unprotected package or a stale ticket', () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = native.showLockChallenge(app)!;
      expect(native.markChallengeReady(ticket), isTrue);
      expect(
        native.authorizePackage(
          PendingLockChallenge(
            packageName: app,
            generation: ticket.generation + 1,
          ),
        ),
        isFalse,
      );
      native.configure(enabled: true, packages: <String>{other});
      expect(native.authorizePackage(ticket), isFalse);
    });
  });

  group('hideLockChallenge', () {
    test('refused while a ticket is pending', () {
      final StaticNativeChallengeContract native = configured();
      native.showLockChallenge(app);
      expect(native.hideLockChallenge(), isFalse);
      expect(native.shieldVisible, isTrue);
    });
  });

  group('screen and keyguard transitions', () {
    test('SCREEN_OFF invalidates the handoff and mints a wake generation', () {
      final StaticNativeChallengeContract native = configured();
      native.reportForeground(app);
      final PendingLockChallenge preSleep = native.showLockChallenge(app)!;
      expect(native.markChallengeReady(preSleep), isTrue);

      native.screenOff();
      final PendingLockChallenge wake = native.pending!;
      expect(wake.packageName, app);
      expect(wake.generation, greaterThan(preSleep.generation));
      expect(native.readyChallenge, isNull);
      expect(native.shieldVisible, isTrue);
      expect(native.authorizedPackages, isEmpty);

      // Pre-sleep callbacks are stale.
      expect(native.markChallengeReady(preSleep), isFalse);
      expect(native.authorizePackage(preSleep), isFalse);
    });

    test('native SCREEN_ON, USER_PRESENT and retry never clear the shield '
        'on their own (they never call into Dart)', () {
      final StaticNativeChallengeContract native = configured();
      native.reportForeground(app);
      native.screenOff();
      native.onActivityPaused();
      native.lockKeyguard();

      native.screenOn();
      native.onActivityResumed();
      native.dismissKeyguard();
      native.recoveryRetryTick();
      native.recoveryRetryTick();

      expect(native.shieldVisible, isTrue);
      expect(native.readyChallenge, isNull);
      expect(native.readyAcknowledgements, 0);
      expect(native.recoveryAttempts, containsAllInOrder(<NativeRecoverySignal>[
        NativeRecoverySignal.screenOn,
        NativeRecoverySignal.userPresent,
        NativeRecoverySignal.retry,
      ]));
      // Only one exact acknowledgement is needed once preconditions hold.
      expect(native.readyBlockers(native.pending!), isEmpty);
    });

    test(
        'a genuine leave (Activity paused, then an unprotected app is '
        'reported) after a rendered challenge abandons it', () {
      final StaticNativeChallengeContract native = configured();
      native.reportForeground(app);
      final PendingLockChallenge ticket = native.showLockChallenge(app)!;
      expect(native.markChallengeReady(ticket), isTrue);

      // H-1 F1: a report while MainActivity is still resumed only defers
      // (see test/regression/h1_transient_foreground_test.dart).
      native.onActivityPaused();
      native.reportForeground('com.android.launcher');
      expect(native.pending, isNull);
      expect(native.readyChallenge, isNull);
      expect(native.wakeReauthPackage, isNull);
    });
  });

  group('static doubles bound to the contract', () {
    test('rejections surface as Result failures; authorization needs ready',
        () async {
      final StaticOverlayLockService overlay = StaticOverlayLockService();
      final StaticWatcherService watcher = StaticWatcherService();
      final StaticNativeChallengeContract native =
          StaticNativeChallengeContract.bind(
        overlay: overlay,
        watcher: watcher,
      );
      await watcher.configureProtection(
        enabled: true,
        protectedPackages: <String>{app},
      );
      expect(native.isProtected(app), isTrue);

      final PendingLockChallenge ticket =
          (await overlay.showLockChallenge(app)).valueOrNull!;
      expect((await watcher.takePendingChallenge()).valueOrNull, ticket);

      native.lockKeyguard();
      expect((await overlay.markChallengeReady(ticket)).isFailure, isTrue);
      expect((await watcher.authorizePackage(ticket)).isFailure, isTrue);
      expect((await overlay.hideLockChallenge()).isFailure, isTrue);

      native.dismissKeyguard();
      expect((await overlay.markChallengeReady(ticket)).isSuccess, isTrue);
      expect((await watcher.authorizePackage(ticket)).isSuccess, isTrue);
      expect((await watcher.takePendingChallenge()).valueOrNull, isNull);
      expect((await overlay.hideLockChallenge()).isSuccess, isTrue);
    });

    test('unbound doubles keep their legacy lenient behaviour', () async {
      final StaticOverlayLockService overlay = StaticOverlayLockService();
      final StaticWatcherService watcher = StaticWatcherService();
      await watcher.configureProtection(
        enabled: true,
        protectedPackages: <String>{app},
      );
      final PendingLockChallenge ticket =
          (await overlay.showLockChallenge(app)).valueOrNull!;
      expect((await overlay.markChallengeReady(ticket)).isSuccess, isTrue);
      // Legacy gap documented by H-4: native would reject this.
      expect((await watcher.authorizePackage(ticket)).isSuccess, isTrue);
    });
  });
}
