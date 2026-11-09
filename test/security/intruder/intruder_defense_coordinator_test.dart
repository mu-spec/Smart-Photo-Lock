// Phase 12 / M2 — coordinator trigger semantics and the M1 monitor hook.
// SIMULATED: Dart VM, fake camera/alarm platform, in-memory database, real
// AES-GCM cipher and the production credential manager / monitor wiring.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/verified_attempt.dart';
import 'package:smart_app_lock/security/encryption/settings_cipher.dart';
import 'package:smart_app_lock/security/encryption/settings_cipher_impl.dart';
import 'package:smart_app_lock/security/intruder/failed_attempt_event.dart';
import 'package:smart_app_lock/security/intruder/intruder_defense_coordinator.dart';
import 'package:smart_app_lock/security/intruder/intruder_defense_settings.dart';
import 'package:smart_app_lock/security/intruder/intruder_evidence_service.dart';
import 'package:smart_app_lock/services/impl/static_intruder_evidence_service.dart';
import 'package:smart_app_lock/security/intruder/intruder_evidence_store.dart';
import 'package:smart_app_lock/security/intruder/intruder_failure_log_store.dart';
import 'package:smart_app_lock/security/intruder/intruder_monitor.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';

import '../../support/intruder_fixtures.dart';

FailedAttemptEvent ev(
  int seq,
  int run, {
  AuthAttemptSurface surface = AuthAttemptSurface.protectedAppChallenge,
  String? pkg = 'com.bank',
}) =>
    FailedAttemptEvent(
      seq: seq,
      verificationId: 'p:$seq',
      at: DateTime(2026, 10, 22),
      method: FailedAttemptMethod.pin,
      surface: surface,
      consecutiveFailures: run,
      lockoutTriggered: run == 3,
      lockoutStreak: run >= 3 ? 1 : 0,
      counterPersisted: true,
      packageName:
          surface == AuthAttemptSurface.protectedAppChallenge ? pkg : null,
    );

class _Recorder implements IntruderEventListener {
  _Recorder(this.order);
  final List<String> order;
  final List<FailedAttemptEvent> events = <FailedAttemptEvent>[];
  int owner = 0;
  bool throwAll = false;

  @override
  void onFailedAttemptRecorded(FailedAttemptEvent event) {
    order.add('notify:${event.seq}');
    events.add(event);
    if (throwAll) throw StateError('listener bug');
  }

  @override
  void onOwnerVerified() {
    owner++;
    if (throwAll) throw StateError('listener bug');
  }
}

class _OrderDb extends InMemoryLocalDatabase {
  final List<String> order = <String>[];
  bool breakLog = false;
  bool breakLogWrites = false;

  @override
  Future<String?> getSetting(String key) async {
    if (breakLog && key.startsWith(IntruderFailureLogStore.storageKey)) {
      throw StateError('log fault');
    }
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) async {
    if (key.startsWith(IntruderFailureLogStore.storageKey)) {
      if (breakLog || breakLogWrites) throw StateError('log fault');
      order.add('persist');
    }
    return super.setSetting(key, value);
  }
}

void main() {
  late InMemoryLocalDatabase db;
  late SettingsCipher cipher;
  late GatedEvidenceService platform;
  late IntruderDefenseSettingsStore settings;
  late IntruderEvidenceStore evidence;
  late IntruderDefenseCoordinator coordinator;

  setUp(() {
    db = InMemoryLocalDatabase();
    cipher = AesGcmSettingsCipher(InMemorySecretStore());
    platform = GatedEvidenceService()
      ..permission = CameraPermissionState.granted;
    settings = IntruderDefenseSettingsStore(db, cipher);
    evidence = IntruderEvidenceStore(db, cipher);
    coordinator = IntruderDefenseCoordinator(
        settings: settings, evidence: evidence, service: platform);
  });

  Future<void> enable(
          {bool photo = true, bool alarm = false, int threshold = 3}) =>
      settings.write(IntruderDefenseSettings(
          evidenceEnabled: photo, alarmEnabled: alarm, threshold: threshold));

  group('defaults and consent', () {
    test(
        'nothing happens by default — no camera, no alarm, no permission prompt',
        () async {
      for (int i = 1; i <= 10; i++) {
        coordinator.onFailedAttemptRecorded(ev(i, i));
      }
      await coordinator.idle();
      expect(platform.captures, 0);
      expect(platform.alarmStarts, 0);
      expect(platform.permissionRequests, 0);
      expect(await evidence.list(), isEmpty);
      expect(coordinator.status.triggers, 0);
    });

    test('the coordinator NEVER requests the camera permission itself',
        () async {
      platform.permission = CameraPermissionState.denied;
      await enable();
      coordinator.onFailedAttemptRecorded(ev(3, 3));
      await coordinator.idle();
      expect(platform.permissionRequests, 0);
      expect(platform.captures, 0);
      expect(coordinator.status.captureSkipped, 1);
      expect(coordinator.status.lastFailure, 'capture:permission');
    });

    test('corrupt settings fail safe: disabled', () async {
      await db.setSetting(IntruderDefenseSettingsStore.storageKey, 'junk');
      coordinator.onFailedAttemptRecorded(ev(3, 3));
      await coordinator.idle();
      expect(platform.captures + platform.alarmStarts, 0);
    });
  });

  group('trigger semantics', () {
    test('captures exactly once at the threshold, keyed by the event seq',
        () async {
      await enable();
      for (int run = 1; run <= 6; run++) {
        coordinator.onFailedAttemptRecorded(ev(40 + run, run));
      }
      await coordinator.idle();
      expect(platform.captures, 1);
      final EvidenceItem item = (await evidence.list()).single;
      expect(item.seq, 43);
      expect(item.packageName, 'com.bank');
      expect(coordinator.status.captured, 1);
    });

    test('Smart App Lock self-verification failures never trigger', () async {
      await enable(alarm: true, threshold: 1);
      for (int run = 1; run <= 5; run++) {
        coordinator.onFailedAttemptRecorded(
            ev(run, run, surface: AuthAttemptSurface.smartAppLock));
      }
      await coordinator.idle();
      expect(platform.captures + platform.alarmStarts, 0);
    });

    test('the threshold is configurable (1 and 10)', () async {
      await enable(threshold: 1);
      coordinator.onFailedAttemptRecorded(ev(1, 1));
      coordinator.onFailedAttemptRecorded(ev(2, 2));
      await coordinator.idle();
      expect((await evidence.list()).map((EvidenceItem e) => e.seq), <int>[1]);

      await enable(threshold: 10);
      for (int run = 1; run <= 10; run++) {
        coordinator.onFailedAttemptRecorded(ev(100 + run, run));
      }
      await coordinator.idle();
      expect((await evidence.list()).map((EvidenceItem e) => e.seq),
          <int>[1, 110]);
    });

    test('a duplicate notification for the same seq captures once', () async {
      await enable();
      coordinator.onFailedAttemptRecorded(ev(3, 3));
      coordinator.onFailedAttemptRecorded(ev(3, 3));
      await coordinator.idle();
      coordinator.onFailedAttemptRecorded(ev(3, 3));
      await coordinator.idle();
      expect(platform.captures, 1);
    });

    test('a new run after owner success triggers again (new seq)', () async {
      await enable();
      for (final int run in <int>[1, 2, 3]) {
        coordinator.onFailedAttemptRecorded(ev(run, run));
      }
      await coordinator.idle(); // first capture done (single slot)
      coordinator.onOwnerVerified();
      for (final int run in <int>[1, 2, 3]) {
        coordinator.onFailedAttemptRecorded(ev(10 + run, run));
      }
      await coordinator.idle();
      expect(
          (await evidence.list()).map((EvidenceItem e) => e.seq), <int>[3, 13]);
    });

    test('a store that already holds the seq (process restart) is not doubled',
        () async {
      await enable();
      await evidence.save(seq: 3, jpeg: jpegWithMetadata());
      final IntruderDefenseCoordinator restarted = IntruderDefenseCoordinator(
          settings: settings, evidence: evidence, service: platform);
      restarted.onFailedAttemptRecorded(ev(3, 3));
      await restarted.idle();
      expect((await evidence.list()), hasLength(1));
      expect(restarted.status.saveFailed, 1);
      expect(restarted.status.lastFailure, 'save:duplicate');
    });

    test('single capture slot: an overlapping trigger is skipped, not queued',
        () async {
      await enable(threshold: 1);
      platform.gate = Completer<CaptureResult>();
      coordinator.onFailedAttemptRecorded(ev(1, 1));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      coordinator.onFailedAttemptRecorded(ev(5, 1));
      await Future<void>.delayed(Duration.zero);
      platform.gate!.complete(CaptureSucceeded(jpegWithMetadata()));
      await coordinator.idle();
      expect(platform.captures, 1);
      expect(coordinator.status.captureSkipped, 1);
      expect((await evidence.list()).map((EvidenceItem e) => e.seq), <int>[1]);
    });
  });

  group('capture failures are contained', () {
    for (final String reason in <String>[
      'not_foreground',
      'screen_off',
      'camera_busy',
      'timeout',
      'aborted',
      'no_front_camera',
      'permission',
    ]) {
      test('platform failure "$reason" stores nothing', () async {
        await enable();
        platform.onCapture = () => CaptureFailed(reason);
        coordinator.onFailedAttemptRecorded(ev(3, 3));
        await coordinator.idle();
        expect(await evidence.list(), isEmpty);
        expect(coordinator.status.captureFailed, 1);
        expect(coordinator.status.lastFailure, 'capture:$reason');
      });
    }

    test('a non-JPEG from the platform is rejected', () async {
      await enable();
      platform.onCapture =
          () => CaptureSucceeded(jpegWithMetadata().sublist(0, 10));
      coordinator.onFailedAttemptRecorded(ev(3, 3));
      await coordinator.idle();
      expect(await evidence.list(), isEmpty);
      expect(coordinator.status.lastFailure, 'save:invalidImage');
    });

    test('a throwing platform never escapes the coordinator', () async {
      final ThrowingEvidenceService broken = ThrowingEvidenceService();
      final IntruderDefenseCoordinator c = IntruderDefenseCoordinator(
          settings: settings, evidence: evidence, service: broken);
      await enable(alarm: true);
      c.onFailedAttemptRecorded(ev(3, 3));
      await c.idle();
      c.onOwnerVerified();
      await c.idle();
      expect(broken.calls, greaterThanOrEqualTo(2));
      expect(c.status.errors, greaterThanOrEqualTo(2));
    });
  });

  group('alarm', () {
    test('starts once at the threshold and stops on owner success', () async {
      await enable(photo: false, alarm: true);
      for (int run = 1; run <= 5; run++) {
        coordinator.onFailedAttemptRecorded(ev(run, run));
      }
      await coordinator.idle();
      expect(platform.alarmStarts, 1);
      expect(platform.alarmPlaying, isTrue);
      expect(platform.captures, 0, reason: 'photo not enabled');
      coordinator.onOwnerVerified();
      await coordinator.idle();
      expect(platform.alarmPlaying, isFalse);
      expect(platform.alarmStops, 1);
      coordinator.onOwnerVerified();
      await coordinator.idle();
      expect(platform.alarmStops, 1, reason: 'idempotent; no stray calls');
    });

    test('owner success without an alarm makes no platform call', () async {
      coordinator.onOwnerVerified();
      await coordinator.idle();
      expect(platform.alarmStops, 0);
    });

    for (final AlarmStartResult r in <AlarmStartResult>[
      AlarmStartResult.suppressedByDnd,
      AlarmStartResult.suppressedByRinger,
      AlarmStartResult.focusDenied,
      AlarmStartResult.notForeground,
    ]) {
      test('suppression (${r.name}) is respected and recorded', () async {
        await enable(photo: false, alarm: true);
        platform.alarmResult = r;
        coordinator.onFailedAttemptRecorded(ev(3, 3));
        await coordinator.idle();
        expect(coordinator.status.alarmsStarted, 0);
        expect(coordinator.status.alarmsSuppressed, 1);
        expect(coordinator.status.lastFailure, 'alarm:${r.name}');
      });
    }

    test('alarm and photo both run for one trigger; duration is 30 s',
        () async {
      Duration? asked;
      final _DurationSpy spy = _DurationSpy((Duration d) => asked = d)
        ..permission = CameraPermissionState.granted
        ..onCapture = () => CaptureSucceeded(jpegWithMetadata());
      final IntruderDefenseCoordinator c = IntruderDefenseCoordinator(
          settings: settings, evidence: evidence, service: spy);
      await enable(alarm: true);
      c.onFailedAttemptRecorded(ev(3, 3));
      await c.idle();
      expect(asked, const Duration(seconds: 30));
      expect(spy.captures, 1);
      expect(c.status.alarmsStarted, 1);
    });
  });

  group('M1 monitor hook (production container wiring)', () {
    test('the listener hears an event only AFTER it was persisted', () async {
      final _OrderDb odb = _OrderDb();
      final AppContainer c = AppContainer.inMemory(database: odb);
      final _Recorder rec = _Recorder(odb.order);
      c.intruderMonitor.listener = rec;
      await c.auth.enrollPin('1234');
      await c.auth.authenticatePin('0000');
      await c.intruderMonitor.idle();
      expect(odb.order, <String>['persist', 'notify:0']);
      expect(rec.events.single.surface, AuthAttemptSurface.smartAppLock);
    });

    test('a dropped (unpersisted) event is never reported', () async {
      final _OrderDb odb = _OrderDb()..breakLog = true;
      final AppContainer c = AppContainer.inMemory(database: odb);
      final _Recorder rec = _Recorder(odb.order);
      c.intruderMonitor.listener = rec;
      await c.auth.enrollPin('1234');
      final AuthAttemptResult? r =
          (await c.auth.authenticatePin('0000')).valueOrNull;
      await c.intruderMonitor.idle();
      expect(r, isA<AuthFailure>());
      expect(rec.events, isEmpty);
    });

    test('a built event whose WRITE failed (saved == false) is never reported',
        () async {
      final _OrderDb odb = _OrderDb();
      final AppContainer c = AppContainer.inMemory(database: odb);
      final _Recorder rec = _Recorder(odb.order);
      c.intruderMonitor.listener = rec;
      await c.auth.enrollPin('1234');
      await c.auth.authenticatePin('0000'); // persisted + reported
      await c.intruderMonitor.idle();
      odb.breakLogWrites = true; // log readable, writes fail
      final AuthAttemptResult? r =
          (await c.auth.authenticatePin('1111')).valueOrNull;
      await c.intruderMonitor.idle();
      expect(r, isA<AuthFailure>(), reason: 'verdict unaffected');
      expect(rec.events.map((FailedAttemptEvent e) => e.seq), <int>[0]);
      expect(odb.order, <String>['persist', 'notify:0']);
    });

    test('owner success is reported; a wrong credential is not', () async {
      final AppContainer c = AppContainer.inMemory();
      final _Recorder rec = _Recorder(<String>[]);
      c.intruderMonitor.listener = rec;
      await c.auth.enrollPin('1234');
      await c.auth.authenticatePin('0000');
      expect(rec.owner, 0);
      await c.auth.authenticatePin('1234');
      expect(rec.owner, 1, reason: 'synchronous with the verdict');
    });

    test('a throwing listener changes neither verdicts nor the M1 log',
        () async {
      final AppContainer c = AppContainer.inMemory();
      final _Recorder rec = _Recorder(<String>[])..throwAll = true;
      c.intruderMonitor.listener = rec;
      await c.auth.enrollPin('1234');
      expect((await c.auth.authenticatePin('0000')).valueOrNull,
          isA<AuthFailure>());
      expect((await c.auth.authenticatePin('1234')).valueOrNull,
          isA<AuthSuccess>());
      expect((await c.auth.authenticatePin('1111')).valueOrNull,
          isA<AuthFailure>());
      await c.intruderMonitor.idle();
      final IntruderFailureLog log = (await c.intruderMonitor.snapshot())!;
      expect(log.events.map((FailedAttemptEvent e) => e.seq), <int>[0, 1]);
      expect(log.consecutiveFailures, 1);
    });

    test('in-app failures with every option on never use the camera or alarm',
        () async {
      final StaticIntruderEvidenceService fake = StaticIntruderEvidenceService()
        ..permission = CameraPermissionState.granted;
      final AppContainer c = AppContainer.inMemory(intruderEvidence: fake);
      await c.intruderDefenseSettings.write(const IntruderDefenseSettings(
          evidenceEnabled: true, alarmEnabled: true, threshold: 1));
      await c.auth.enrollPin('1234');
      for (final String p in <String>['0000', '1111', '2222']) {
        await c.auth.authenticatePin(p);
      }
      await c.intruderMonitor.idle();
      await c.intruderDefense.idle();
      expect(fake.captures + fake.alarmStarts + fake.permissionRequests, 0);
    });
  });
}

class _DurationSpy extends StaticIntruderEvidenceService {
  _DurationSpy(this.onDuration);
  final void Function(Duration) onDuration;

  @override
  Future<AlarmStartResult> startAlarm({required Duration duration}) {
    onDuration(duration);
    return super.startAlarm(duration: duration);
  }
}
