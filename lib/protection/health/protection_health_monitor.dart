import 'dart:async';

import '../../data/models/protected_app.dart';
import '../../data/repositories/protected_apps_repository.dart';
import '../../data/storage/preferences_store.dart';
import '../../security/credentials/auth_type.dart';
import '../../security/credentials/biometric_options.dart';
import '../../security/credentials/credential_manager.dart';
import '../../security/credentials/credential_state.dart';
import '../../services/accessibility_lock_service.dart';
import '../../services/biometric_service.dart';
import '../../services/installed_apps_service.dart';
import '../../services/overlay_lock_service.dart';
import '../../services/watcher_service.dart';
import '../../utilities/result.dart';
import 'protection_health_engine.dart';

/// Phase 7 / Milestone 1 — collects [HealthSignals] from the live services
/// and evaluates them with [ProtectionHealthEngine].
///
/// Observational by construction. It only calls READ methods:
/// `CredentialManager.status`, `ProtectedAppsRepository.getProtectedApps`,
/// the three capability probes, `PreferencesStore.wasCapabilityEverGranted`,
/// `WatcherService.getHealth` and the biometric capability queries. It never
/// calls `ProtectionBootstrap.synchronize` (which configures and starts the
/// watcher), never authorizes or revokes, never touches tickets or the
/// shield, never prompts for biometrics and never records grant history.
///
/// Refresh boundaries (no timer, no polling, no background work):
///  * [refresh] runs one collection; concurrent calls share it;
///  * every probe has a [probeTimeout] → a hung bridge reads as UNKNOWN;
///  * [latest] re-applies the age rule, so an un-refreshed report can never
///    stay SECURE for longer than [maxAge] (it becomes ATTENTION REQUIRED
///    with `health_snapshot_stale`);
///  * callers decide WHEN to refresh (Phase 7 / M2 dashboard display,
///    Phase 7 / M3 return-from-Settings refresh).
class ProtectionHealthMonitor {
  ProtectionHealthMonitor({
    required ProtectedAppsRepository protectedApps,
    required CredentialManager credentials,
    required InstalledAppsService installedApps,
    required AccessibilityLockService accessibility,
    required OverlayLockService overlay,
    required WatcherService watcher,
    required PreferencesStore preferences,
    required BiometricService biometrics,
    DateTime Function()? now,
    this.maxAge = ProtectionHealthEngine.defaultMaxAge,
    this.probeTimeout = const Duration(seconds: 3),
  })  : _protectedApps = protectedApps,
        _credentials = credentials,
        _installedApps = installedApps,
        _accessibility = accessibility,
        _overlay = overlay,
        _watcher = watcher,
        _preferences = preferences,
        _biometrics = biometrics,
        _now = now ?? DateTime.now;

  final ProtectedAppsRepository _protectedApps;
  final CredentialManager _credentials;
  final InstalledAppsService _installedApps;
  final AccessibilityLockService _accessibility;
  final OverlayLockService _overlay;
  final WatcherService _watcher;
  final PreferencesStore _preferences;
  final BiometricService _biometrics;
  final DateTime Function() _now;

  /// A snapshot older than this cannot support SECURE.
  final Duration maxAge;

  /// Upper bound for each individual platform/storage read.
  final Duration probeTimeout;

  final StreamController<ProtectionHealthReport> _changes =
      StreamController<ProtectionHealthReport>.broadcast();

  Future<ProtectionHealthReport>? _inFlight;
  ProtectionHealthReport? _last;
  String? _lastSignature;

  /// Emits a report only when its [ProtectionHealthReport.signature] (state,
  /// issues or component statuses — including biometric availability)
  /// differs from the previously emitted one.
  Stream<ProtectionHealthReport> get changes => _changes.stream;

  /// The most recent observation re-evaluated against the current time, or
  /// null before the first [refresh]. Performs no probes.
  ProtectionHealthReport? latest() {
    final ProtectionHealthReport? last = _last;
    if (last == null) return null;
    return ProtectionHealthEngine.reevaluate(
      last,
      now: _now(),
      maxAge: maxAge,
    );
  }

  /// Collects fresh signals and evaluates them. Concurrent calls share one
  /// collection.
  Future<ProtectionHealthReport> refresh() =>
      _inFlight ??= _collect().whenComplete(() => _inFlight = null);

  Future<void> dispose() => _changes.close();

  Future<ProtectionHealthReport> _collect() async {
    final DateTime observedAt = _now();

    final CredentialState? credentials = await _read(_credentials.status);
    final List<ProtectedApp>? apps =
        await _read(_protectedApps.getProtectedApps);
    final bool? configured;
    if (credentials != null && apps != null) {
      configured = credentials.hasAnyCredential && apps.isNotEmpty;
    } else if (credentials != null && !credentials.hasAnyCredential) {
      configured = false;
    } else if (apps != null && apps.isEmpty) {
      configured = false;
    } else {
      configured = null;
    }

    final bool? usage = await _read(_installedApps.hasUsageAccess);
    final bool? accessibility = await _read(_accessibility.isServiceEnabled);
    final bool? overlay = await _read(_overlay.canDrawOverlays);
    final ProtectionEngineHealth? native = await _read(_watcher.getHealth);

    final bool? biometricEnabled = credentials?.hasEnrolled(AuthType.biometric);
    // Phase 7 / M2: with biometric unlock turned off in the app the engine
    // reports `disabled_by_user` whatever the hardware says, so the
    // platform biometric probes are skipped (no needless call per refresh).
    final bool probeBiometrics = biometricEnabled != false;
    final bool? hardware =
        probeBiometrics ? await _read(_biometrics.isSupported) : null;
    final Set<BiometricKind>? kinds =
        probeBiometrics ? await _read(_biometrics.availableKinds) : null;

    final HealthSignals signals = HealthSignals(
      observedAt: observedAt,
      protectionConfigured: configured,
      credentialConfigured: credentials?.hasAnyCredential,
      hasProtectedApps: apps?.isNotEmpty,
      nativeProtectionEnabled: native?.protectionConfigured,
      overlayGranted: overlay,
      overlayEverGranted: overlay == false && await _everGranted('overlay'),
      accessibilityEnabled: accessibility,
      accessibilityEverGranted:
          accessibility == false && await _everGranted('accessibility'),
      accessibilityConnected: native?.accessibilityServiceConnected,
      usageAccessGranted: usage,
      usageAccessEverGranted:
          usage == false && await _everGranted('usageAccess'),
      nativeHealthAvailable: native != null,
      watcherRunning: native?.serviceRunning,
      watcherLastError: native?.lastError,
      shieldArmed: native?.shieldArmed,
      notificationsGranted: native?.notificationPermissionGranted,
      backgroundRestricted: native?.backgroundRestricted,
      sdkInt: native?.sdkInt,
      powerSaveMode: native?.powerSaveMode,
      ignoringBatteryOptimizations: native?.ignoringBatteryOptimizations,
      biometricUnlockEnabled: biometricEnabled,
      biometricHardwarePresent: hardware,
      biometricEnrolled: kinds?.contains(BiometricKind.strong),
    );

    final ProtectionHealthReport report = ProtectionHealthEngine.evaluate(
      signals,
      now: _now(),
      maxAge: maxAge,
    );
    _last = report;
    final String signature = report.signature;
    if (signature != _lastSignature && !_changes.isClosed) {
      _lastSignature = signature;
      _changes.add(report);
    }
    return report;
  }

  /// One bounded read: failure, exception or timeout → null (UNKNOWN).
  Future<T?> _read<T>(Future<Result<T>> Function() read) async {
    try {
      final Result<T> result = await read().timeout(probeTimeout);
      return result.isSuccess ? result.valueOrNull : null;
    } catch (_) {
      return null;
    }
  }

  /// Read-only grant history (never recorded here). A failed read counts
  /// as "never granted", which only changes the cause shown, not severity.
  Future<bool> _everGranted(String kind) async {
    try {
      return await _preferences
          .wasCapabilityEverGranted(kind)
          .timeout(probeTimeout);
    } catch (_) {
      return false;
    }
  }
}
