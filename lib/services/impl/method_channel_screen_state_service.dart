import 'package:flutter/services.dart';

import '../../utilities/result.dart';
import '../screen_state_service.dart';

/// Production [ScreenStateService] over the native
/// `smart_app_lock/screen_state` EventChannel (Phase 5K).
///
/// The native side relays `ACTION_SCREEN_OFF` / `ACTION_SCREEN_ON`
/// broadcasts as `screen_off` / `screen_on` payloads while a listener
/// is attached. Fail-closed: an unavailable event channel yields an
/// empty stream; unknown payloads and channel errors surface as
/// [Result.failure] events — never fabricated screen states.
class MethodChannelScreenStateService implements ScreenStateService {
  MethodChannelScreenStateService({EventChannel? channel})
      : _channel = channel ??
            const EventChannel('smart_app_lock/screen_state');

  final EventChannel _channel;

  @override
  Stream<Result<ScreenStateEvent>> get events {
    Stream<Result<ScreenStateEvent>> stream;
    try {
      stream = _channel.receiveBroadcastStream().map(
            (dynamic event) => switch (event) {
              'screen_off' => Result.success(ScreenStateEvent.screenOff),
              'screen_on' => Result.success(ScreenStateEvent.screenOn),
              _ => Result.failure(
                  StateError('Unknown screen-state payload: $event'),
                ),
            },
          );
    } on MissingPluginException {
      return const Stream<Result<ScreenStateEvent>>.empty();
    }
    return stream.handleError(
      (Object error) => Result<ScreenStateEvent>.failure(error),
    );
  }
}
