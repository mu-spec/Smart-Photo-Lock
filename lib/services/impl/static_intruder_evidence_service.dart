// Phase 12 / Milestone 2 — in-memory intruder evidence / alarm platform for
// tests and AppContainer.inMemory: no camera, no audio.

import '../../security/intruder/intruder_evidence_service.dart';

/// In-memory implementation for tests and previews: no camera, no audio.
class StaticIntruderEvidenceService implements IntruderEvidenceService {
  CameraPermissionState permission = CameraPermissionState.denied;
  CameraPermissionState permissionAfterRequest = CameraPermissionState.granted;
  CaptureResult Function()? onCapture;
  AlarmStartResult alarmResult = AlarmStartResult.started;
  int permissionRequests = 0;
  int captures = 0;
  int captureAborts = 0;
  int alarmStarts = 0;
  int alarmStops = 0;
  bool alarmPlaying = false;

  @override
  Future<CameraPermissionState> cameraPermission() async => permission;

  @override
  Future<CameraPermissionState> requestCameraPermission() async {
    permissionRequests++;
    permission = permissionAfterRequest;
    return permission;
  }

  @override
  Future<CaptureResult> captureStill({required int maxBytes}) async {
    captures++;
    return onCapture?.call() ?? const CaptureFailed('unavailable');
  }

  @override
  Future<void> abortCapture() async {
    captureAborts++;
  }

  @override
  Future<AlarmStartResult> startAlarm({required Duration duration}) async {
    alarmStarts++;
    if (alarmPlaying) return AlarmStartResult.alreadyPlaying;
    if (alarmResult == AlarmStartResult.started) alarmPlaying = true;
    return alarmResult;
  }

  @override
  Future<void> stopAlarm() async {
    alarmStops++;
    alarmPlaying = false;
  }
}
