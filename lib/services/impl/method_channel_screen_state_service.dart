import 'package:flutter/services.dart';

import '../../utilities/result.dart';
import '../screen_state_service.dart';

/// Production [ScreenStateService] over the native
/// `smart_app_lock/screen_state` EventChannel (Phase 5K).
///
/// The native side relays `ACTION_SCREEN_OFF` / `ACTION_SCREEN_ON`
/// broadcasts as `screen_off` / `screen_on` payloads while a listener
/// is attached. Fail-closed (QA fix #4C): unknown payloads, channel
/// errors and a missing native handler surface as [Result.failure]
/// events — never fabricated screen states.
class MethodChannelScreenStateService implements ScreenStateService {
  MethodChannelScreenStateService({EventChannel? channel})
      : _channel = channel ??
            const EventChannel('smart_app_lock/screen_state');

  final EventChannel _channel;

  @override
  Stream<Result<ScreenStateEvent>> get events {
    // Phase 5 mobile-QA fix #4C: every channel error — including a
    // MISSING native handler, which arrives asynchronously as a stream
    // error (the platform `send` for the `listen` method call fails)
    // rather than as a synchronous throw — is converted into a
    // [Result.failure] DATA event. The previous `handleError` (which
    // builds a Result and discards it) SWALLOWED errors, so channel
    // problems surfaced as nothing at all. Fail-closed: an error or an
    // unknown payload is never turned into a screen state; the
    // fail-quiet consumer (LockTrigger) stays quiet.
    return _channel.receiveBroadcastStream().transform(
      StreamTransformer<dynamic, Result<ScreenStateEvent>>.fromHandlers(
        handleData: (dynamic event, sink) {
          sink.add(
            switch (event) {
              'screen_off' => Result.success(ScreenStateEvent.screenOff),
              'screen_on' => Result.success(ScreenStateEvent.screenOn),
              _ => Result.failure(
                  StateError('Unknown screen-state payload: $event'),
                ),
            },
          );
        },
        handleError: (Object error, StackTrace stackTrace, sink) =>
            sink.add(Result<ScreenStateEvent>.failure(error)),
      ),
    );
  }
}
