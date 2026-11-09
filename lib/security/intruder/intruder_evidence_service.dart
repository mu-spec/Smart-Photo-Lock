// Phase 12 / Milestone 2 — platform boundary for camera evidence and the
// alarm (interface + value types only; this package stays platform-free).
// The production implementation lives in
// lib/services/impl/method_channel_intruder_evidence_service.dart and talks
// to MainActivity (framework Camera2 / ToneGenerator; no new SDK). Every
// call fails quiet: errors come back as values, never as exceptions that
// could reach authentication.

import 'dart:async';
import 'dart:typed_data';

enum CameraPermissionState { granted, denied, unavailable }

/// Outcome of one still capture.
sealed class CaptureResult {
  const CaptureResult();
}

final class CaptureSucceeded extends CaptureResult {
  const CaptureSucceeded(this.jpeg);
  final Uint8List jpeg;
}

/// Why no image was produced (permission, not foreground, aborted by
/// pause/screen-off, camera busy/unavailable, timeout, error).
final class CaptureFailed extends CaptureResult {
  const CaptureFailed(this.reason);
  final String reason;
}

enum AlarmStartResult {
  started,
  alreadyPlaying,
  suppressedByDnd,
  suppressedByRinger,
  focusDenied,
  notForeground,
  error,
}

abstract interface class IntruderEvidenceService {
  Future<CameraPermissionState> cameraPermission();

  /// Shows the system permission dialog. Only ever called from the
  /// owner-verified enable flow.
  Future<CameraPermissionState> requestCameraPermission();

  /// One front-camera still, at most [maxBytes]. Only succeeds while the
  /// challenge Activity is resumed and the screen is interactive.
  Future<CaptureResult> captureStill({required int maxBytes});

  /// Aborts an in-flight capture (owner success, consent revoked, Dart-side
  /// timeout). Idempotent; a no-op when nothing is in flight. The pending
  /// [captureStill] then completes with a failure.
  Future<void> abortCapture();

  Future<AlarmStartResult> startAlarm({required Duration duration});

  Future<void> stopAlarm();
}
