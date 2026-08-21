import '../../utilities/result.dart';
import '../watcher_service.dart';

/// In-memory [WatcherService] for tests and previews (Phase 5 mobile-QA
/// fix). [running] is mutable; [startCalls]/[stopCalls] count lifecycle
/// invocations.
class StaticWatcherService implements WatcherService {
  bool running = false;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<Result<bool>> start() async {
    startCalls++;
    running = true;
    return Result.success(true);
  }

  @override
  Future<Result<bool>> stop() async {
    stopCalls++;
    running = false;
    return Result.success(true);
  }

  @override
  Future<Result<bool>> isRunning() async => Result.success(running);
}
