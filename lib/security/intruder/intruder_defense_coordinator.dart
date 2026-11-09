// Phase 12 / Milestone 2 — evidence capture + alarm coordinator.
//
// OBSERVE-ONLY. It listens to the M1 IntruderMonitor and is called only
// after a failed-attempt event was PERSISTED (and not superseded by a later
// owner success). It holds no reference to the credential manager, the
// access controller, the shield, profiles or rules; nothing it does can
// reach an authentication verdict. Every entry point is synchronous and
// returns immediately; all work is fire-and-forget and fails quiet into
// [IntruderDefenseStatus].
//
// Trigger (design gate §A): an event from a protected-app challenge whose
// run counter EQUALS the configured threshold — unique per run, so it fires
// once per threshold crossing. Evidence identity = the M1 event seq.
//
// Cancellation (final security gate B/C): an owner success or a consent
// revocation bumps an epoch SYNCHRONOUSLY and asks the platform to abort.
// Work started under an older epoch can never persist an image (checked
// after every await and, finally, inside the store's serialized write) and
// an alarm whose start was still pending is stopped as soon as it reports.

import 'dart:async';
import 'dart:collection';

import '../credentials/verified_attempt.dart';
import 'failed_attempt_event.dart';
import 'intruder_defense_settings.dart';
import 'intruder_evidence_service.dart';
import 'intruder_evidence_store.dart';
import 'intruder_monitor.dart';

/// Counters only — no image data, no credential material.
final class IntruderDefenseStatus {
  int triggers = 0;
  int captured = 0;
  int captureSkipped = 0;
  int captureFailed = 0;
  int captureCancelled = 0;
  int saveFailed = 0;
  int alarmsStarted = 0;
  int alarmsSuppressed = 0;
  int alarmsCancelled = 0;
  int errors = 0;
  String? lastFailure;
}

class IntruderDefenseCoordinator implements IntruderEventListener {
  IntruderDefenseCoordinator({
    required IntruderDefenseSettingsStore settings,
    required IntruderEvidenceStore evidence,
    required IntruderEvidenceService service,
    this.alarmDuration = defaultAlarmDuration,
    this.captureTimeout = defaultCaptureTimeout,
  })  : _settings = settings,
        _evidence = evidence,
        _service = service;

  static const Duration defaultAlarmDuration = Duration(seconds: 30);

  /// Dart-side bound on one platform capture call (native: 4 s open +
  /// 0.7 s warm-up + 4 s capture). A late native reply is ignored.
  static const Duration defaultCaptureTimeout = Duration(seconds: 12);
  static const int _handledCapacity = 256;

  final IntruderDefenseSettingsStore _settings;
  final IntruderEvidenceStore _evidence;
  final IntruderEvidenceService _service;
  final Duration alarmDuration;
  final Duration captureTimeout;

  final IntruderDefenseStatus status = IntruderDefenseStatus();
  final LinkedHashSet<int> _handled = LinkedHashSet<int>();
  final Set<Future<void>> _inFlight = <Future<void>>{};
  bool _capturing = false;

  /// Bumped by owner success and by photo-consent revocation.
  int _captureEpoch = 0;

  /// Bumped by owner success and by alarm-consent revocation.
  int _alarmEpoch = 0;
  bool _alarmPlaying = false;
  int _alarmStartsPending = 0;

  /// Completes when every started operation has finished (tests).
  Future<void> idle() async {
    while (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight.toList());
    }
  }

  void _track(Future<void> work) {
    late final Future<void> op;
    op = work.whenComplete(() => _inFlight.remove(op));
    _inFlight.add(op);
  }

  @override
  void onFailedAttemptRecorded(FailedAttemptEvent event) {
    if (event.surface != AuthAttemptSurface.protectedAppChallenge) return;
    if (!_handled.add(event.seq)) return; // duplicate notification
    while (_handled.length > _handledCapacity) {
      _handled.remove(_handled.first);
    }
    _track(_handle(event, _captureEpoch, _alarmEpoch));
  }

  /// Synchronous and non-blocking: the owner just authenticated. Cancels any
  /// pending capture and silences (or pre-empts) the alarm.
  @override
  void onOwnerVerified() {
    _invalidateCapture();
    _invalidateAlarm();
  }

  /// The owner saved new settings (authorized flow). Revoked consent takes
  /// effect immediately for work already in progress.
  ///
  /// Revocation always signals the platform (both calls are idempotent), so a
  /// camera session or tone the coordinator does not know about is stopped.
  void onSettingsChanged(IntruderDefenseSettings settings) {
    if (!settings.evidenceEnabled) _invalidateCapture(force: true);
    if (!settings.alarmEnabled) _invalidateAlarm(force: true);
  }

  void _invalidateCapture({bool force = false}) {
    _captureEpoch++;
    if (force || _capturing) {
      _track(_quiet(_service.abortCapture));
    }
  }

  void _invalidateAlarm({bool force = false}) {
    _alarmEpoch++;
    if (force || _alarmPlaying || _alarmStartsPending > 0) {
      _alarmPlaying = false;
      _track(_quiet(_service.stopAlarm));
    }
  }

  Future<void> _quiet(Future<void> Function() call) async {
    try {
      await call();
    } catch (_) {
      status.errors++;
    }
  }

  Future<void> _handle(
    FailedAttemptEvent event,
    int captureEpoch,
    int alarmEpoch,
  ) async {
    try {
      final IntruderDefenseSettings s = (await _settings.read()).settings;
      if (event.consecutiveFailures != s.threshold) return;
      final bool alarm = s.alarmEnabled && alarmEpoch == _alarmEpoch;
      final bool photo = s.evidenceEnabled && captureEpoch == _captureEpoch;
      if (!alarm && !photo) return;
      status.triggers++;
      await Future.wait(<Future<void>>[
        if (alarm) _alarm(alarmEpoch),
        if (photo) _capture(event, captureEpoch),
      ]);
    } catch (_) {
      status.errors++;
    }
  }

  Future<void> _alarm(int epoch) async {
    _alarmStartsPending++;
    AlarmStartResult r;
    try {
      r = await _service.startAlarm(duration: alarmDuration);
    } catch (_) {
      status.errors++;
      return;
    } finally {
      _alarmStartsPending--;
    }
    if (r != AlarmStartResult.started) {
      status.alarmsSuppressed++;
      status.lastFailure = 'alarm:${r.name}';
      return;
    }
    if (epoch != _alarmEpoch) {
      // Owner success / revocation arrived while the start was pending.
      status.alarmsCancelled++;
      await _quiet(_service.stopAlarm);
      return;
    }
    status.alarmsStarted++;
    _alarmPlaying = true;
  }

  Future<void> _capture(FailedAttemptEvent event, int epoch) async {
    if (_capturing) {
      status.captureSkipped++; // single capture slot; never queued
      return;
    }
    _capturing = true;
    try {
      if (await _service.cameraPermission() != CameraPermissionState.granted) {
        status.captureSkipped++;
        status.lastFailure = 'capture:permission';
        return;
      }
      if (epoch != _captureEpoch) {
        _cancelled();
        return;
      }
      bool timedOut = false;
      final CaptureResult r = await _service
          .captureStill(maxBytes: _evidence.maxImageBytes)
          .timeout(captureTimeout, onTimeout: () {
        timedOut = true;
        return const CaptureFailed('timeout');
      });
      if (timedOut) {
        _track(_quiet(_service.abortCapture));
      }
      if (epoch != _captureEpoch) {
        _cancelled(); // late success / failure / timeout after cancel
        return;
      }
      switch (r) {
        case CaptureFailed(:final String reason):
          status.captureFailed++;
          status.lastFailure = 'capture:$reason';
        case CaptureSucceeded(:final jpeg):
          // Authoritative consent re-check (corrupt/unreadable = disabled).
          final IntruderDefenseSettings now = (await _settings.read()).settings;
          if (!now.evidenceEnabled || epoch != _captureEpoch) {
            _cancelled();
            return;
          }
          final EvidenceSaveResult saved = await _evidence.save(
            seq: event.seq,
            jpeg: jpeg,
            packageName: event.packageName,
            // Linearization point: checked synchronously inside the store's
            // serialized write, immediately before the blob is written.
            stillValid: () => epoch == _captureEpoch,
          );
          if (saved == EvidenceSaveResult.saved) {
            status.captured++;
          } else if (saved == EvidenceSaveResult.cancelled) {
            _cancelled();
          } else {
            status.saveFailed++;
            status.lastFailure = 'save:${saved.name}';
          }
      }
    } catch (_) {
      status.errors++;
    } finally {
      _capturing = false;
    }
  }

  void _cancelled() {
    status.captureCancelled++;
    status.lastFailure = 'capture:cancelled';
  }
}
