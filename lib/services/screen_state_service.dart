import '../utilities/result.dart';

/// A device screen-state transition (Phase 5K).
enum ScreenStateEvent {
  /// The display turned off — the re-lock trigger.
  screenOff,

  /// The display turned back on.
  screenOn,
}

/// Bridge to the Android screen-state broadcasts
/// (`ACTION_SCREEN_OFF` / `ACTION_SCREEN_ON`), received through a
/// runtime-registered receiver — the precise "screen turned off"
/// signal that lifecycle pauses cannot provide (launching a protected
/// app itself pauses Smart App Lock, so lifecycle-only re-lock would
/// revoke every fresh session instantly).
abstract interface class ScreenStateService {
  /// Emits [ScreenStateEvent]s as they happen. Fail-closed: channel
  /// problems — including a missing native handler — surface as
  /// [Result.failure] events (never fabricated screen states).
  Stream<Result<ScreenStateEvent>> get events;
}
