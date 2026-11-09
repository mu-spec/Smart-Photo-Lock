// Phase 12 / Milestone 2 — FINAL SECURITY GATE (Gates B, C, D).
//
// Gate B: owner success while a capture / alarm start is pending.
// Gate C: consent revocation while a capture / alarm start is pending.
// Gate D: storage commit point + enforcement unchanged (cooldown, shield).
//
// SIMULATED: Dart VM / Flutter widget tests with the production coordinator,
// evidence store (real AES-GCM), M1 monitor, credential manager, lock
// challenge host and Security screen. The camera and audio are a gated fake
// IntruderEvidenceService whose abortCapture() does NOT complete the pending
// capture, so each test chooses the LATE callback (success / failure /
// timeout) that arrives after cancellation. NO device camera, Camera2,
// ToneGenerator or permission dialog is exercised here.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/router.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/credential_state.dart';
import 'package:smart_app_lock/security/credentials/verified_attempt.dart';
import 'package:smart_app_lock/security/encryption/settings_cipher.dart';
import 'package:smart_app_lock/security/encryption/settings_cipher_impl.dart';
import 'package:smart_app_lock/security/intruder/failed_attempt_event.dart';
import 'package:smart_app_lock/security/intruder/intruder_defense_coordinator.dart';
import 'package:smart_app_lock/security/intruder/intruder_defense_settings.dart';
import 'package:smart_app_lock/security/intruder/intruder_evidence_service.dart';
import 'package:smart_app_lock/security/intruder/intruder_evidence_store.dart';
import 'package:smart_app_lock/security/intruder/intruder_failure_log_store.dart';
import 'package:smart_app_lock/security/intruder/intruder_monitor.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/security/security_screen.dart';

import '../support/intruder_fixtures.dart';

const String _app = 'com.bank.app';
const String _pin = '482916';

FailedAttemptEvent ev(int seq, int run) => FailedAttemptEvent(
      seq: seq,
      verificationId: 'p:$seq',
      at: DateTime(2026, 10, 22),
      method: FailedAttemptMethod.pin,
      surface: AuthAttemptSurface.protectedAppChallenge,
      consecutiveFailures: run,
      lockoutTriggered: run == 3,
      lockoutStreak: run >= 3 ? 1 : 0,
      counterPersisted: true,
      packageName: 'com.bank',
    );

/// Database with test hooks: a callback on reads of one key, an injectable
/// read fault, and a gate that holds writes of the M1 failure log.
class _HookDb extends InMemoryLocalDatabase {
  final Map<String, void Function()> onRead = <String, void Function()>{};
  final Set<String> unreadable = <String>{};
  Completer<void>? logWriteGate;

  @override
  Future<String?> getSetting(String key) async {
    onRead[key]?.call();
    if (unreadable.contains(key)) throw StateError('read fault');
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) async {
    final Completer<void>? g = logWriteGate;
    if (g != null && key.startsWith(IntruderFailureLogStore.storageKey)) {
      await g.future;
    }
    return super.setSetting(key, value);
  }
}

/// Fake whose permission query runs a hook (owner success lands there).
class _PermissionHookService extends GatedEvidenceService {
  _PermissionHookService(this.hook);
  final void Function() hook;

  @override
  Future<CameraPermissionState> cameraPermission() async {
    hook();
    return super.cameraPermission();
  }
}

class _Recorder implements IntruderEventListener {
  final List<FailedAttemptEvent> events = <FailedAttemptEvent>[];
  int owner = 0;

  @override
  void onFailedAttemptRecorded(FailedAttemptEvent event) => events.add(event);

  @override
  void onOwnerVerified() => owner++;
}

void main() {
  late _HookDb db;
  late SettingsCipher cipher;
  late GatedEvidenceService platform;
  late IntruderDefenseSettingsStore settings;
  late IntruderEvidenceStore evidence;
  late IntruderDefenseCoordinator coordinator;

  IntruderDefenseCoordinator build({Duration? captureTimeout}) =>
      IntruderDefenseCoordinator(
        settings: settings,
        evidence: evidence,
        service: platform,
        captureTimeout:
            captureTimeout ?? IntruderDefenseCoordinator.defaultCaptureTimeout,
      );

  setUp(() {
    db = _HookDb();
    cipher = AesGcmSettingsCipher(InMemorySecretStore());
    platform = GatedEvidenceService()
      ..permission = CameraPermissionState.granted;
    settings = IntruderDefenseSettingsStore(db, cipher);
    evidence = IntruderEvidenceStore(db, cipher);
    coordinator = build();
  });

  Future<void> enable({bool photo = true, bool alarm = false}) =>
      settings.write(
          IntruderDefenseSettings(evidenceEnabled: photo, alarmEnabled: alarm));

  /// Lets the trigger reach the (gated) platform call.
  Future<void> drain() async {
    for (int i = 0; i < 50; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Starts a capture for event (3, run 3) and holds it at the platform.
  Future<Completer<CaptureResult>> pendingCapture({int seq = 3}) async {
    final Completer<CaptureResult> gate = Completer<CaptureResult>();
    platform.gate = gate;
    coordinator.onFailedAttemptRecorded(ev(seq, 3));
    await drain();
    expect(platform.captures, greaterThan(0), reason: 'capture is pending');
    expect(gate.isCompleted, isFalse);
    return gate;
  }

  // ===========================================================================
  group('Gate B — owner success during a pending capture / alarm', () {
    test('B1 late SUCCESS after owner success: aborted, never persisted',
        () async {
      await enable(alarm: true);
      final Completer<CaptureResult> gate = await pendingCapture();
      expect(platform.alarmPlaying, isTrue);

      coordinator.onOwnerVerified();
      await drain();
      expect(platform.captureAborts, 1, reason: 'native capture aborted');
      expect(platform.alarmPlaying, isFalse, reason: 'alarm stopped');

      gate.complete(CaptureSucceeded(jpegWithMetadata())); // LATE result
      await coordinator.idle();
      expect(await evidence.list(), isEmpty);
      expect(
          await db.getSetting('${IntruderEvidenceStore.blobPrefix}3'), isNull,
          reason: 'no blob written either');
      expect(coordinator.status.captureCancelled, 1);
      expect(coordinator.status.captured, 0);
    });

    test('B2 late FAILURE after owner success: cancelled, not a failure',
        () async {
      await enable();
      final Completer<CaptureResult> gate = await pendingCapture();
      coordinator.onOwnerVerified();
      gate.complete(const CaptureFailed('cancelled'));
      await coordinator.idle();
      expect(await evidence.list(), isEmpty);
      expect(coordinator.status.captureCancelled, 1);
      expect(coordinator.status.captureFailed, 0);
      expect(platform.captureAborts, 1);
    });

    test(
        'B3 TIMEOUT after owner success: cancelled; an even later success '
        'is ignored', () async {
      coordinator = build(captureTimeout: const Duration(milliseconds: 40));
      await enable();
      final Completer<CaptureResult> gate = await pendingCapture();
      coordinator.onOwnerVerified();
      await coordinator.idle(); // the 40 ms Dart timeout fires
      expect(coordinator.status.captureCancelled, 1);
      expect(coordinator.status.captureFailed, 0);

      gate.complete(CaptureSucceeded(jpegWithMetadata()));
      await drain();
      await coordinator.idle();
      expect(await evidence.list(), isEmpty);
      expect(coordinator.status.captured, 0);
    });

    test(
        'B3b TIMEOUT without owner success: failure + native abort, and a '
        'later success is ignored', () async {
      coordinator = build(captureTimeout: const Duration(milliseconds: 40));
      await enable();
      final Completer<CaptureResult> gate = await pendingCapture();
      await coordinator.idle();
      expect(coordinator.status.captureFailed, 1);
      expect(coordinator.status.lastFailure, 'capture:timeout');
      expect(platform.captureAborts, 1, reason: 'timeout aborts natively');
      gate.complete(CaptureSucceeded(jpegWithMetadata()));
      await drain();
      expect(await evidence.list(), isEmpty);
    });

    for (final bool pessimistic in <bool>[false, true]) {
      test(
          'B4 owner success during a PENDING alarm start '
          '(${pessimistic ? 'tone starts on reply' : 'native order'}): '
          'the alarm ends silent', () async {
        platform.startTakesEffectOnReply = pessimistic;
        await enable(photo: false, alarm: true);
        final Completer<AlarmStartResult> alarm = Completer<AlarmStartResult>();
        platform.alarmGate = alarm;
        coordinator.onFailedAttemptRecorded(ev(3, 3));
        await drain();
        expect(platform.ops, <String>['alarmStart']);

        coordinator.onOwnerVerified();
        await drain();
        expect(platform.ops.last, 'alarmStop', reason: 'pre-empted at once');

        alarm.complete(AlarmStartResult.started); // late reply
        await coordinator.idle();
        expect(platform.alarmPlaying, isFalse);
        expect(platform.ops.last, 'alarmStop');
        expect(coordinator.status.alarmsCancelled, 1);
        expect(coordinator.status.alarmsStarted, 0);
      });
    }

    test(
        'B5 owner success arriving INSIDE the store write (commit point): '
        'nothing persisted', () async {
      await enable();
      // The store reads its index inside the serialized save, just before
      // the stillValid check; owner success lands exactly there.
      db.onRead[IntruderEvidenceStore.indexKey] = coordinator.onOwnerVerified;
      platform.gate = null; // capture returns immediately
      coordinator.onFailedAttemptRecorded(ev(3, 3));
      await coordinator.idle();
      db.onRead.clear();
      expect(await evidence.list(), isEmpty);
      expect(
          await db.getSetting('${IntruderEvidenceStore.blobPrefix}3'), isNull);
      expect(coordinator.status.captureCancelled, 1);
      expect(coordinator.status.captured, 0);
    });

    test('B6 owner success during the settings re-check: nothing persisted',
        () async {
      await enable();
      int reads = 0;
      db.onRead[IntruderDefenseSettingsStore.storageKey] = () {
        if (++reads == 2) coordinator.onOwnerVerified(); // the re-check
      };
      coordinator.onFailedAttemptRecorded(ev(3, 3));
      await coordinator.idle();
      expect(reads, 2);
      expect(await evidence.list(), isEmpty);
      expect(coordinator.status.captureCancelled, 1);
    });

    test(
        'B8 owner success during the permission query: the camera is never '
        'asked to capture', () async {
      await enable();
      platform = _PermissionHookService(() => coordinator.onOwnerVerified())
        ..permission = CameraPermissionState.granted;
      coordinator = build();
      coordinator.onFailedAttemptRecorded(ev(3, 3));
      await coordinator.idle();
      expect(platform.captures, 0);
      expect(coordinator.status.captureCancelled, 1);
      expect(await evidence.list(), isEmpty);
    });

    test(
        'B9 owner success during the trigger settings read: neither the '
        'alarm nor the camera starts', () async {
      await enable(alarm: true);
      int reads = 0;
      db.onRead[IntruderDefenseSettingsStore.storageKey] = () {
        if (++reads == 1) coordinator.onOwnerVerified();
      };
      coordinator.onFailedAttemptRecorded(ev(3, 3));
      await coordinator.idle();
      expect(platform.alarmStarts, 0);
      expect(platform.captures, 0);
      expect(coordinator.status.triggers, 0);
    });

    test(
        'B7 OWN-1: a failure verified BEFORE the owner success but persisted '
        'AFTER it is logged (M1) yet never reaches the listener', () async {
      final _HookDb hdb = _HookDb();
      final AppContainer c = AppContainer.inMemory(database: hdb);
      final _Recorder rec = _Recorder();
      c.intruderMonitor.listener = rec;
      await c.auth.enrollPin('1234');

      hdb.logWriteGate = Completer<void>(); // hold the M1 log write
      final AuthAttemptResult? bad = (await c.auth
              .authenticatePin('0000')
              .timeout(const Duration(seconds: 5)))
          .valueOrNull;
      expect(bad, isA<AuthFailure>(), reason: 'verdict not delayed');
      final AuthAttemptResult? good = (await c.auth
              .authenticatePin('1234')
              .timeout(const Duration(seconds: 5)))
          .valueOrNull;
      expect(good, isA<AuthSuccess>());
      expect(rec.owner, 1);

      hdb.logWriteGate!.complete(); // the failure now persists
      hdb.logWriteGate = null;
      await c.intruderMonitor.idle();
      expect(rec.events, isEmpty, reason: 'superseded by the owner success');
      final IntruderFailureLog log = (await c.intruderMonitor.snapshot())!;
      expect(log.events.map((FailedAttemptEvent e) => e.seq), <int>[0],
          reason: 'M1 log still records the failure');
      expect(log.consecutiveFailures, 0);

      // A NEW failure after the success is reported normally.
      await c.auth.authenticatePin('9999');
      await c.intruderMonitor.idle();
      expect(rec.events.map((FailedAttemptEvent e) => e.seq), <int>[1]);
    });
  });

  // ===========================================================================
  group('Gate C — consent revocation during a pending capture / alarm', () {
    Future<void> revoke({bool photo = false, bool alarm = false}) async {
      final IntruderDefenseSettings next =
          IntruderDefenseSettings(evidenceEnabled: photo, alarmEnabled: alarm);
      await settings.write(next);
      coordinator.onSettingsChanged(next);
    }

    test('C1 photo disabled: pending capture aborted; late success dropped',
        () async {
      await enable();
      final Completer<CaptureResult> gate = await pendingCapture();
      await revoke();
      expect(platform.captureAborts, 1);
      gate.complete(CaptureSucceeded(jpegWithMetadata()));
      await coordinator.idle();
      expect(await evidence.list(), isEmpty);
      expect(coordinator.status.captureCancelled, 1);
    });

    test('C1b late FAILURE after revocation is a cancel, never persisted',
        () async {
      await enable();
      final Completer<CaptureResult> gate = await pendingCapture();
      await revoke();
      gate.complete(const CaptureFailed('cancelled'));
      await coordinator.idle();
      expect(await evidence.list(), isEmpty);
      expect(coordinator.status.captureCancelled, 1);
      expect(coordinator.status.captureFailed, 0);
    });

    test(
        'C2 revoked in storage without a notification: the authoritative '
        're-check still drops the late success', () async {
      await enable();
      final Completer<CaptureResult> gate = await pendingCapture();
      await settings.write(const IntruderDefenseSettings()); // no notify
      gate.complete(CaptureSucceeded(jpegWithMetadata()));
      await coordinator.idle();
      expect(await evidence.list(), isEmpty);
      expect(coordinator.status.captureCancelled, 1);
    });

    test(
        'C3 re-enable: the OLD capture still cannot persist; only a NEW '
        'eligible event captures', () async {
      await enable();
      final Completer<CaptureResult> old = await pendingCapture(seq: 3);
      await revoke();
      const IntruderDefenseSettings on =
          IntruderDefenseSettings(evidenceEnabled: true);
      await settings.write(on);
      coordinator.onSettingsChanged(on);

      old.complete(CaptureSucceeded(jpegWithMetadata())); // late, old epoch
      await coordinator.idle();
      expect(await evidence.list(), isEmpty);

      coordinator.onFailedAttemptRecorded(ev(3, 3)); // redelivered: deduped
      await coordinator.idle();
      expect(platform.captures, 1);

      platform.gate = null;
      coordinator.onFailedAttemptRecorded(ev(4, 2)); // not the threshold
      coordinator.onFailedAttemptRecorded(ev(13, 3)); // new eligible event
      await coordinator.idle();
      expect((await evidence.list()).map((EvidenceItem e) => e.seq), <int>[13]);
    });

    test('C4 alarm disabled while playing: stopped; photo consent untouched',
        () async {
      await enable(alarm: true);
      final Completer<CaptureResult> gate = await pendingCapture();
      expect(platform.alarmPlaying, isTrue);
      await revoke(photo: true); // alarm off, photo stays on
      await drain();
      expect(platform.alarmPlaying, isFalse);
      expect(platform.captureAborts, 0, reason: 'photo consent unchanged');
      gate.complete(CaptureSucceeded(jpegWithMetadata()));
      await coordinator.idle();
      expect((await evidence.list()).single.seq, 3);
    });

    test('C5 alarm disabled during a PENDING start: ends silent', () async {
      await enable(photo: false, alarm: true);
      final Completer<AlarmStartResult> alarm = Completer<AlarmStartResult>();
      platform.alarmGate = alarm;
      coordinator.onFailedAttemptRecorded(ev(3, 3));
      await drain();
      await revoke();
      alarm.complete(AlarmStartResult.started);
      await coordinator.idle();
      expect(platform.alarmPlaying, isFalse);
      expect(platform.ops.last, 'alarmStop');
      expect(coordinator.status.alarmsCancelled, 1);
      expect(coordinator.status.alarmsStarted, 0);
    });

    test('C6 corrupt settings at the re-check: disabled, nothing persisted',
        () async {
      await enable();
      final Completer<CaptureResult> gate = await pendingCapture();
      await db.setSetting(IntruderDefenseSettingsStore.storageKey, 'junk');
      gate.complete(CaptureSucceeded(jpegWithMetadata()));
      await coordinator.idle();
      expect(await evidence.list(), isEmpty);
    });

    test('C7 unreadable settings: disabled (trigger and re-check)', () async {
      await enable(alarm: true);
      db.unreadable.add(IntruderDefenseSettingsStore.storageKey);
      expect((await settings.read()).settings.evidenceEnabled, isFalse);
      coordinator.onFailedAttemptRecorded(ev(3, 3));
      await coordinator.idle();
      expect(platform.captures + platform.alarmStarts, 0);

      db.unreadable.clear();
      final Completer<CaptureResult> gate = await pendingCapture(seq: 23);
      db.unreadable.add(IntruderDefenseSettingsStore.storageKey);
      gate.complete(CaptureSucceeded(jpegWithMetadata()));
      await coordinator.idle();
      db.unreadable.clear();
      expect(await evidence.list(), isEmpty);
    });
  });

  // ===========================================================================
  group('Gate D — storage commit point', () {
    test('D1 save(stillValid: false) writes nothing and reports cancelled',
        () async {
      final EvidenceSaveResult r = await evidence.save(
          seq: 7, jpeg: jpegWithMetadata(), stillValid: () => false);
      expect(r, EvidenceSaveResult.cancelled);
      expect(await evidence.list(), isEmpty);
      expect(
          await db.getSetting('${IntruderEvidenceStore.blobPrefix}7'), isNull);
      expect(await db.getSetting(IntruderEvidenceStore.indexKey), isNull);
      // and a valid save afterwards works normally
      expect(
          await evidence.save(
              seq: 7, jpeg: jpegWithMetadata(), stillValid: () => true),
          EvidenceSaveResult.saved);
      final Uint8List? read = await evidence.readImage(7);
      expect(read, isNotNull);
      expect(containsAscii(read!, secretExif), isFalse);
    });
  });

  // ===========================================================================
  group('end-to-end (real host / real Security screen, gated fake)', () {
    Future<void> pumpApp(WidgetTester tester, AppContainer c) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(SmartAppLockApp(container: c));
      await tester.pumpAndSettle();
    }

    Future<void> protect(AppContainer c) async {
      await c.protectedApps.add(ProtectedApp(
        packageName: _app,
        label: _app,
        addedAt: DateTime(2026, 10, 22),
        securityLevel: AppSecurityLevel.defaultLevel,
      ));
      await c.protectionBootstrap.synchronize();
    }

    Future<void> openApp(WidgetTester tester, AppContainer c) async {
      (c.accessibility as StaticAccessibilityLockService)
          .emitForegroundPackage(_app);
      await tester.pumpAndSettle();
    }

    Future<void> typePin(WidgetTester tester, String pin) async {
      await tester.pump(const Duration(milliseconds: 250));
      for (final String d in pin.split('')) {
        await tester.tap(find.byKey(Key('pin_key_$d')));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
    }

    Object? sessionFor(AppContainer c) =>
        (c.accessController as DefaultAccessController).sessionFor(_app);

    testWidgets(
        'B-E2E: the correct PIN unlocks while the capture is STILL pending; '
        'the capture is aborted, the alarm stopped, the late success dropped',
        (WidgetTester tester) async {
      final GatedEvidenceService fake = GatedEvidenceService()
        ..permission = CameraPermissionState.granted
        ..gate = Completer<CaptureResult>();
      final AppContainer c = AppContainer.inMemory(intruderEvidence: fake);
      await pumpApp(tester, c);
      await c.auth.enrollPin(_pin);
      await c.intruderDefenseSettings.write(const IntruderDefenseSettings(
          evidenceEnabled: true, alarmEnabled: true, threshold: 1));
      await protect(c);
      await openApp(tester, c);

      await typePin(tester, '111111');
      await tester.pumpAndSettle();
      expect(fake.captures, 1);
      expect(fake.alarmPlaying, isTrue);
      expect(sessionFor(c), isNull);

      await typePin(tester, _pin);
      expect(fake.gate!.isCompleted, isFalse, reason: 'capture still pending');
      expect(sessionFor(c), isNotNull, reason: 'auth NOT delayed by capture');
      expect(
          (c.installedAppsService as StaticInstalledAppsService).launchAppCalls,
          1);
      expect(fake.captureAborts, 1);
      expect(fake.alarmPlaying, isFalse);

      fake.gate!.complete(CaptureSucceeded(jpegWithMetadata()));
      await tester.pumpAndSettle();
      await c.intruderDefense.idle();
      expect(await c.intruderEvidence.list(), isEmpty);
      expect(c.intruderDefense.status.captureCancelled, 1);
    });

    testWidgets(
        'C-E2E: disabling photo on the Security screen (PIN-verified) while a '
        'capture is pending aborts it; the late success is dropped',
        (WidgetTester tester) async {
      final GatedEvidenceService fake = GatedEvidenceService()
        ..permission = CameraPermissionState.granted
        ..gate = Completer<CaptureResult>();
      final AppContainer c = AppContainer.inMemory(intruderEvidence: fake);
      await c.auth.enrollPin(_pin);
      await c.intruderDefenseSettings
          .write(const IntruderDefenseSettings(evidenceEnabled: true));
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(AppScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.dark,
          onGenerateRoute: AppRouter.onGenerateRoute,
          home: const Scaffold(body: SecurityScreen()),
        ),
      ));
      await tester.pumpAndSettle();

      c.intruderDefense.onFailedAttemptRecorded(ev(3, 3));
      await tester.pumpAndSettle();
      expect(fake.captures, 1);

      final Finder sw = find.descendant(
          of: find.byKey(const ValueKey<String>('intruder_photo_switch')),
          matching: find.byType(Switch));
      await tester.ensureVisible(sw);
      await tester.pumpAndSettle();
      await tester.tap(sw);
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await typePin(tester, _pin);
      expect((await c.intruderDefenseSettings.read()).settings.evidenceEnabled,
          isFalse);
      expect(fake.ops.where((String o) => o == 'abort'), isNotEmpty);

      fake.gate!.complete(CaptureSucceeded(jpegWithMetadata()));
      await tester.pumpAndSettle();
      await c.intruderDefense.idle();
      expect(await c.intruderEvidence.list(), isEmpty);
      expect(c.intruderDefense.status.captureCancelled, 1);
    });

    testWidgets(
        'D-E2E: camera/alarm failures change neither verdicts, cooldown nor '
        'the native shield calls (compared with the feature off)',
        (WidgetTester tester) async {
      Future<(CredentialState, List<int>, Object?)> run(bool on) async {
        final AppContainer c = AppContainer.inMemory(
            intruderEvidence: on ? ThrowingEvidenceService() : null);
        await pumpApp(tester, c);
        await c.auth.enrollPin(_pin);
        if (on) {
          await c.intruderDefenseSettings.write(const IntruderDefenseSettings(
              evidenceEnabled: true, alarmEnabled: true, threshold: 1));
        }
        await protect(c);
        await openApp(tester, c);
        for (final String p in <String>['111111', '222222', '333333']) {
          await typePin(tester, p);
          await c.intruderMonitor.idle();
          await c.intruderDefense.idle();
          await tester.pumpAndSettle();
        }
        await typePin(tester, _pin); // blocked by the cooldown
        final StaticOverlayLockService o =
            c.overlay as StaticOverlayLockService;
        final CredentialState s = (await c.auth.status()).valueOrNull!;
        final List<int> shield = <int>[
          o.showLockChallengeCalls,
          o.hideLockChallengeCalls,
          o.markChallengeReadyCalls,
        ];
        await tester.pumpWidget(const SizedBox());
        return (s, shield, sessionFor(c));
      }

      final (CredentialState off, List<int> shieldOff, Object? sOff) =
          await run(false);
      final (CredentialState on, List<int> shieldOn, Object? sOn) =
          await run(true);
      expect(sOff, isNull);
      expect(sOn, isNull, reason: 'cooldown still blocks the correct PIN');
      expect(on.failedAttempts, off.failedAttempts);
      expect(on.lockoutStreak, off.lockoutStreak);
      expect(on.lockedOutUntil, isNotNull);
      expect(on.lockedOutUntil!.difference(off.lockedOutUntil!).inSeconds.abs(),
          lessThan(5),
          reason: 'same cooldown length');
      expect(shieldOn, shieldOff, reason: 'shield behaviour unchanged');
    });
  });
}
