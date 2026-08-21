import 'package:flutter/services.dart';

import '../../utilities/result.dart';
import '../accessibility_lock_service.dart';

/// Production [AccessibilityLockService] over the native
/// `smart_app_lock/accessibility` channel (Phase 4C) and the
/// `smart_app_lock/accessibility_events` EventChannel (Phase 5A).
///
/// Capability state comes from the system's ENABLED_ACCESSIBILITY_SERVICES
/// setting; enabling happens exclusively through the system Accessibility
/// settings screen. [foregroundPackages] relays window-state package
/// names reported by the detection-only accessibility service —
/// fail-closed: an unavailable event channel yields an empty stream, and
/// channel errors surface as [Result.failure] events (never fabricated
/// packages).
class MethodChannelAccessibilityLockService
    implements AccessibilityLockService {
  MethodChannelAccessibilityLockService({
    MethodChannel? channel,
    EventChannel? eventsChannel,
  })  : _channel = channel ??
            const MethodChannel('smart_app_lock/accessibility'),
        _eventsChannel = eventsChannel ??
            const EventChannel('smart_app_lock/accessibility_events');

  final MethodChannel _channel;
  final EventChannel _eventsChannel;

  @override
  Future<Result<bool>> isServiceEnabled() async {
    try {
      final bool? enabled =
          await _channel.invokeMethod<bool>('isAccessibilityEnabled');
      return Result.success(enabled ?? false);
    } on PlatformException catch (e) {
      return Result.failure(e);
    } on MissingPluginException catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<void>> requestServiceEnable() async {
    try {
      final bool? opened =
          await _channel.invokeMethod<bool>('requestAccessibilityEnable');
      if (opened == true) {
        return Result.success(null);
      }
      return Result.failure(
        StateError('Could not open the accessibility settings screen.'),
      );
    } on PlatformException catch (e) {
      return Result.failure(e);
    } on MissingPluginException catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Stream<Result<String>> get foregroundPackages {
    // Phase 5A: the detection-only accessibility service reports window
    // states through the native event channel. Fail-closed: a missing
    // plugin resolves to an empty stream; channel errors become failure
    // Results so consumers can stay fail-quiet.
    Stream<Result<String>> stream;
    try {
      stream = _eventsChannel.receiveBroadcastStream().map(
            (dynamic event) => Result.success(event as String),
          );
    } on MissingPluginException {
      return const Stream<Result<String>>.empty();
    }
    return stream.handleError((Object error) => Result<String>.failure(error));
  }
}
