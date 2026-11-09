// Phase 12 / M2 test fixtures: a structurally valid JPEG carrying metadata
// that must be stripped, and a gated fake evidence platform.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:smart_app_lock/security/intruder/intruder_evidence_service.dart';
import 'package:smart_app_lock/services/impl/static_intruder_evidence_service.dart';

const String secretExif = 'GPS-48.8584N-SECRET';
const String secretComment = 'OWNER-COMMENT-SECRET';

List<int> _segment(int marker, List<int> payload) {
  final int len = payload.length + 2;
  return <int>[0xFF, marker, len >> 8, len & 0xFF, ...payload];
}

/// SOI, APP0(JFIF), APP1(Exif + GPS text), COM, DQT, SOS + scan data, EOI.
/// [padding] grows the entropy-coded data to hit size limits.
Uint8List jpegWithMetadata({int padding = 32, int fill = 0x11}) {
  return Uint8List.fromList(<int>[
    0xFF,
    0xD8,
    ..._segment(
        0xE0, <int>[...ascii.encode('JFIF'), 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]),
    ..._segment(0xE1,
        <int>[...ascii.encode('Exif'), 0, 0, ...ascii.encode(secretExif)]),
    ..._segment(0xFE, ascii.encode(secretComment)),
    ..._segment(0xDB, List<int>.filled(65, 1)),
    ..._segment(0xDA, <int>[1, 1, 0, 0, 0x3F, 0]),
    ...List<int>.filled(padding, fill),
    0xFF,
    0xD9,
  ]);
}

bool containsAscii(Uint8List bytes, String needle) =>
    latin1.decode(bytes, allowInvalid: true).contains(needle);

/// Fake platform whose capture (and alarm start) can be held open by a test.
///
/// [abortCapture] only records the call: it never completes [gate], so a test
/// decides which LATE callback (success / failure / none) arrives afterwards.
class GatedEvidenceService extends StaticIntruderEvidenceService {
  Completer<CaptureResult>? gate;
  Completer<AlarmStartResult>? alarmGate;

  /// Ordered platform calls: capture, abort, alarmStart, alarmStop.
  final List<String> ops = <String>[];

  @override
  Future<CaptureResult> captureStill({required int maxBytes}) async {
    captures++;
    ops.add('capture');
    final Completer<CaptureResult>? g = gate;
    if (g != null) return g.future;
    return onCapture?.call() ?? CaptureSucceeded(jpegWithMetadata());
  }

  @override
  Future<void> abortCapture() async {
    ops.add('abort');
    return super.abortCapture();
  }

  @override
  Future<AlarmStartResult> startAlarm({required Duration duration}) async {
    ops.add('alarmStart');
    final Completer<AlarmStartResult>? g = alarmGate;
    if (g == null) return super.startAlarm(duration: duration);
    alarmStarts++;
    // Native order: the tone starts when the call is processed; only the
    // reply is delayed. [startTakesEffectOnReply] models the pessimistic
    // order (tone starts when the reply is produced).
    if (!startTakesEffectOnReply) alarmPlaying = true;
    final AlarmStartResult r = await g.future;
    if (r != AlarmStartResult.started) {
      alarmPlaying = false;
    } else if (startTakesEffectOnReply) {
      alarmPlaying = true;
    }
    return r;
  }

  bool startTakesEffectOnReply = false;

  @override
  Future<void> stopAlarm() async {
    ops.add('alarmStop');
    return super.stopAlarm();
  }
}

/// Fake platform whose every call throws.
class ThrowingEvidenceService implements IntruderEvidenceService {
  int calls = 0;

  @override
  Future<CameraPermissionState> cameraPermission() async {
    calls++;
    throw StateError('camera service down');
  }

  @override
  Future<CameraPermissionState> requestCameraPermission() async {
    calls++;
    throw StateError('camera service down');
  }

  @override
  Future<CaptureResult> captureStill({required int maxBytes}) async {
    calls++;
    throw StateError('camera service down');
  }

  @override
  Future<void> abortCapture() async {
    calls++;
    throw StateError('camera service down');
  }

  @override
  Future<AlarmStartResult> startAlarm({required Duration duration}) async {
    calls++;
    throw StateError('audio service down');
  }

  @override
  Future<void> stopAlarm() async {
    calls++;
    throw StateError('audio service down');
  }
}
