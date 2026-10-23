import '../../utilities/result.dart';
import '../pending_lock_challenge.dart';
import '../watcher_service.dart';
import 'static_native_challenge_contract.dart';

/// In-memory [WatcherService] for tests and previews (Phase 5 mobile-QA
/// fix). [running] is mutable; [startCalls]/[stopCalls] count lifecycle
/// invocations.
///
/// Phase 5 / Milestone 3 — Fix #1 (H-4): when [nativeContract] is bound
/// (see [StaticNativeChallengeContract.bind]), configuration, ticket
/// reads, authorization and revocation go through the exact native
/// contract. In particular, `authorizePackage` needs an exact pending
/// ticket AND an accepted ready handoff. Unbound, the lenient legacy
/// behaviour below is unchanged; for example, it authorizes when no
/// ticket is pending, which native Android never does.
class StaticWatcherService implements WatcherService {
  /// Optional faithful native model shared with [StaticOverlayLockService].
  StaticNativeChallengeContract? nativeContract;

  bool running = false;
  bool protectionConfigured = false;
  bool engineAvailable = false;
  bool notificationPermissionGranted = true;
  Set<String> protectedPackages = <String>{};
  String? pendingChallenge;
  int pendingChallengeGeneration = 1;
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
    nativeContract?.configure(
      enabled: enabled,
      packages: Set<String>.of(protectedPackages),
    );
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
    PendingLockChallenge challenge, {
    Duration sessionWindow = const Duration(minutes: 2),
  }) async {
    authorizePackageCalls++;
    final StaticNativeChallengeContract? native = nativeContract;
    if (native != null) {
      if (!native.authorizePackage(challenge)) {
        return Result.failure(
          StateError('Native watcher rejected authorizePackage.'),
        );
      }
      authorizedPackages.add(challenge.packageName);
      return Result.success(null);
    }
    final String packageName = challenge.packageName;
    if (!protectionConfigured || !protectedPackages.contains(packageName)) {
      return Result.failure(StateError('Package is not protected.'));
    }
    if (pendingChallenge != null &&
        (pendingChallenge != packageName ||
            pendingChallengeGeneration != challenge.generation)) {
      return Result.failure(StateError('Challenge ticket is stale.'));
    }
    authorizedPackages.add(packageName);
    if (pendingChallenge == packageName &&
        pendingChallengeGeneration == challenge.generation) {
      pendingChallenge = null;
    }
    return Result.success(null);
  }

  @override
  Future<Result<void>> revokeAllAuthorizations() async {
    revokeAllAuthorizationsCalls++;
    authorizedPackages.clear();
    nativeContract?.revokeAllAuthorizations();
    return Result.success(null);
  }

  @override
  Future<Result<void>> markEngineUnavailable() async {
    engineAvailable = false;
    return Result.success(null);
  }

  @override
  Future<Result<PendingLockChallenge?>> takePendingChallenge() async {
    final StaticNativeChallengeContract? native = nativeContract;
    if (native != null) {
      return Result.success(native.takePendingChallenge());
    }
    final String? packageName = pendingChallenge;
    return Result.success(
      packageName == null
          ? null
          : PendingLockChallenge(
              packageName: packageName,
              generation: pendingChallengeGeneration,
            ),
    );
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
