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

/// Phase 5 / Milestone 3, 5T process-death security audit. These are
/// TEST-ONLY regression tests. No production code was changed.
///
/// ## What these tests are and what they are not
///
/// They are SIMULATED process-death tests. They are NOT real process death.
/// Nothing here kills an Android process, removes a WindowManager overlay,
/// restarts a service or rebinds an AccessibilityService. They model the
/// state consequences of a death using:
///
///  * Flutter: a full widget-tree teardown, then a fresh [AppContainer]
///    over the same persisted stores (SQLite and Keystore stand-ins). This
///    is the same honest simulation as `process_recreation_test.dart`.
///  * Native: a fresh [StaticNativeChallengeContract] (the test-only
///    double of the Kotlin handoff contract). It carries over ONLY what
///    production persists in SharedPreferences
///    `smart_app_lock_protection_bootstrap`: the enabled flag, the
///    protected packages, the pending ticket (package and generation), the
///    generation counter, and the wake-reauth package. Everything
///    production holds in memory starts fresh: `ProtectionRuntime`
///    (`readyChallenge`, `activityResumed`), the `ProtectionAccessState`
///    authorizations, and overlay visibility (WindowManager removes a dead
///    process's windows).
///
/// The native restart order (sticky `onStartCommand`, then the
/// `recoverProtected(RETRY)` cold launch, then `MainActivity.onResume`,
/// then the Flutter mount) is driven explicitly, following the Kotlin
/// sources at HEAD `3277068`. These tests can show that the restore
/// CONTRACT fails closed under that model. They cannot measure the real
/// crash-to-shield exposure window on a device. That window remains
/// UNVERIFIED until a screen recording or frame evidence exists.
const String _protected = 'com.intsig.camscanner';
const String _pin = '1234';
const String _wrongPin = '9999';

/// The shared "disk": what survives a process death.
class _Disk {
  final InMemoryLocalDatabase database = InMemoryLocalDatabase();
  final InMemorySecretStore secretStore = InMemorySecretStore();
}

/// Snapshot of the native SharedPreferences fields at the instant of death.
class _PersistedNative {
  _PersistedNative({
    required this.enabled,
    required this.packages,
    required this.pending,
    required this.lastGeneration,
    required this.wakeReauthPackage,
  });

  final bool enabled;
  final Set<String> packages;
  final PendingLockChallenge? pending;
  final int lastGeneration;
  final String? wakeReauthPackage;
}

/// One simulated Smart App Lock process.
class _Process {
  _Process(this.tester, this.container, this.native);

  final WidgetTester tester;
  final AppContainer container;
  final StaticNativeChallengeContract native;

  StaticInstalledAppsService get apps =>
      container.installedAppsService as StaticInstalledAppsService;

  Object? dartSession() =>
      (container.accessController as DefaultAccessController)
          .sessionFor(_protected);

  /// Production order: Accessibility reports to native first, then to
  /// the Flutter event sink.
  Future<void> foreground(String packageName) async {
    native.reportForeground(packageName);
    (container.accessibility as StaticAccessibilityLockService)
        .emitForegroundPackage(packageName);
    await tester.pumpAndSettle();
  }

  Future<void> enterPin(String pin) async {
    for (final String digit in pin.split('')) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
  }
}

AppContainer _boot(_Disk disk) => AppContainer.inMemory(
      database: disk.database,
      secretStore: disk.secretStore,
    );

void _phoneView(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// First process: enrol, protect, configure native, mount the UI.
Future<_Process> _firstProcess(WidgetTester tester, _Disk disk) async {
  _phoneView(tester);
  final AppContainer container = _boot(disk);
  final StaticNativeChallengeContract native =
      StaticNativeChallengeContract.bind(
    overlay: container.overlay as StaticOverlayLockService,
    watcher: container.watcher as StaticWatcherService,
  );
  await container.auth.enrollPin(_pin);
  await container.protectedApps.add(
    ProtectedApp(
      packageName: _protected,
      label: 'CamScanner',
      addedAt: DateTime(2026, 10, 25),
    ),
  );
  await container.protectionBootstrap.synchronize();
  expect(native.isProtected(_protected), isTrue);
  await tester.pumpWidget(SmartAppLockApp(container: container));
  await tester.pumpAndSettle();
  return _Process(tester, container, native);
}

/// SIMULATED process death. The Flutter isolate's tree is torn down, and
/// the native model's persisted fields are snapshotted. The dead model is
/// discarded afterwards.
Future<_PersistedNative> _simulateProcessDeath(_Process dead) async {
  await dead.tester.pumpWidget(const SizedBox());
  await dead.tester.pumpAndSettle();
  final StaticNativeChallengeContract n = dead.native;
  final PendingLockChallenge? pending = n.pending;
  // The persisted generation counter (KEY_NEXT_GENERATION) is private in
  // the double. Probe it on the discarded model only: the next
  // replacement's generation minus one is the last issued generation.
  final _PersistedNative snapshot = _PersistedNative(
    enabled: n.enabled,
    packages: Set<String>.of(n.protectedPackages),
    pending: pending,
    lastGeneration: n.replacePendingChallenge('__probe__').generation - 1,
    wakeReauthPackage: n.wakeReauthPackage,
  );
  return snapshot;
}

/// The new process's native layer, built from persisted state only. No
/// Flutter UI is mounted yet: Android restarts the service process first.
_Process _newProcessNative(
  WidgetTester tester,
  _Disk disk,
  _PersistedNative persisted,
) {
  final AppContainer container = _boot(disk);
  final StaticNativeChallengeContract native =
      StaticNativeChallengeContract.bind(
    overlay: container.overlay as StaticOverlayLockService,
    watcher: container.watcher as StaticWatcherService,
  );
  // bind() copied the fresh, unconfigured Dart watcher. Production does
  // NOT call configure on a restart; SharedPreferences is simply read.
  // Restore exactly the persisted fields.
  native.enabled = persisted.enabled;
  native.protectedPackages = Set<String>.of(persisted.packages);
  while (native.replacePendingChallenge('__counter__').generation <
      persisted.lastGeneration) {}
  native.pending = persisted.pending;
  native.wakeReauthPackage = persisted.wakeReauthPackage;
  // Process-local state starts fresh. MainActivity does not exist yet,
  // so activityResumed is false. WindowManager removed the dead
  // process's shield.
  native.readyChallenge = null;
  native.activityResumed = false;
  native.shieldVisible = false;
  native.authorizedPackages.clear();
  native.currentForegroundPackage = null;
  return _Process(tester, container, native);
}

/// Sticky `WatcherService.onStartCommand`: arm, show the shield if a
/// ticket is pending, then `recoverProtected(RETRY)`, which cold-launches
/// MainActivity.
void _nativeServiceRestart(StaticNativeChallengeContract native) {
  native.recoveryRetryTick();
}

/// `MainActivity.onCreate/onResume` (recovery intent accepted), then the
/// Flutter engine mounts the app and the host bootstraps.
Future<void> _activityAndFlutterStart(_Process p) async {
  p.native.onActivityResumed();
  _phoneView(p.tester);
  await p.tester.pumpWidget(SmartAppLockApp(container: p.container));
  await p.tester.pumpAndSettle();
}

/// Brings the first process to "PIN challenge on screen, ready accepted".
Future<PendingLockChallenge> _challengeOnScreen(_Process p) async {
  await p.foreground(_protected);
  expect(find.byType(PinUnlockScreen), findsOneWidget);
  final PendingLockChallenge ticket = p.native.pending!;
  expect(ticket.packageName, _protected);
  expect(p.native.readyChallenge, ticket);
  expect(p.native.shieldVisible, isFalse);
  return ticket;
}

void main() {
  testWidgets(
      'SIMULATED process death mid-challenge: the persisted ticket is '
      'restored with the SAME generation, the shield precedes the UI, and '
      'only the correct PIN authorizes it', (WidgetTester tester) async {
    final _Disk disk = _Disk();
    final _Process a = await _firstProcess(tester, disk);
    final PendingLockChallenge beforeDeath = await _challengeOnScreen(a);

    final _PersistedNative persisted = await _simulateProcessDeath(a);
    expect(persisted.pending, beforeDeath,
        reason: 'replacePendingChallenge uses commit(): the ticket is on disk');

    final _Process b = _newProcessNative(tester, disk, persisted);
    // The crash-to-shield window, as modelled: the ticket is persisted,
    // but no shield exists and nothing is authorized. This test cannot
    // measure how long the window lasts on a device.
    expect(b.native.shieldVisible, isFalse);
    expect(b.native.authorizedPackages, isEmpty);
    expect(b.native.readyChallenge, isNull);

    _nativeServiceRestart(b.native);
    expect(b.native.shieldVisible, isTrue,
        reason: 'onStartCommand shows the shield before any UI exists');
    expect(b.native.pending, beforeDeath,
        reason: 'ensurePendingChallenge keeps the same package and '
            'generation (no regeneration on the nominal path)');
    expect(b.native.activityPromotions, 1);

    await _activityAndFlutterStart(b);
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(b.native.pending, beforeDeath);
    expect(b.native.readyChallenge, beforeDeath,
        reason: 'the restored route acknowledged the exact persisted ticket');
    expect(b.native.shieldVisible, isFalse);
    expect(b.dartSession(), isNull, reason: 'no Dart session survives');
    expect(b.native.authorizedPackages, isEmpty,
        reason: 'no native authorization survives');

    // Wrong PIN: nothing is granted, and the ticket is unchanged.
    await b.enterPin(_wrongPin);
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(b.native.authorizedPackages, isEmpty);
    expect(b.native.pending, beforeDeath);
    expect(b.dartSession(), isNull);
    expect(b.apps.launchAppCalls, 0);

    // Correct PIN: exactly one grant for the exact restored ticket.
    await b.enterPin(_pin);
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(b.native.authorizedPackages, <String>{_protected});
    expect(b.native.pending, isNull);
    expect(b.dartSession(), isNotNull);
    expect(b.apps.launchedPackages, <String>[_protected]);
    expect(b.native.authorizeRejections, 0);
  });

  testWidgets(
      'SIMULATED: duplicate restart signals (sticky restart, Accessibility '
      'rebind, retry ticks, repeated protected reports) never mint a new '
      'generation or stack challenges', (WidgetTester tester) async {
    final _Disk disk = _Disk();
    final _Process a = await _firstProcess(tester, disk);
    final PendingLockChallenge beforeDeath = await _challengeOnScreen(a);
    final _PersistedNative persisted = await _simulateProcessDeath(a);
    final _Process b = _newProcessNative(tester, disk, persisted);

    _nativeServiceRestart(b.native); // sticky onStartCommand
    _nativeServiceRestart(b.native); // a11y rebind -> start -> onStartCommand
    b.native.reportForeground(_protected); // first post-rebind a11y event
    b.native.reportForeground(_protected); // usage-events poll, same app
    b.native.recoveryRetryTick();
    expect(b.native.pending, beforeDeath);
    expect(b.native.shieldVisible, isTrue);

    await _activityAndFlutterStart(b);
    // A Dart LockRequired for the same package while the restored route is
    // up is the same challenge: it must not stack a second route.
    await b.foreground(_protected);
    await tester.pump(const Duration(seconds: 6)); // heartbeats and retries
    b.native.recoveryRetryTick();
    await tester.pumpAndSettle();

    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(b.native.pending, beforeDeath);
    expect(b.native.readyChallenge, beforeDeath);
    expect(b.native.shieldVisible, isFalse);

    await b.enterPin(_pin);
    expect(b.native.authorizedPackages, <String>{_protected});
    expect(b.apps.launchAppCalls, 1);
  });

  testWidgets(
      'SIMULATED: a generation replaced in the new process (screen off '
      'before the UI mounts) supersedes the persisted one; the stale ticket '
      'can neither acknowledge nor authorize', (WidgetTester tester) async {
    final _Disk disk = _Disk();
    final _Process a = await _firstProcess(tester, disk);
    final PendingLockChallenge stale = await _challengeOnScreen(a);
    final _PersistedNative persisted = await _simulateProcessDeath(a);
    final _Process b = _newProcessNative(tester, disk, persisted);

    _nativeServiceRestart(b.native);
    // SCREEN_OFF reaches the restarted watcher before Flutter mounts.
    b.native.currentForegroundPackage = _protected;
    b.native.screenOff();
    final PendingLockChallenge fresh = b.native.pending!;
    expect(fresh.packageName, _protected);
    expect(fresh.generation, greaterThan(stale.generation),
        reason: 'the persisted counter continues; there is no reuse');
    b.native.screenOn(); // the keyguard stays unlocked in this model

    // Stale callbacks for the pre-death generation are rejected.
    b.native.activityResumed = true;
    expect(b.native.markChallengeReady(stale), isFalse);
    expect(b.native.readyRejections.last,
        contains(NativeReadyRejection.ticketMismatch));
    expect(b.native.authorizePackage(stale), isFalse);
    expect(b.native.authorizedPackages, isEmpty);
    expect(b.native.pending, fresh);
    expect(b.native.shieldVisible, isTrue);
    b.native.activityResumed = false;

    await _activityAndFlutterStart(b);
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(b.native.readyChallenge, fresh);
    await b.enterPin(_pin);
    expect(b.native.authorizedPackages, <String>{_protected});
    expect(b.native.pending, isNull);
  });

  testWidgets(
      'SIMULATED: a failed shield hide after the restored ack '
      '(onChallengeHandoffFailed) regenerates; the route adopts the new '
      'ticket and the PIN authorizes only that one',
      (WidgetTester tester) async {
    final _Disk disk = _Disk();
    final _Process a = await _firstProcess(tester, disk);
    final PendingLockChallenge persistedTicket = await _challengeOnScreen(a);
    final _PersistedNative persisted = await _simulateProcessDeath(a);
    final _Process b = _newProcessNative(tester, disk, persisted);

    _nativeServiceRestart(b.native);
    b.native.shieldHideSucceeds = false; // updateViewLayout throws once
    await _activityAndFlutterStart(b);
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    final PendingLockChallenge regenerated = b.native.pending!;
    expect(regenerated.generation, greaterThan(persistedTicket.generation));
    expect(b.native.shieldVisible, isTrue, reason: 'fail closed');
    expect(b.native.authorizePackage(persistedTicket), isFalse);

    b.native.shieldHideSucceeds = true;
    for (int s = 1; s <= 12; s++) {
      await tester.pump(const Duration(seconds: 1));
      if (s % 3 == 0) b.native.recoveryRetryTick();
    }
    await tester.pumpAndSettle();
    expect(b.native.readyChallenge, b.native.pending);
    expect(b.native.shieldVisible, isFalse);

    await b.enterPin(_pin);
    expect(b.native.authorizedPackages, <String>{_protected});
    expect(b.native.pending, isNull);
    expect(b.apps.launchedPackages, <String>[_protected]);
  });

  // H-1 reconciliation (F1/F2, working tree on e5ca340). This test used to
  // be "SIMULATED (H-1 characterization)", which pinned the H-1 BUG: an
  // 'android' report cleared the restored ticket, so the correct PIN was
  // rejected and the host re-challenged. Under F1/F2 a framework window is
  // transient and proves no leave, so the exact ticket, the readiness
  // handoff and the wake identity are preserved. The old security property
  // (a cleared generation never authorizes; only a NEW generation does) is
  // kept by the genuine-leave test right after this one.
  testWidgets(
      'SIMULATED (H-1 corrected, F1/F2): after the restored ack, a transient '
      "framework report ('android', for example a system crash dialog) "
      'preserves the exact ticket, the readiness handoff and the wake '
      'identity; a wrong PIN is still rejected and only the correct PIN '
      'authorizes that same generation, exactly once',
      (WidgetTester tester) async {
    final _Disk disk = _Disk();
    final _Process a = await _firstProcess(tester, disk);
    final PendingLockChallenge persistedTicket = await _challengeOnScreen(a);
    final _PersistedNative persisted = await _simulateProcessDeath(a);
    expect(persisted.wakeReauthPackage, _protected,
        reason: 'the protected report persisted the wake identity');
    final _Process b = _newProcessNative(tester, disk, persisted);

    _nativeServiceRestart(b.native);
    await _activityAndFlutterStart(b);
    expect(b.native.pending, persistedTicket);
    expect(b.native.readyChallenge, persistedTicket);
    expect(b.native.wakeReauthPackage, _protected);
    final int acceptedBefore = b.native.readyAccepted;
    final int rejectionsBefore = b.native.authorizeRejections;

    // Native-only report (the a11y event of a non-protected window). The
    // Dart stream is not fed, so the route stays on screen, as when the
    // event belongs to a transient system window over Smart App Lock.
    b.native.reportForeground('android');
    expect(b.native.isTransientWindow('android'), isTrue);
    expect(b.native.pending, persistedTicket,
        reason: 'F1: a transient window never clears the exact ticket');
    expect(b.native.readyChallenge, persistedTicket,
        reason: 'F1: the readiness handoff is not invalidated');
    expect(b.native.wakeReauthPackage, _protected,
        reason: 'F2: a transient window never forgets the wake identity');
    expect(b.native.abandonCandidate, isNull,
        reason: 'a transient window is not even a leave candidate');
    // Preserving the ticket grants nothing.
    expect(b.native.authorizedPackages, isEmpty);
    expect(b.dartSession(), isNull);
    expect(b.apps.launchAppCalls, 0);
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    // Wrong PIN: still rejected; nothing is granted and the exact ticket
    // and handoff are unchanged.
    await b.enterPin(_wrongPin);
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(b.native.authorizedPackages, isEmpty);
    expect(b.native.pending, persistedTicket);
    expect(b.native.readyChallenge, persistedTicket);
    expect(b.dartSession(), isNull);
    expect(b.apps.launchAppCalls, 0);

    // Correct PIN: exactly one grant for the exact restored generation,
    // with no native rejection and no re-challenge or new handoff.
    await b.enterPin(_pin);
    await tester.pumpAndSettle();
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(b.native.authorizeRejections, rejectionsBefore,
        reason: 'the preserved generation is accepted first time');
    expect(b.native.readyAccepted, acceptedBefore,
        reason: 'no regenerated challenge was handed off');
    expect(b.native.authorizedPackages, <String>{_protected});
    expect(b.native.pending, isNull);
    expect(b.native.readyChallenge, isNull,
        reason: 'the exact handoff is consumed by the authorization');
    expect(b.dartSession(), isNotNull);
    expect(b.apps.launchedPackages, <String>[_protected]);

    // The consumed generation cannot be replayed.
    expect(b.native.authorizePackage(persistedTicket), isFalse);
    expect(b.native.authorizeRejections, rejectionsBefore + 1);
    expect(b.apps.launchedPackages, <String>[_protected]);
  });

  testWidgets(
      'SIMULATED (H-1 retained property): after the restored ack, a GENUINE '
      'leave (MainActivity paused, then the launcher reported) still clears '
      'the exact ticket; the correct PIN for the cleared generation CANNOT '
      'authorize, and the host re-challenges with a NEW generation that '
      'alone authorizes', (WidgetTester tester) async {
    final _Disk disk = _Disk();
    final _Process a = await _firstProcess(tester, disk);
    final PendingLockChallenge persistedTicket = await _challengeOnScreen(a);
    final _PersistedNative persisted = await _simulateProcessDeath(a);
    final _Process b = _newProcessNative(tester, disk, persisted);

    _nativeServiceRestart(b.native);
    await _activityAndFlutterStart(b);
    expect(b.native.readyChallenge, persistedTicket);

    // Genuine leave, native-only: MainActivity.onPause, then the launcher's
    // a11y event. The Dart stream is not fed, so the stale route stays.
    b.native.onActivityPaused();
    b.native.reportForeground('com.android.launcher');
    expect(b.native.isTransientWindow('com.android.launcher'), isFalse);
    expect(b.native.pending, isNull, reason: 'F1: a genuine leave clears it');
    expect(b.native.readyChallenge, isNull);
    expect(b.native.wakeReauthPackage, isNull,
        reason: 'F2: a genuine leave forgets the wake identity');
    expect(b.native.authorizedPackages, isEmpty);

    // The user returns to the stale PIN route (MainActivity.onResume).
    b.native.onActivityResumed();
    await tester.pumpAndSettle();
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    // The correct PIN for the cleared generation: native rejects it, Dart
    // revokes, and nothing launches.
    await b.enterPin(_pin);
    expect(b.native.authorizeRejections, greaterThanOrEqualTo(1));
    expect(b.native.authorizedPackages, isEmpty);
    expect(b.apps.launchAppCalls, 0);
    expect(b.dartSession(), isNull);
    expect(b.native.authorizePackage(persistedTicket), isFalse);
    expect(b.native.authorizedPackages, isEmpty);

    // The host re-challenges. The new route carries a NEW generation, and
    // only that generation can authorize.
    await tester.pumpAndSettle();
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    final PendingLockChallenge regenerated = b.native.pending!;
    expect(regenerated.packageName, _protected);
    expect(regenerated.generation, greaterThan(persistedTicket.generation));
    expect(b.native.readyChallenge, regenerated);
    await b.enterPin(_pin);
    expect(b.native.authorizedPackages, <String>{_protected});
    expect(b.native.pending, isNull);
    expect(b.apps.launchedPackages, <String>[_protected]);
  });

  testWidgets(
      'SIMULATED (Test C characterization): death while the protected app '
      'is open under a valid session. No authorization survives, but '
      'nothing re-locks the visible app until a foreground report arrives',
      (WidgetTester tester) async {
    final _Disk disk = _Disk();
    final _Process a = await _firstProcess(tester, disk);
    await _challengeOnScreen(a);
    await a.enterPin(_pin);
    await a.foreground(_protected); // the user is now inside the app
    expect(a.native.authorizedPackages, <String>{_protected});
    expect(a.native.pending, isNull);

    final _PersistedNative persisted = await _simulateProcessDeath(a);
    expect(persisted.pending, isNull);
    final _Process b = _newProcessNative(tester, disk, persisted);
    _nativeServiceRestart(b.native);

    // Fail-closed authorization state...
    expect(b.native.authorizedPackages, isEmpty);
    // ...but there is no ticket and no shield. With no a11y replay and no
    // usage event inside the 60 s lookback, the visible app stays usable
    // until the next transition. This is the residual risk recorded in the
    // audit, not a pass condition.
    expect(b.native.pending, isNull);
    expect(b.native.shieldVisible, isFalse);

    // The first foreground report after restart challenges (no trusted
    // prior session).
    b.native.reportForeground(_protected);
    expect(b.native.pending, isNotNull);
    expect(b.native.shieldVisible, isTrue);
    expect(b.native.authorizedPackages, isEmpty);
  });

  testWidgets(
      'SIMULATED (residual-risk characterization): overlay permission lost '
      'across the restart means no shield, no ticket handoff and no '
      'challenge launch', (WidgetTester tester) async {
    final _Disk disk = _Disk();
    final _Process a = await _firstProcess(tester, disk);
    final PendingLockChallenge persistedTicket = await _challengeOnScreen(a);
    final _PersistedNative persisted = await _simulateProcessDeath(a);
    final _Process b = _newProcessNative(tester, disk, persisted);
    b.native.overlayAvailable = false;

    _nativeServiceRestart(b.native);
    expect(b.native.shieldVisible, isFalse);
    expect(b.native.activityPromotions, 0,
        reason: 'recoverProtected launches only after a successful shield');
    // The ticket persists, so authorization still fails closed.
    expect(b.native.pending, persistedTicket);
    expect(b.native.authorizedPackages, isEmpty);
  });
}
