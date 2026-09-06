import '../data/repositories/protected_apps_repository.dart';
import '../security/credentials/credential_manager.dart';
import '../services/watcher_service.dart';
import '../utilities/result.dart';

class ProtectionBootstrapResult {
  const ProtectionBootstrapResult({
    required this.configured,
    required this.health,
  });

  final bool configured;
  final ProtectionEngineHealth health;
}

/// Synchronizes authoritative Dart persistence into the minimal native
/// bootstrap store used after process death and reboot.
///
/// A repository/decryption failure never overwrites a previously enabled
/// native configuration. That preserves fail-closed recovery instead of
/// converting an unreadable security state into "protection disabled".
class ProtectionBootstrap {
  ProtectionBootstrap({
    required ProtectedAppsRepository protectedApps,
    required CredentialManager credentials,
    required WatcherService watcher,
  })  : _protectedApps = protectedApps,
        _credentials = credentials,
        _watcher = watcher;

  final ProtectedAppsRepository _protectedApps;
  final CredentialManager _credentials;
  final WatcherService _watcher;

  Future<Result<ProtectionBootstrapResult>> synchronize() async {
    final credentialResult = await _credentials.status();
    if (credentialResult.isFailure) {
      return Result.failure(credentialResult.errorOrNull!);
    }
    final appsResult = await _protectedApps.getProtectedApps();
    if (appsResult.isFailure) {
      return Result.failure(appsResult.errorOrNull!);
    }
    final packages = appsResult.valueOrNull!
        .map((app) => app.packageName)
        .toSet();
    final bool configured =
        credentialResult.valueOrNull!.hasAnyCredential && packages.isNotEmpty;
    final configuredResult = await _watcher.configureProtection(
      enabled: configured,
      protectedPackages: packages,
    );
    if (configuredResult.isFailure) {
      return Result.failure(configuredResult.errorOrNull!);
    }
    final running = await _watcher.isRunning();
    if (running.isFailure) {
      return Result.failure(running.errorOrNull!);
    }
    Result<bool>? lifecycle;
    if (configured && running.valueOrNull != true) {
      lifecycle = await _watcher.start();
    } else if (!configured && running.valueOrNull == true) {
      lifecycle = await _watcher.stop();
    }
    if (lifecycle != null &&
        (lifecycle.isFailure || lifecycle.valueOrNull != true)) {
      return Result.failure(
        lifecycle.errorOrNull ?? StateError('Watcher lifecycle failed.'),
      );
    }
    if (configured) {
      final heartbeat = await _watcher.heartbeat();
      if (heartbeat.isFailure) {
        return Result.failure(heartbeat.errorOrNull!);
      }
    }
    final health = await _watcher.getHealth();
    if (health.isFailure) {
      return Result.failure(health.errorOrNull!);
    }
    return Result.success(
      ProtectionBootstrapResult(
        configured: configured,
        health: health.valueOrNull!,
      ),
    );
  }
}
