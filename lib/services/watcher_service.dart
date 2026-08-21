import '../utilities/result.dart';

/// Bridge to the watcher foreground service (Phase 5 mobile-QA fix).
///
/// The lock engine's pipeline (foreground polling, the accessibility
/// listener, the trigger and the challenge host) lives in the Flutter
/// isolate. Android freezes or kills that isolate when the app is
/// backgrounded. The watcher foreground service anchors the process so
/// detection keeps running and protected apps are challenged the moment
/// they open — this bridge starts/stops it alongside the lock engine.
abstract interface class WatcherService {
  /// Starts the watcher foreground service (requests POST_NOTIFICATIONS
  /// on API 33+ so the protection indicator is visible). True when the
  /// start request succeeded.
  Future<Result<bool>> start();

  /// Stops the watcher foreground service.
  Future<Result<bool>> stop();

  /// The native watcher's running state.
  Future<Result<bool>> isRunning();
}
