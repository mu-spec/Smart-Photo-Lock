import '../utilities/result.dart';

enum ProtectionEngineState { inactive, healthy, recovering, unavailable }

class ProtectionEngineHealth {
  const ProtectionEngineHealth({
    required this.protectionConfigured,
    required this.serviceRunning,
    required this.engineState,
    required this.notificationPermissionGranted,
    this.lastError,
  });

  const ProtectionEngineHealth.inactive()
      : protectionConfigured = false,
        serviceRunning = false,
        engineState = ProtectionEngineState.inactive,
        notificationPermissionGranted = true,
        lastError = null;

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
    );
  }

  final bool protectionConfigured;
  final bool serviceRunning;
  final ProtectionEngineState engineState;
  final bool notificationPermissionGranted;
  final String? lastError;
}

/// Bridge to the native lifecycle and recovery watcher.
///
/// Dart owns normal enforcement while its heartbeat is healthy. If the
/// isolate stops, the native watcher detects protected packages, raises a
/// touch-blocking shield, and rebuilds the Flutter authentication activity.
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

  /// Marks an orderly Flutter-engine teardown. This never disables desired
  /// protection; it hands enforcement back to the native recovery watcher.
  Future<Result<void>> markEngineUnavailable();

  /// Consumes a package queued by native recovery after process death/reboot.
  Future<Result<String?>> takePendingChallenge();

  /// Current native enforcement health for truthful baseline UI.
  Future<Result<ProtectionEngineHealth>> getHealth();
}
