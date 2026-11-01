import '../utilities/result.dart';
import 'pending_lock_challenge.dart';

enum ProtectionEngineState { inactive, healthy, recovering, unavailable }

class ProtectionEngineHealth {
  const ProtectionEngineHealth({
    required this.protectionConfigured,
    required this.serviceRunning,
    required this.engineState,
    required this.notificationPermissionGranted,
    this.lastError,
    this.accessibilityServiceConnected,
    this.shieldArmed,
    this.challengePending,
    this.backgroundRestricted,
    this.powerSaveMode,
    this.ignoringBatteryOptimizations,
    this.sdkInt,
  });

  const ProtectionEngineHealth.inactive()
      : protectionConfigured = false,
        serviceRunning = false,
        engineState = ProtectionEngineState.inactive,
        notificationPermissionGranted = true,
        lastError = null,
        accessibilityServiceConnected = null,
        shieldArmed = null,
        challengePending = null,
        backgroundRestricted = null,
        powerSaveMode = null,
        ignoringBatteryOptimizations = null,
        sdkInt = null;

  factory ProtectionEngineHealth.fromMap(Map<dynamic, dynamic> map) {
    final String rawState = map['engineState'] as String? ?? 'unavailable';
    return ProtectionEngineHealth(
      protectionConfigured: map['protectionConfigured'] as bool? ?? false,
      serviceRunning: map['serviceRunning'] as bool? ?? false,
      engineState: ProtectionEngineState.values.firstWhere(
        (ProtectionEngineState state) => state.name == rawState,
        orElse: () => ProtectionEngineState.unavailable,
      ),
      notificationPermissionGranted:
          map['notificationPermissionGranted'] as bool? ?? true,
      lastError: map['lastError'] as String?,
      accessibilityServiceConnected: _optionalBool(
        map['accessibilityServiceConnected'],
      ),
      shieldArmed: _optionalBool(map['shieldArmed']),
      challengePending: _optionalBool(map['challengePending']),
      backgroundRestricted: _optionalBool(map['backgroundRestricted']),
      powerSaveMode: _optionalBool(map['powerSaveMode']),
      ignoringBatteryOptimizations: _optionalBool(
        map['ignoringBatteryOptimizations'],
      ),
      sdkInt: map['sdkInt'] is int ? map['sdkInt'] as int : null,
    );
  }

  /// Phase 7 / M1: an absent or malformed signal is UNKNOWN (null), never
  /// a fabricated healthy value.
  static bool? _optionalBool(Object? value) => value is bool ? value : null;

  final bool protectionConfigured;
  final bool serviceRunning;
  final ProtectionEngineState engineState;
  final bool notificationPermissionGranted;
  final String? lastError;

  // Phase 7 / M1 — additive, observational health signals (null = UNKNOWN:
  // unsupported API level, a failed platform read, or an older native build).

  /// Android currently has the detection Accessibility service BOUND
  /// (distinct from "enabled in Settings").
  final bool? accessibilityServiceConnected;

  /// The pre-armed native shield window is attached.
  final bool? shieldArmed;

  /// A native pending challenge ticket exists (enforcement in progress).
  final bool? challengePending;

  /// `ActivityManager.isBackgroundRestricted()` (API 28+). OEM power
  /// managers are not reflected by this API.
  final bool? backgroundRestricted;

  /// `PowerManager.isPowerSaveMode()` (Battery Saver).
  final bool? powerSaveMode;

  /// `PowerManager.isIgnoringBatteryOptimizations()` for this app.
  final bool? ignoringBatteryOptimizations;

  /// `Build.VERSION.SDK_INT` reported by native code.
  final int? sdkInt;
}

/// Phase 7 / M2: the only Android Settings screens the health dashboard
/// may open directly (native allowlist `ProtectionSettingsTargets`).
/// Overlay, Accessibility and Usage Access use their existing setup screens.
enum ProtectionSettingsTarget {
  /// This app's notification settings (App info below API 26).
  notifications('notifications'),

  /// This app's App info screen (battery / background controls live here).
  appDetails('app_details'),

  /// The system Battery Saver screen.
  batterySaver('battery_saver');

  const ProtectionSettingsTarget(this.id);

  /// Wire identifier sent to native code.
  final String id;
}

/// Bridge to the native lifecycle and recovery watcher.
///
/// Native code owns the earliest detector-to-shield transition even while
/// Dart is healthy. Dart owns credential decisions and grants only the
/// short-lived package authorization produced by successful authentication.
abstract interface class WatcherService {
  /// Starts the watcher foreground service. Notification permission is
  /// optional on API 33+: denial affects visibility, not service startup.
  Future<Result<bool>> start();

  /// Stops the watcher foreground service.
  Future<Result<bool>> stop();

  /// The native watcher's running state.
  Future<Result<bool>> isRunning();

  /// Persists the minimum non-secret bootstrap state needed by the native
  /// recovery engine. Package names are already persisted by the protected
  /// apps repository; no credential material crosses this bridge.
  Future<Result<void>> configureProtection({
    required bool enabled,
    required Set<String> protectedPackages,
  });

  /// Liveness signal from the Dart enforcement pipeline. The native watcher
  /// falls back to recovery detection when heartbeats stop.
  Future<Result<void>> heartbeat();

  /// Synchronizes the immediate/grace re-lock policy used by native early
  /// enforcement. No credential material crosses this boundary.
  Future<Result<void>> setGracePeriod(Duration period);

  /// Mirrors a temporary package authorization after explicit successful
  /// authentication. Native state is process-local and disappears on reboot
  /// or process death, preserving fail-closed recovery.
  Future<Result<void>> authorizePackage(
    PendingLockChallenge challenge, {
    Duration sessionWindow = const Duration(minutes: 2),
  });

  /// Immediately invalidates every native authorization (screen-off path).
  Future<Result<void>> revokeAllAuthorizations();

  /// Marks an orderly Flutter-engine teardown. This never disables desired
  /// protection; it hands enforcement back to the native recovery watcher.
  Future<Result<void>> markEngineUnavailable();

  /// Reads a package queued by native recovery after process death/reboot.
  /// The native shield latch remains set until the rendered challenge handoff.
  Future<Result<PendingLockChallenge?>> takePendingChallenge();

  /// Current native enforcement health for truthful baseline UI.
  Future<Result<ProtectionEngineHealth>> getHealth();

  /// Phase 7 / M2: opens one allowlisted Android Settings screen after an
  /// explicit user tap. Resolves `true` when Android started the screen.
  /// Grants nothing and changes no protection state; only fresh health
  /// signals can show whether the user changed the setting.
  Future<Result<bool>> openProtectionSettings(ProtectionSettingsTarget target);
}
