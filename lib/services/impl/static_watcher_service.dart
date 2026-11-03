import 'dart:async';

import '../../data/models/app_security_level.dart';
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

  /// Phase 7 / M1 health signals (null = UNKNOWN, as from native).
  bool? accessibilityServiceConnected;
  bool? shieldArmed;
  bool? challengePending;
  bool? backgroundRestricted;
  bool? powerSaveMode;
  bool? ignoringBatteryOptimizations;
  int? sdkInt;

  /// Phase 7 / M2: Settings screens opened via [openProtectionSettings]
  /// (in order) and the simulated outcome (`false` = Android could not
  /// start the screen).
  final List<ProtectionSettingsTarget> openedSettings =
      <ProtectionSettingsTarget>[];
  bool settingsOpenResult = true;

  /// When non-null, [getHealth] fails with this error (bridge failure).
  Object? getHealthError;

  /// When non-null, [getHealth] waits for it (a slow platform channel).
  Completer<void>? getHealthGate;
  int getHealthCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int configureCalls = 0;
  int heartbeatCalls = 0;
  int setGracePeriodCalls = 0;
  int authorizePackageCalls = 0;

  /// Phase 8 / M2 gate: level floor sent with the last `authorizePackage`
  /// per package (null = none sent).
  final Map<String, AppSecurityLevel?> authorizeLevelFloors =
      <String, AppSecurityLevel?>{};
  int revokeAllAuthorizationsCalls = 0;
  Duration gracePeriod = Duration.zero;
  final Set<String> authorizedPackages = <String>{};

  /// Phase 8 / M2 (SIMULATED native): the levels the simulated engine
  /// enforces, resolved like `PolicySnapshotResolver.kt` — legacy keeps
  /// known levels (new → Standard); a valid v1 snapshot applies, holding
  /// any lower level that is not in `authorizedDowngrades`; a malformed
  /// one enforces Critical; an older (session, revision) is stale.
  final Map<String, AppSecurityLevel> securityLevels =
      <String, AppSecurityLevel>{};

  /// Every snapshot received, in order (tests inspect transport).
  final List<ProtectionPolicySnapshot?> receivedPolicies =
      <ProtectionPolicySnapshot?>[];

  /// When non-null, [configureProtection] fails with it and changes
  /// nothing (a bridge or native persistence failure).
  Object? configureError;

  /// When non-null, [configureProtection] waits for it first.
  Completer<void>? configureGate;

  String? _lastSession;
  int _lastRevision = -1;

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
  Future<Result<ProtectionPolicyAck>> configureProtection({
    required bool enabled,
    required Set<String> protectedPackages,
    ProtectionPolicySnapshot? policy,
  }) async {
    configureCalls++;
    receivedPolicies.add(policy);
    final Completer<void>? gate = configureGate;
    if (gate != null) await gate.future;
    final Object? error = configureError;
    if (error != null) return Result.failure(error);
    if (policy != null &&
        policy.session == _lastSession &&
        policy.revision <= _lastRevision) {
      return Result.failure(StateError('stale protection snapshot'));
    }
    final ProtectionPolicyAck ack = _resolveLevels(protectedPackages, policy);
    if (policy != null) {
      _lastSession = policy.session;
      _lastRevision = policy.revision;
    }
    protectionConfigured = enabled;
    this.protectedPackages = Set<String>.of(protectedPackages);
    authorizedPackages.retainAll(this.protectedPackages);
    if (!enabled) authorizedPackages.clear();
    nativeContract?.configure(
      enabled: enabled,
      packages: Set<String>.of(protectedPackages),
    );
    return Result.success(ack);
  }

  ProtectionPolicyAck _resolveLevels(
    Set<String> packages,
    ProtectionPolicySnapshot? policy,
  ) {
    final Map<String, AppSecurityLevel> previous =
        Map<String, AppSecurityLevel>.of(securityLevels);
    final Map<String, AppSecurityLevel> next = <String, AppSecurityLevel>{};
    final Set<String> held = <String>{};
    ProtectionPolicyStatus status;
    if (policy == null) {
      status = ProtectionPolicyStatus.legacy;
      for (final String p in packages) {
        next[p] = previous[p] ?? AppSecurityLevel.standard;
      }
    } else if (policy.levels.keys.toSet().length == packages.length &&
        policy.levels.keys.toSet().containsAll(packages)) {
      status = ProtectionPolicyStatus.applied;
      for (final String p in packages) {
        final AppSecurityLevel requested = policy.levels[p]!;
        final AppSecurityLevel? old = previous[p];
        if (old != null &&
            old.isStricterThan(requested) &&
            !policy.authorizedDowngrades.contains(p)) {
          next[p] = old;
          held.add(p);
        } else {
          next[p] = requested;
        }
      }
    } else {
      status = ProtectionPolicyStatus.invalid;
      for (final String p in packages) {
        next[p] = AppSecurityLevel.critical;
      }
    }
    for (final MapEntry<String, AppSecurityLevel> e in next.entries) {
      final AppSecurityLevel? old = previous[e.key];
      if (old != null && e.value.isStricterThan(old)) {
        authorizedPackages.remove(e.key); // raised → session revoked
      }
    }
    securityLevels
      ..clear()
      ..addAll(next);
    return ProtectionPolicyAck(
      status: status,
      effectiveLevels: Map<String, AppSecurityLevel>.unmodifiable(next),
      heldDowngrades: Set<String>.unmodifiable(held),
    );
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
    AppSecurityLevel? securityLevel,
  }) async {
    authorizePackageCalls++;
    authorizeLevelFloors[challenge.packageName] = securityLevel;
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
  Future<Result<bool>> openProtectionSettings(
    ProtectionSettingsTarget target,
  ) async {
    openedSettings.add(target);
    return Result.success(settingsOpenResult);
  }

  @override
  Future<Result<ProtectionEngineHealth>> getHealth() async {
    getHealthCalls++;
    final Completer<void>? gate = getHealthGate;
    if (gate != null) await gate.future;
    final Object? error = getHealthError;
    if (error != null) {
      return Result.failure(error);
    }
    return Result.success(
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
        accessibilityServiceConnected: accessibilityServiceConnected,
        shieldArmed: shieldArmed,
        challengePending: challengePending,
        backgroundRestricted: backgroundRestricted,
        powerSaveMode: powerSaveMode,
        ignoringBatteryOptimizations: ignoringBatteryOptimizations,
        sdkInt: sdkInt,
      ),
    );
  }
}
