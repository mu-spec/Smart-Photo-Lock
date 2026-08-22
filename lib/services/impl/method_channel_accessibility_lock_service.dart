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
/// fail-closed (QA fix #4C): channel errors and a missing native
/// handler surface as [Result.failure] events, never fabricated
/// packages.
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
    // Phase 5 mobile-QA fix #4C: every channel error — including a
    // MISSING native handler, which arrives asynchronously as a stream
    // error (the platform `send` for the `listen` method call fails)
    // rather than as a synchronous throw — is converted into a
    // [Result.failure] DATA event. The previous `handleError` (which
    // builds a Result and discards it) SWALLOWED errors, so channel
    // problems surfaced as nothing at all. Fail-closed: an error is
    // never turned into a foreground package; the fail-quiet consumer
    // (ForegroundAppMonitor) counts it and stays quiet.
    return _eventsChannel.receiveBroadcastStream().transform(
      StreamTransformer<dynamic, Result<String>>.fromHandlers(
        handleData: (dynamic event, sink) =>
            sink.add(Result.success(event as String)),
        handleError: (Object error, StackTrace stackTrace, sink) =>
            sink.add(Result<String>.failure(error)),
      ),
    );
  }
}
