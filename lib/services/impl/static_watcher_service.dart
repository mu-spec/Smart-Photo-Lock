import '../../utilities/result.dart';
import '../watcher_service.dart';

/// In-memory [WatcherService] for tests and previews (Phase 5 mobile-QA
/// fix). [running] is mutable; [startCalls]/[stopCalls] count lifecycle
/// invocations.
class StaticWatcherService implements WatcherService {
  bool running = false;
  bool protectionConfigured = false;
  bool engineAvailable = false;
  bool notificationPermissionGranted = true;
  Set<String> protectedPackages = <String>{};
  String? pendingChallenge;
  String? lastError;
  int startCalls = 0;
  int stopCalls = 0;
  int configureCalls = 0;
  int heartbeatCalls = 0;

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

  @override
  Future<Result<void>> configureProtection({
    required bool enabled,
    required Set<String> protectedPackages,
  }) async {
    configureCalls++;
    protectionConfigured = enabled;
    this.protectedPackages = Set<String>.of(protectedPackages);
    return Result.success(null);
  }

  @override
  Future<Result<void>> heartbeat() async {
    heartbeatCalls++;
    engineAvailable = true;
    return Result.success(null);
  }

  @override
  Future<Result<void>> markEngineUnavailable() async {
    engineAvailable = false;
    return Result.success(null);
  }

  @override
  Future<Result<String?>> takePendingChallenge() async {
    final String? pending = pendingChallenge;
    pendingChallenge = null;
    return Result.success(pending);
  }

  @override
  Future<Result<ProtectionEngineHealth>> getHealth() async => Result.success(
        ProtectionEngineHealth(
          protectionConfigured: protectionConfigured,
          serviceRunning: running,
          engineState: !protectionConfigured
              ? ProtectionEngineState.inactive
              : engineAvailable
                  ? ProtectionEngineState.healthy
                  : running
                      ? ProtectionEngineState.recovering
                      : ProtectionEngineState.unavailable,
          notificationPermissionGranted: notificationPermissionGranted,
          lastError: lastError,
        ),
      );
}
