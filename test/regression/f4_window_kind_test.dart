import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/services/impl/static_native_challenge_contract.dart';
import 'package:smart_app_lock/services/pending_lock_challenge.dart';

/// Phase 5 / F4 P1: an unprotected foreground report proves a genuine leave
/// only through the resolved Home package, a UsageEvents activity resume or
/// an Accessibility window class resolved to an Activity of the reporting
/// package. An UNCONFIRMED report (overlay, dialog, null class, failed
/// lookup, package mismatch) keeps the wake identity and the ready ticket,
/// but it still revokes authorization exactly as before.
///
/// SIMULATED. Every test here runs against [StaticNativeChallengeContract],
/// a Dart model of the Kotlin `WatcherService` / `WindowLeavePolicy` rules.
/// The window kind is supplied by the test; nothing here executes Kotlin,
/// PackageManager, Accessibility, UsageEvents or a real ColorOS window, and
/// nothing here is evidence of device behaviour. The pure classification
/// (null class, failed lookup, mismatch) is tested in
/// `android/app/src/test/.../WindowLeavePolicyTest.kt`.
const String _pkg = 'com.intsig.camscanner';
const String _home = 'com.oppo.launcher';
const String _ime = 'com.google.android.inputmethod.latin';
const String _notes = 'com.example.notes';
const String _discover = 'com.google.android.googlequicksearchbox';

/// Unconfirmed windows: ColorOS (unverified on device while interactive),
/// a third-party chat head and the launcher-hosted Discover overlay.
const List<String> _overlays = <String>[
  'com.coloros.gesture',
  'com.coloros.screenshot',
  'com.facebook.orca',
  _discover,
];

void main() {
  StaticNativeChallengeContract configured() {
    final StaticNativeChallengeContract native =
        StaticNativeChallengeContract();
    native.configure(enabled: true, packages: <String>{_pkg});
    native.inputMethodPackage = _ime;
    native.homePackage = _home; // the safe-exit Home resolver's answer
    return native;
  }

  PendingLockChallenge readyChallenge(StaticNativeChallengeContract native) {
    native.reportForeground(_pkg);
    final PendingLockChallenge ticket = native.showLockChallenge(_pkg)!;
    expect(native.markChallengeReady(ticket), isTrue);
    expect(native.readyChallenge, ticket);
    return ticket;
  }

  /// Challenge accepted, MainActivity pauses, the protected app is in front.
  void authorizedInFront(StaticNativeChallengeContract native) {
    final PendingLockChallenge ticket = readyChallenge(native);
    expect(native.authorizePackage(ticket), isTrue);
    native.onActivityPaused();
    native.reportForeground(_pkg);
    expect(native.pending, isNull);
    expect(native.authorizedPackages, contains(_pkg));
    expect(native.wakeReauthPackage, _pkg);
  }

  void sleepAndWake(StaticNativeChallengeContract native) {
    native.screenOff();
    native.lockKeyguard();
    native.screenOn();
    native.dismissKeyguard();
  }

  group('SIMULATED F4: unconfirmed overlays while the protected app is used',
      () {
    for (final String overlay in _overlays) {
      test(
          'SIMULATED: "$overlay" overlay keeps the wake identity; screen-off '
          'creates the wake ticket', () {
        final StaticNativeChallengeContract native = configured();
        authorizedInFront(native);

        native.reportForeground(overlay,
            windowKind: NativeWindowKind.unconfirmed);
        expect(native.wakeReauthPackage, _pkg);
        // Authorization is still revoked by the foreground change.
        expect(native.authorizedPackages, isEmpty);

        sleepAndWake(native);
        expect(native.pending?.packageName, _pkg);
        expect(native.shieldVisible, isTrue);
        expect(native.recoveryAttempts,
            contains(NativeRecoverySignal.userPresent));
      });
    }

    test(
        'SIMULATED: returning to the protected app after an overlay needs a '
        'fresh authentication (no stale authorization)', () {
      final StaticNativeChallengeContract native = configured();
      authorizedInFront(native);
      native.reportForeground('com.coloros.gesture',
          windowKind: NativeWindowKind.unconfirmed);
      native.reportForeground(_pkg);
      expect(native.authorizedPackages, isEmpty);
      expect(native.pending?.packageName, _pkg);
      expect(
          native.recoveryAttempts, contains(NativeRecoverySignal.foreground));
      expect(native.shieldVisible, isTrue);
    });

    test(
        'SIMULATED: a later confirmed activity of another app forgets the '
        'retained identity (no false wake challenge)', () {
      final StaticNativeChallengeContract native = configured();
      authorizedInFront(native);
      native.reportForeground('com.coloros.gesture',
          windowKind: NativeWindowKind.unconfirmed);
      expect(native.wakeReauthPackage, _pkg);
      native.reportForeground(_notes); // Activity window of the notes app
      expect(native.wakeReauthPackage, isNull);
      sleepAndWake(native);
      expect(native.pending, isNull);
      expect(native.shieldVisible, isFalse);
    });

    test(
        'SIMULATED: the screen-off preserve branch is unchanged for both '
        'window kinds', () {
      for (final NativeWindowKind kind in <NativeWindowKind>[
        NativeWindowKind.unconfirmed,
        NativeWindowKind.activity,
      ]) {
        final StaticNativeChallengeContract native = configured();
        authorizedInFront(native);
        native.screenInteractive = false; // display-off transition
        native.reportForeground('com.coloros.gesture', windowKind: kind);
        expect(native.wakeReauthPackage, _pkg, reason: '$kind');
        expect(native.authorizedPackages, isEmpty, reason: '$kind');
      }
    });
  });

  group('SIMULATED F4: confirmed genuine leaves keep the existing behaviour',
      () {
    for (final NativeWindowKind kind in <NativeWindowKind>[
      NativeWindowKind.activity,
      NativeWindowKind.usageActivity,
    ]) {
      test(
          'SIMULATED: $kind navigation to an unprotected app forgets the '
          'identity; no false wake challenge', () {
        final StaticNativeChallengeContract native = configured();
        authorizedInFront(native);
        native.reportForeground(_notes, windowKind: kind);
        expect(native.wakeReauthPackage, isNull);
        expect(native.authorizedPackages, isEmpty);
        sleepAndWake(native);
        expect(native.pending, isNull);
        expect(native.shieldVisible, isFalse);
      });

      test(
          'SIMULATED: $kind leave while the challenge is resumed defers, '
          'and the matching onPause abandons', () {
        final StaticNativeChallengeContract native = configured();
        final PendingLockChallenge ticket = readyChallenge(native);
        native.elapsedMs = 10000;
        native.reportForeground(_notes, windowKind: kind);
        expect(native.abandonCandidate?.ticket, ticket);
        expect(native.pending, ticket);
        native.elapsedMs += 400;
        native.onActivityPaused();
        expect(native.pending, isNull);
        expect(native.shieldVisible, isFalse);
      });

      test('SIMULATED: $kind leave after the challenge paused abandons', () {
        final StaticNativeChallengeContract native = configured();
        final PendingLockChallenge ticket = readyChallenge(native);
        native.activityResumed = false;
        native.reportForeground(_notes, windowKind: kind);
        expect(native.pending, isNull);
        expect(native.readyChallenge, isNull);
        expect(ticket.packageName, _pkg);
      });
    }
  });

  group('SIMULATED F4: ready ticket and unconfirmed windows', () {
    for (final String overlay in _overlays) {
      test(
          'SIMULATED: "$overlay" overlay then onPause within 1.5 s keeps the '
          'exact ticket', () {
        final StaticNativeChallengeContract native = configured();
        final PendingLockChallenge ticket = readyChallenge(native);
        native.elapsedMs = 10000;
        native.reportForeground(overlay,
            windowKind: NativeWindowKind.unconfirmed);
        expect(native.abandonCandidate, isNull);
        native.elapsedMs += 400;
        native.onActivityPaused();
        expect(native.pending, ticket);
        expect(native.readyChallenge, ticket);
        expect(native.wakeReauthPackage, _pkg);
        // The kept ticket still enforces: recovery re-presents it.
        native.recoveryRetryTick();
        expect(native.recoveryAttempts, contains(NativeRecoverySignal.retry));
        expect(native.shieldVisible, isTrue);
        expect(native.pending, ticket);
      });
    }

    test(
        'SIMULATED: an unconfirmed report after the challenge paused keeps '
        'the ticket (no immediate abandon)', () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = readyChallenge(native);
      native.activityResumed = false;
      native.reportForeground('com.coloros.gesture',
          windowKind: NativeWindowKind.unconfirmed);
      expect(native.pending, ticket);
      expect(native.readyChallenge, ticket);
    });
  });

  group('SIMULATED F4: Home and Recents (no challenge trap)', () {
    test(
        'SIMULATED: Home with an unknown window class is a confirmed leave '
        'and abandons on the matching onPause', () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = readyChallenge(native);
      native.elapsedMs = 10000;
      native.reportForeground(_home, windowKind: NativeWindowKind.unconfirmed);
      expect(native.abandonCandidate?.ticket, ticket);
      native.elapsedMs += 300;
      native.onActivityPaused();
      expect(native.pending, isNull);
      expect(native.wakeReauthPackage, isNull);
      sleepAndWake(native);
      expect(native.pending, isNull, reason: 'no false wake challenge');
    });

    test(
        'SIMULATED: ColorOS Recents hosted by the Home package abandons; '
        'AOSP Recents in System UI keeps the ticket until a real leave', () {
      final StaticNativeChallengeContract coloros = configured();
      readyChallenge(coloros);
      coloros.activityResumed = false;
      coloros.reportForeground(_home, windowKind: NativeWindowKind.unconfirmed);
      expect(coloros.pending, isNull);

      final StaticNativeChallengeContract aosp = configured();
      final PendingLockChallenge ticket = readyChallenge(aosp);
      aosp.activityResumed = false;
      aosp.reportForeground('com.android.systemui',
          windowKind: NativeWindowKind.unconfirmed);
      expect(aosp.pending, ticket, reason: 'H-1 transient, unchanged');
      aosp.reportForeground(_notes); // the user picks an app from Recents
      expect(aosp.pending, isNull);
    });

    test(
        'SIMULATED: a launcher-hosted overlay is unconfirmed until the Home '
        'package itself reports', () {
      final StaticNativeChallengeContract native = configured();
      final PendingLockChallenge ticket = readyChallenge(native);
      native.elapsedMs = 10000;
      native.reportForeground(_discover,
          windowKind: NativeWindowKind.unconfirmed);
      expect(native.abandonCandidate, isNull);
      expect(native.wakeReauthPackage, _pkg);
      native.reportForeground(_home, windowKind: NativeWindowKind.unconfirmed);
      expect(native.abandonCandidate?.ticket, ticket);
      native.elapsedMs += 200;
      native.onActivityPaused();
      expect(native.pending, isNull);
    });

    test(
        'SIMULATED: a launcher package name is not Home unless the resolver '
        'returned it', () {
      final StaticNativeChallengeContract native = configured();
      native.homePackage = 'com.example.otherhome';
      final PendingLockChallenge ticket = readyChallenge(native);
      native.reportForeground(_home, windowKind: NativeWindowKind.unconfirmed);
      expect(native.abandonCandidate, isNull);
      expect(native.pending, ticket);
      expect(native.wakeReauthPackage, _pkg);
    });
  });

  group('SIMULATED F4: F3 restart after an unconfirmed overlay', () {
    StaticNativeChallengeContract restart(StaticNativeChallengeContract dead) {
      final StaticNativeChallengeContract fresh =
          StaticNativeChallengeContract();
      fresh.configure(enabled: true, packages: <String>{_pkg});
      fresh.inputMethodPackage = _ime;
      fresh.homePackage = _home;
      fresh.bootCount = dead.bootCount;
      fresh.elapsedMs = dead.elapsedMs + 2000;
      fresh.wallClockOffsetMs = dead.wallClockOffsetMs;
      fresh.restorePersistedWakeIdentity(
        packageName: dead.wakeReauthPackage,
        bootCount: dead.wakeReauthBootCount,
        stampElapsedMs: dead.wakeReauthStampElapsedMs,
        stampWallMs: dead.wakeReauthStampWallMs,
      );
      fresh.pending = dead.pending;
      fresh.activityResumed = false;
      fresh.usageForegroundEvidence = null; // Usage Access OFF
      fresh.serviceStart();
      return fresh;
    }

    test(
        'SIMULATED: with Usage Access off the remembered target remains and '
        'the restart challenges', () {
      final StaticNativeChallengeContract native = configured();
      native.elapsedMs = 50000;
      authorizedInFront(native);
      native.reportForeground('com.coloros.gesture',
          windowKind: NativeWindowKind.unconfirmed);
      final StaticNativeChallengeContract fresh = restart(native);
      expect(fresh.lastRestartDecision,
          NativeRestartDecision.challengeRememberedForegroundUnknown);
      expect(fresh.pending?.packageName, _pkg);
      expect(fresh.shieldVisible, isTrue);
    });

    test(
        'SIMULATED: after a confirmed activity leave the restart has no '
        'protected target (unchanged)', () {
      final StaticNativeChallengeContract native = configured();
      native.elapsedMs = 50000;
      authorizedInFront(native);
      native.reportForeground(_notes);
      final StaticNativeChallengeContract fresh = restart(native);
      expect(fresh.lastRestartDecision,
          NativeRestartDecision.noneNoProtectedTarget);
      expect(fresh.pending, isNull);
    });
  });
}
