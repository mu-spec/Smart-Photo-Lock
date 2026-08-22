import 'dart:async';

import 'package:flutter/services.dart';

import '../../utilities/result.dart';
import '../screen_state_service.dart';

/// Production [ScreenStateService] over the native
/// `smart_app_lock/screen_state` EventChannel (Phase 5K).
///
/// The native side relays `ACTION_SCREEN_OFF` / `ACTION_SCREEN_ON`
/// broadcasts as `screen_off` / `screen_on` payloads while a listener
/// is attached. Fail-closed (QA fix #4C.1): unknown payloads, channel
/// errors and a missing native handler surface as [Result.failure]
/// events — never fabricated screen states.
class MethodChannelScreenStateService implements ScreenStateService {
  MethodChannelScreenStateService({EventChannel? channel})
      : _channel = channel ??
            const EventChannel('smart_app_lock/screen_state');

  final EventChannel _channel;

  @override
  Stream<Result<ScreenStateEvent>> get events {
    // Phase 5 mobile-QA fix #4C.1: the framework's
    // `EventChannel.receiveBroadcastStream` SWALLOWS `listen` activation
    // failures — a missing native handler (MissingPluginException) or a
    // platform error during activation is caught inside its `onListen`
    // and routed to `FlutterError.reportError`, so it NEVER reaches the
    // stream (subscribers see nothing, not even a failure). Owning the
    // stream lifecycle here (register the inbound message handler and
    // invoke `listen` ourselves) surfaces EVERY channel error — error
    // envelopes AND a missing native handler — as exactly one
    // [Result.failure] data event. Fail-closed: an error or an unknown
    // payload is never turned into a screen state; the fail-quiet
    // consumer (LockTrigger) stays quiet.
    final EventChannel eventChannel = _channel;
    final MethodChannel activation =
        MethodChannel(eventChannel.name, eventChannel.codec);
    late StreamController<Result<ScreenStateEvent>> controller;
    void emit(Result<ScreenStateEvent> result) {
      if (!controller.isClosed) {
        controller.add(result);
      }
    }

    controller = StreamController<Result<ScreenStateEvent>>.broadcast(
      onListen: () {
        // Inbound platform messages on this channel: success envelopes
        // carry screen-state payloads; error envelopes carry failures;
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
              final dynamic payload = eventChannel.codec.decodeEnvelope(reply);
              emit(
                switch (payload) {
                  'screen_off' => Result.success(ScreenStateEvent.screenOff),
                  'screen_on' => Result.success(ScreenStateEvent.screenOn),
                  _ => Result.failure(
                      StateError('Unknown screen-state payload: $payload'),
                    ),
                },
              );
            } catch (error) {
              // PlatformException (error envelope) or an undecodable
              // payload — a failure, never fabricated data.
              emit(Result<ScreenStateEvent>.failure(error));
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
              emit(Result<ScreenStateEvent>.failure(error));
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
