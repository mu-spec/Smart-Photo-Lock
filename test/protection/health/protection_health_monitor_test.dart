// Phase 7 / M1 — Protection Health monitor.
//
// PRODUCTION Dart code (ProtectionHealthMonitor, ProtectionHealthEngine,
// ProtectionEngineHealth.fromMap, MethodChannelWatcherService.getHealth)
// running over SIMULATED platform services (the in-memory container's
// static services and a mocked method channel). Nothing here observes a
// real Android device.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/protection/health/protection_health_engine.dart';
import 'package:smart_app_lock/protection/health/protection_health_monitor.dart';
import 'package:smart_app_lock/security/credentials/biometric_options.dart';
import 'package:smart_app_lock/services/biometric_service.dart';
import 'package:smart_app_lock/services/impl/method_channel_watcher_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/overlay_lock_service.dart';
import 'package:smart_app_lock/services/watcher_service.dart';
import 'package:smart_app_lock/utilities/result.dart';

class _Biometrics implements BiometricService {
  bool hardware = true;
  bool enrolled = true;
  int authenticateCalls = 0;
  int probeCalls = 0;

  @override
  Future<Result<bool>> isSupported() async {
    probeCalls++;
    return Result.success(hardware);
  }

  @override
  Future<Result<Set<BiometricKind>>> availableKinds() async {
    probeCalls++;
    return Result.success(<BiometricKind>{if (enrolled) BiometricKind.strong});
  }

  @override
  Future<Result<bool>> authenticate({
    required String reason,
    BiometricOptions? options,
  }) async {
    authenticateCalls++;
    return Result.success(false);
  }
}

/// An overlay bridge whose capability probe fails (platform exception).
class _FailingOverlay extends StaticOverlayLockService {
  _FailingOverlay() : super(overlayGranted: true);

  @override
  Future<Result<bool>> canDrawOverlays() async =>
      Result.failure(StateError('probe failed'));
}

/// A watcher whose getHealth never answers (hung platform channel).
class _HungWatcher extends StaticWatcherService {
  @override
  Future<Result<ProtectionEngineHealth>> getHealth() =>
      Completer<Result<ProtectionEngineHealth>>().future;
}

class _Rig {
  _Rig._(this.container, this.biometrics, this.clock);

  final AppContainer container;
  final _Biometrics biometrics;
  final List<DateTime> clock;

  StaticWatcherService get watcher => container.watcher as StaticWatcherService;
  StaticOverlayLockService get overlay =>
      container.overlay as StaticOverlayLockService;

  ProtectionHealthMonitor monitor({
    WatcherService? watcher,
    OverlayLockService? overlay,
    Duration probeTimeout = const Duration(seconds: 3),
  }) =>
      ProtectionHealthMonitor(
        protectedApps: container.protectedApps,
        credentials: container.auth,
        installedApps: container.installedAppsService,
        accessibility: container.accessibility,
        overlay: overlay ?? container.overlay,
        watcher: watcher ?? container.watcher,
        preferences: container.preferences,
        biometrics: biometrics,
        now: () => clock.single,
        probeTimeout: probeTimeout,
      );

  /// A fully configured, healthy simulated device.
  static Future<_Rig> configured({bool protect = true}) async {
    final _Biometrics biometrics = _Biometrics();
    final AppContainer container = AppContainer.inMemory(
      biometrics: biometrics,
      accessibilityEnabled: true,
      overlayGranted: true,
    );
    final _Rig rig = _Rig._(container, biometrics, <DateTime>[
      DateTime(2026, 11, 1, 10),
    ]);
    await container.auth.enrollPin('2468');
    if (protect) {
      await container.protectedApps.add(
        ProtectedApp(
          packageName: 'com.example.private',
          label: 'Private',
          addedAt: DateTime(2026, 11, 1),
        ),
      );
    }
    final StaticWatcherService w = rig.watcher
      ..protectionConfigured = protect
      ..running = true
      ..accessibilityServiceConnected = true
      ..shieldArmed = true
      ..challengePending = false
      ..backgroundRestricted = false
      ..powerSaveMode = false
      ..ignoringBatteryOptimizations = false
      ..sdkInt = 34;
    expect(w.running, isTrue);
    return rig;
  }

  void advance(Duration d) => clock[0] = clock.single.add(d);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('healthy simulated device reports SECURE', () async {
    final _Rig rig = await _Rig.configured();
    final ProtectionHealthReport r = await rig.monitor().refresh();
    expect(r.state, ProtectionHealthState.secure, reason: '${r.issues}');
    expect(r.signals.protectionConfigured, isTrue);
  });

  test('refresh is observational: no lifecycle, auth, ticket or grant writes',
      () async {
    final _Rig rig = await _Rig.configured();
    rig.watcher
      ..running = false
      ..pendingChallenge = 'com.example.private';
    final StaticWatcherService w = rig.watcher;
    final int configure = w.configureCalls;
    await rig.monitor().refresh();
    expect(w.startCalls, 0, reason: 'never restarts the watcher');
    expect(w.stopCalls, 0);
    expect(w.configureCalls, configure);
    expect(w.heartbeatCalls, 0);
    expect(w.authorizePackageCalls, 0);
    expect(w.revokeAllAuthorizationsCalls, 0);
    expect(w.pendingChallenge, 'com.example.private', reason: 'ticket kept');
    expect(rig.overlay.showLockChallengeCalls, 0);
    expect(rig.overlay.hideLockChallengeCalls, 0);
    expect(rig.biometrics.authenticateCalls, 0, reason: 'never prompts');
    // Grant history is read, never recorded, by health.
    expect(
      await rig.container.preferences.wasCapabilityEverGranted('overlay'),
      isFalse,
    );
  });

  test('no protected app is the user choice; no credential is setup', () async {
    final _Rig rig = await _Rig.configured(protect: false);
    final ProtectionHealthReport r = await rig.monitor().refresh();
    expect(r.state, ProtectionHealthState.protectionOffline);
    expect(r.issues.single.code, HealthIssueCode.protectionNotConfigured);
    expect(r.issues.single.cause, HealthCause.noProtectedApps);
    final AppContainer empty = AppContainer.inMemory();
    final ProtectionHealthReport fresh = await ProtectionHealthMonitor(
      protectedApps: empty.protectedApps,
      credentials: empty.auth,
      installedApps: empty.installedAppsService,
      accessibility: empty.accessibility,
      overlay: empty.overlay,
      watcher: empty.watcher,
      preferences: empty.preferences,
      biometrics: rig.biometrics,
    ).refresh();
    expect(fresh.issues.single.cause, HealthCause.setupIncomplete);
    expect(fresh.issues.single.category.isSystemFailure, isFalse);
  });

  test('saved Dart configuration with native enforcement disabled → OFFLINE',
      () async {
    final _Rig rig = await _Rig.configured();
    rig.watcher.protectionConfigured = false; // e.g. before the first sync
    final ProtectionHealthReport r = await rig.monitor().refresh();
    expect(r.signals.protectionConfigured, isTrue);
    expect(r.state, ProtectionHealthState.protectionOffline);
    expect(r.issues.single.code, HealthIssueCode.enforcementNotArmed);
  });

  test('watcher interruption → ATTENTION with reason; restart → SECURE',
      () async {
    final _Rig rig = await _Rig.configured();
    final ProtectionHealthMonitor m = rig.monitor();
    final List<ProtectionHealthState> events = <ProtectionHealthState>[];
    final StreamSubscription<ProtectionHealthReport> sub = m.changes.listen(
      (ProtectionHealthReport r) => events.add(r.state),
    );
    await m.refresh();
    rig.watcher
      ..running = false
      ..lastError = 'Android stopped the protection service.';
    final ProtectionHealthReport down = await m.refresh();
    expect(down.state, ProtectionHealthState.attentionRequired);
    expect(down.issues.single.code, HealthIssueCode.watcherNotRunning);
    expect(down.issues.single.detail['lastError'],
        'Android stopped the protection service.');
    rig.watcher
      ..running = true
      ..lastError = null;
    expect((await m.refresh()).state, ProtectionHealthState.secure);
    await m.refresh(); // identical → no duplicate change event
    await Future<void>.delayed(Duration.zero);
    expect(events, <ProtectionHealthState>[
      ProtectionHealthState.secure,
      ProtectionHealthState.attentionRequired,
      ProtectionHealthState.secure,
    ]);
    await sub.cancel();
    await m.dispose();
  });

  test('capability revoked (per grant history) → OFFLINE; regrant → SECURE',
      () async {
    final _Rig rig = await _Rig.configured();
    await rig.container.preferences.markCapabilityEverGranted('overlay');
    final ProtectionHealthMonitor m = rig.monitor();
    rig.overlay.overlayGranted = false;
    final ProtectionHealthReport lost = await m.refresh();
    expect(lost.state, ProtectionHealthState.protectionOffline);
    expect(lost.issues.first.code, HealthIssueCode.overlayUnavailable);
    expect(lost.issues.first.cause, HealthCause.revoked);
    rig.overlay.overlayGranted = true;
    expect((await m.refresh()).state, ProtectionHealthState.secure);
  });

  test('Accessibility enabled but unbound (OEM kill) is not operational',
      () async {
    final _Rig rig = await _Rig.configured();
    rig.watcher.accessibilityServiceConnected = false;
    final ProtectionHealthReport r = await rig.monitor().refresh();
    expect(r.state, ProtectionHealthState.attentionRequired);
    expect(r.issues.single.code, HealthIssueCode.accessibilityNotRunning);
  });

  test('native health bridge failure → UNKNOWN, never SECURE', () async {
    final _Rig rig = await _Rig.configured();
    rig.watcher.getHealthError = StateError('channel down');
    final ProtectionHealthReport r = await rig.monitor().refresh();
    expect(r.state, ProtectionHealthState.attentionRequired);
    expect(r.signals.nativeHealthAvailable, isFalse);
    expect(r.issues.single.code, HealthIssueCode.signalUnknown);
  });

  test('a failed capability probe is UNKNOWN, never a fabricated grant',
      () async {
    final _Rig rig = await _Rig.configured();
    final ProtectionHealthReport r =
        await rig.monitor(overlay: _FailingOverlay()).refresh();
    expect(r.signals.overlayGranted, isNull);
    expect(r.components[HealthComponent.overlay], ComponentStatus.unknown);
    expect(r.state, ProtectionHealthState.attentionRequired);
    expect(r.issues.single.code, HealthIssueCode.signalUnknown);
  });

  test('a hung probe times out to UNKNOWN instead of blocking or passing',
      () async {
    final _Rig rig = await _Rig.configured();
    final ProtectionHealthReport r = await rig
        .monitor(
          watcher: _HungWatcher(),
          probeTimeout: const Duration(milliseconds: 20),
        )
        .refresh();
    expect(r.signals.nativeHealthAvailable, isFalse);
    expect(r.state, isNot(ProtectionHealthState.secure));
  });

  test('concurrent refreshes share one collection', () async {
    final _Rig rig = await _Rig.configured();
    final ProtectionHealthMonitor m = rig.monitor();
    final List<ProtectionHealthReport> both =
        await Future.wait(<Future<ProtectionHealthReport>>[
      m.refresh(),
      m.refresh(),
    ]);
    expect(identical(both[0], both[1]), isTrue);
    expect(rig.watcher.getHealthCalls, 1);
  });

  test('latest() goes stale after maxAge without any new probe', () async {
    final _Rig rig = await _Rig.configured();
    final ProtectionHealthMonitor m = rig.monitor();
    expect(m.latest(), isNull);
    await m.refresh();
    final int calls = rig.watcher.getHealthCalls;
    expect(m.latest()!.state, ProtectionHealthState.secure);
    rig.advance(m.maxAge + const Duration(seconds: 1));
    final ProtectionHealthReport old = m.latest()!;
    expect(old.state, ProtectionHealthState.attentionRequired);
    expect(old.hasIssue(HealthIssueCode.healthSnapshotStale), isTrue);
    expect(rig.watcher.getHealthCalls, calls, reason: 'latest() never probes');
    expect((await m.refresh()).state, ProtectionHealthState.secure);
  });

  test('background restriction and Battery Saver are surfaced', () async {
    final _Rig rig = await _Rig.configured();
    rig.watcher
      ..backgroundRestricted = true
      ..powerSaveMode = true;
    final ProtectionHealthReport r = await rig.monitor().refresh();
    expect(r.state, ProtectionHealthState.attentionRequired);
    expect(
      r.issues.map((HealthIssue i) => i.code).toList(),
      <HealthIssueCode>[
        HealthIssueCode.backgroundRestricted,
        HealthIssueCode.batterySaverOn,
      ],
    );
  });

  test('biometric enrollment removal is a change event, not a state change',
      () async {
    final _Rig rig = await _Rig.configured();
    expect(
      (await rig.container.auth.updateBiometricOptions(
        BiometricOptions.defaults,
      ))
          .isSuccess,
      isTrue,
    );
    final ProtectionHealthMonitor m = rig.monitor();
    final List<ProtectionHealthReport> events = <ProtectionHealthReport>[];
    final StreamSubscription<ProtectionHealthReport> sub =
        m.changes.listen(events.add);
    final ProtectionHealthReport before = await m.refresh();
    expect(before.components[HealthComponent.biometric],
        ComponentStatus.operational);
    rig.biometrics.enrolled = false;
    final ProtectionHealthReport after = await m.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(after.state, ProtectionHealthState.secure);
    expect(after.issues.single.code, HealthIssueCode.biometricUnavailable);
    expect(events.length, 2, reason: 'the configuration change is emitted');
    await sub.cancel();
  });

  test('biometric probes run only when biometric unlock is enabled (M2)',
      () async {
    final _Rig rig = await _Rig.configured();
    final ProtectionHealthMonitor m = rig.monitor();
    final ProtectionHealthReport off = await m.refresh();
    expect(rig.biometrics.probeCalls, 0, reason: 'disabled in app: no probe');
    expect(off.components[HealthComponent.biometric],
        ComponentStatus.disabledByUser);
    expect(off.state, ProtectionHealthState.secure);
    expect(
      (await rig.container.auth.updateBiometricOptions(
        BiometricOptions.defaults,
      ))
          .isSuccess,
      isTrue,
    );
    rig.biometrics.enrolled = false;
    final ProtectionHealthReport on = await m.refresh();
    expect(rig.biometrics.probeCalls, 2, reason: 'enabled: hardware + kinds');
    expect(on.issues.single.code, HealthIssueCode.biometricUnavailable);
  });

  group('native health wire format', () {
    test('absent or malformed M1 keys parse as UNKNOWN (older native build)',
        () {
      final ProtectionEngineHealth legacy =
          ProtectionEngineHealth.fromMap(<String, Object?>{
        'protectionConfigured': true,
        'serviceRunning': true,
        'engineState': 'healthy',
        'notificationPermissionGranted': true,
        'shieldArmed': 'yes',
      });
      expect(legacy.accessibilityServiceConnected, isNull);
      expect(legacy.shieldArmed, isNull);
      expect(legacy.backgroundRestricted, isNull);
      expect(legacy.sdkInt, isNull);
    });

    test('method channel getHealth carries the M1 signals', () async {
      const MethodChannel channel = MethodChannel('test/watcher_health');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        expect(call.method, 'getHealth');
        return <String, Object?>{
          'protectionConfigured': true,
          'serviceRunning': true,
          'engineState': 'recovering',
          'notificationPermissionGranted': false,
          'lastError': null,
          'accessibilityServiceConnected': false,
          'shieldArmed': true,
          'challengePending': true,
          'backgroundRestricted': true,
          'powerSaveMode': false,
          'ignoringBatteryOptimizations': null,
          'sdkInt': 28,
        };
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final ProtectionEngineHealth h =
          (await MethodChannelWatcherService(channel: channel).getHealth())
              .valueOrNull!;
      expect(h.accessibilityServiceConnected, isFalse);
      expect(h.shieldArmed, isTrue);
      expect(h.challengePending, isTrue);
      expect(h.backgroundRestricted, isTrue);
      expect(h.powerSaveMode, isFalse);
      expect(h.ignoringBatteryOptimizations, isNull);
      expect(h.sdkInt, 28);
    });
  });

  test('container exposes the shared monitor without probing on creation',
      () async {
    final AppContainer c = AppContainer.inMemory();
    final StaticWatcherService w = c.watcher as StaticWatcherService;
    expect(c.protectionHealth, isA<ProtectionHealthMonitor>());
    expect(c.protectionHealth.latest(), isNull);
    expect(w.getHealthCalls, 0);
  });

  group('after-change refresh (Phase 7 / M3)', () {
    Future<void> untilBlocked(StaticWatcherService w, int calls) async {
      for (int i = 0; i < 200 && w.getHealthCalls < calls; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(w.getHealthCalls, calls, reason: 'collection reached the gate');
    }

    test(
        'a change made while a collection runs is observed by an '
        'after-change request; later requests join the newer collection',
        () async {
      final _Rig rig = await _Rig.configured();
      final ProtectionHealthMonitor m = rig.monitor();
      rig.watcher.getHealthGate = Completer<void>();

      final Future<ProtectionHealthReport> before = m.refresh();
      await untilBlocked(rig.watcher, 1); // overlay already read as granted
      rig.overlay.overlayGranted = false; // revoked in Android Settings

      final Future<ProtectionHealthReport> afterChange =
          m.refresh(afterChange: true);
      final Future<ProtectionHealthReport> plainLater = m.refresh();
      final Future<ProtectionHealthReport> afterChangeLater =
          m.refresh(afterChange: true);
      expect(identical(plainLater, afterChange), isTrue,
          reason: 'a later plain request never receives older data');
      expect(identical(afterChangeLater, afterChange), isTrue,
          reason: 'bounded: one queued follow-up shared by every request');
      expect(identical(m.refresh(), before), isFalse);

      rig.watcher.getHealthGate!.complete();
      final ProtectionHealthReport first = await before;
      final ProtectionHealthReport second = await afterChange;

      expect(first.state, ProtectionHealthState.secure);
      expect(second.state, ProtectionHealthState.protectionOffline);
      expect(second.issues.first.code, HealthIssueCode.overlayUnavailable);
      expect(rig.watcher.getHealthCalls, 2, reason: 'exactly two collections');
      expect(m.latest()!.state, ProtectionHealthState.protectionOffline,
          reason: 'the newest observation is the one kept');
    });

    test(
        'an after-change request with nothing running starts one collection; '
        'plain requests join it, a second after-change request queues one',
        () async {
      final _Rig rig = await _Rig.configured();
      final ProtectionHealthMonitor m = rig.monitor();
      final Future<ProtectionHealthReport> a = m.refresh(afterChange: true);
      final Future<ProtectionHealthReport> plain = m.refresh();
      expect(identical(a, plain), isTrue);
      expect((await a).state, ProtectionHealthState.secure);
      expect(rig.watcher.getHealthCalls, 1);

      final Future<ProtectionHealthReport> b = m.refresh(afterChange: true);
      final Future<ProtectionHealthReport> c = m.refresh(afterChange: true);
      final Future<ProtectionHealthReport> d = m.refresh(afterChange: true);
      expect(identical(b, c), isFalse);
      expect(identical(c, d), isTrue, reason: 'never more than one queued');
      await d;
      expect(rig.watcher.getHealthCalls, 3);
      await m.refresh();
      expect(rig.watcher.getHealthCalls, 4, reason: 'nothing left running');
    });

    test('a queued collection still runs when the running one hits timeouts',
        () async {
      final _Rig rig = await _Rig.configured();
      final ProtectionHealthMonitor m =
          rig.monitor(probeTimeout: const Duration(milliseconds: 20));
      rig.watcher.getHealthGate = Completer<void>(); // hung bridge
      final Future<ProtectionHealthReport> hung = m.refresh();
      await untilBlocked(rig.watcher, 1);
      final Future<ProtectionHealthReport> queued =
          m.refresh(afterChange: true);

      final ProtectionHealthReport first = await hung;
      expect(first.state, isNot(ProtectionHealthState.secure));
      expect(first.issues.map((HealthIssue i) => i.code),
          contains(HealthIssueCode.signalUnknown));

      rig.watcher.getHealthGate!.complete(); // bridge answers again
      final ProtectionHealthReport second = await queued;
      expect(second.state, ProtectionHealthState.secure);
      expect(rig.watcher.getHealthCalls, 2);
    });
  });
}
