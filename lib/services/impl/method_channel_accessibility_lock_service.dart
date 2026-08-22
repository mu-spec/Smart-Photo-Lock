import 'dart:async';

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
/// fail-closed (QA fix #4C.1): channel errors AND a missing native
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
    // Phase 5 mobile-QA fix #4C.1: the framework's
    // `EventChannel.receiveBroadcastStream` SWALLOWS `listen` activation
    // failures — a missing native handler (MissingPluginException) or a
    // platform error during activation is caught inside its `onListen`
    // and routed to `FlutterError.reportError`, so it NEVER reaches the
    // stream (subscribers see nothing, not even a failure). Owning the
    // stream lifecycle here (register the inbound message handler and
    // invoke `listen` ourselves) surfaces EVERY channel error — error
    // envelopes AND a missing native handler — as exactly one
    // [Result.failure] data event. Fail-closed: an error is never
    // turned into a foreground package; the fail-quiet consumer
    // (ForegroundAppMonitor) counts it and stays quiet.
    final EventChannel eventChannel = _eventsChannel;
    final MethodChannel activation =
        MethodChannel(eventChannel.name, eventChannel.codec);
    late StreamController<Result<String>> controller;
    void emit(Result<String> result) {
      if (!controller.isClosed) {
        controller.add(result);
      }
    }

    controller = StreamController<Result<String>>.broadcast(
      onListen: () {
        // Inbound platform messages on this channel: success envelopes
        // carry foreground packages; error envelopes carry failures;
        // a null reply signals end-of-stream.
        eventChannel.binaryMessenger.setMessageHandler(
          eventChannel.name,
          (ByteData? reply) async {
            if (reply == null) {
              // End-of-stream: close only once.
              if (!controller.isClosed) {
                await controller.close();
              }
              return null;
            }
            try {
              emit(Result.success(eventChannel.codec.decodeEnvelope(reply) as String));
            } catch (error) {
              // PlatformException (error envelope) or an undecodable
              // payload — a failure, never fabricated data.
              emit(Result<String>.failure(error));
            }
            return null;
          },
        );
        // Activate the native stream. If activation itself fails (no
        // native handler, platform error), surface exactly one failure
        // instead of losing the error to FlutterError.
        unawaited(
          activation.invokeMethod<void>('listen').then(
            (_) {},
            onError: (Object error, StackTrace stackTrace) {
              emit(Result<String>.failure(error));
            },
          ),
        );
      },
      onCancel: () async {
        eventChannel.binaryMessenger.setMessageHandler(eventChannel.name, null);
        try {
          await activation.invokeMethod<void>('cancel');
        } catch (_) {
          // Fail-quiet: nothing to cancel (missing handler, teardown).
        }
      },
    );
    return controller.stream;
  }
}
