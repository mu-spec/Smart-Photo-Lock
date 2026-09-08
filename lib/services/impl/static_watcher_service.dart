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
  int setGracePeriodCalls = 0;
  int authorizePackageCalls = 0;
  int revokeAllAuthorizationsCalls = 0;
  Duration gracePeriod = Duration.zero;
  final Set<String> authorizedPackages = <String>{};

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
    authorizedPackages.retainAll(this.protectedPackages);
    if (!enabled) authorizedPackages.clear();
    return Result.success(null);
  }

  @override
  Future<Result<void>> heartbeat() async {
    heartbeatCalls++;
    engineAvailable = true;
    return Result.success(null);
  }

  @override
  Future<Result<void>> setGracePeriod(Duration period) async {
    setGracePeriodCalls++;
    gracePeriod = period.isNegative ? Duration.zero : period;
    return Result.success(null);
  }

  @override
  Future<Result<void>> authorizePackage(
    String packageName, {
    Duration sessionWindow = const Duration(minutes: 2),
  }) async {
    authorizePackageCalls++;
    if (!protectionConfigured || !protectedPackages.contains(packageName)) {
      return Result.failure(StateError('Package is not protected.'));
    }
    authorizedPackages.add(packageName);
    if (pendingChallenge == packageName) pendingChallenge = null;
    return Result.success(null);
  }

  @override
  Future<Result<void>> revokeAllAuthorizations() async {
    revokeAllAuthorizationsCalls++;
    authorizedPackages.clear();
    return Result.success(null);
  }

  @override
  Future<Result<void>> markEngineUnavailable() async {
    engineAvailable = false;
    return Result.success(null);
  }

  @override
  Future<Result<String?>> takePendingChallenge() async {
    return Result.success(pendingChallenge);
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
