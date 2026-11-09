// Phase 12 / Milestone 2 — method-channel implementation of the intruder
// evidence / alarm platform boundary (MainActivity IntruderEvidenceChannel).

import 'package:flutter/services.dart';

import '../../security/intruder/intruder_evidence_service.dart';

/// Method-channel implementation (MainActivity / IntruderEvidenceChannel).
class MethodChannelIntruderEvidenceService implements IntruderEvidenceService {
  MethodChannelIntruderEvidenceService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'com.smartapplock.app/intruder_evidence';

  final MethodChannel _channel;

  static CameraPermissionState _permission(Object? v) => switch (v) {
        'granted' => CameraPermissionState.granted,
        'unavailable' => CameraPermissionState.unavailable,
        _ => CameraPermissionState.denied,
      };

  @override
  Future<CameraPermissionState> cameraPermission() async {
    try {
      return _permission(
          await _channel.invokeMethod<String>('cameraPermission'));
    } catch (_) {
      return CameraPermissionState.unavailable;
    }
  }

  @override
  Future<CameraPermissionState> requestCameraPermission() async {
    try {
      return _permission(
          await _channel.invokeMethod<String>('requestCameraPermission'));
    } catch (_) {
      return CameraPermissionState.unavailable;
    }
  }

  @override
  Future<CaptureResult> captureStill({required int maxBytes}) async {
    try {
      final Uint8List? bytes = await _channel.invokeMethod<Uint8List>(
          'captureStill', <String, Object>{'maxBytes': maxBytes});
      return bytes == null
          ? const CaptureFailed('empty')
          : CaptureSucceeded(bytes);
    } on PlatformException catch (e) {
      return CaptureFailed(e.code);
    } catch (_) {
      return const CaptureFailed('error');
    }
  }

  @override
  Future<void> abortCapture() async {
    try {
      await _channel.invokeMethod<void>('abortCapture');
    } catch (_) {
      // Native also aborts on pause/destroy/timeout.
    }
  }

  @override
  Future<AlarmStartResult> startAlarm({required Duration duration}) async {
    try {
      final String? r = await _channel.invokeMethod<String>('startAlarm',
          <String, Object>{'durationMs': duration.inMilliseconds});
      return AlarmStartResult.values.firstWhere(
        (AlarmStartResult a) => a.name == r,
        orElse: () => AlarmStartResult.error,
      );
    } catch (_) {
      return AlarmStartResult.error;
    }
  }

  @override
  Future<void> stopAlarm() async {
    try {
      await _channel.invokeMethod<void>('stopAlarm');
    } catch (_) {
      // Native also stops on pause/destroy/timeout.
    }
  }
}
