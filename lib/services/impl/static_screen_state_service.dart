import 'dart:async';

import '../../utilities/result.dart';
import '../screen_state_service.dart';

/// In-memory [ScreenStateService] for tests and previews (Phase 5K).
///
/// [emitScreenOff] / [emitScreenOn] simulate the device's screen-state
/// broadcasts; [screenOffCount] / [screenOnCount] track deliveries.
class StaticScreenStateService implements ScreenStateService {
  final StreamController<Result<ScreenStateEvent>> _events =
      StreamController<Result<ScreenStateEvent>>.broadcast();

  int screenOffCount = 0;
  int screenOnCount = 0;

  /// Test hook: simulates the screen turning off.
  void emitScreenOff() {
    screenOffCount++;
    _events.add(Result.success(ScreenStateEvent.screenOff));
  }

  /// Test hook: simulates the screen turning back on.
  void emitScreenOn() {
    screenOnCount++;
    _events.add(Result.success(ScreenStateEvent.screenOn));
  }

  @override
  Stream<Result<ScreenStateEvent>> get events => _events.stream;
}
