import 'dart:async';
import 'dart:math';

import '../data/models/app_security_level.dart';
import '../data/models/protected_app.dart';
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
///
/// Phase 8 / M2: each call sends ONE snapshot (packages + per-app levels,
/// atomically written natively) tagged with this isolate's [session] and an
/// increasing revision, so native ignores a stale/out-of-order one. Calls
/// are serialized. The last native acknowledgement is kept so the app can
/// tell when native enforces a different (stricter) level than persisted.
class ProtectionBootstrap {
  ProtectionBootstrap({
    required ProtectedAppsRepository protectedApps,
    required CredentialManager credentials,
    required WatcherService watcher,
    String? session,
  })  : _protectedApps = protectedApps,
        _credentials = credentials,
        _watcher = watcher,
        session = session ?? _newSession();

  final ProtectedAppsRepository _protectedApps;
  final CredentialManager _credentials;
  final WatcherService _watcher;

  /// Random per-instance id of the snapshot stream (not a secret).
  final String session;
  int _revision = 0;
  Future<void> _tail = Future<void>.value();
  ProtectionPolicyAck? _lastAck;

  static String _newSession() {
    final Random random = Random.secure();
    return List<String>.generate(
      4,
      (_) => random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0'),
    ).join();
  }

  /// The last applied native acknowledgement (null until one succeeds).
  ProtectionPolicyAck? get lastPolicyAck => _lastAck;

  /// Phase 8 / M2: the level native last confirmed it enforces for
  /// [packageName], or null when unknown. Used as a floor: the effective
  /// Dart level is never weaker than this.
  AppSecurityLevel? nativeLevelFor(String packageName) =>
      _lastAck?.effectiveLevels[packageName];

  /// Sends the current persisted state to native. [authorizedDowngrades]
  /// lists packages whose lower level was JUST confirmed through the CR-2
  /// credential gate; native holds any other lower level.
  Future<Result<ProtectionBootstrapResult>> synchronize({
    Set<String> authorizedDowngrades = const <String>{},
  }) {
    final Future<void> previous = _tail;
    final Completer<void> done = Completer<void>();
    _tail = done.future;
    return previous
        .then((_) => _synchronize(authorizedDowngrades))
        .whenComplete(done.complete);
  }

  Future<Result<ProtectionBootstrapResult>> _synchronize(
    Set<String> authorizedDowngrades,
  ) async {
    final credentialResult = await _credentials.status();
    if (credentialResult.isFailure) {
      return Result.failure(credentialResult.errorOrNull!);
    }
    final appsResult = await _protectedApps.getProtectedApps();
    if (appsResult.isFailure) {
      return Result.failure(appsResult.errorOrNull!);
    }
    final List<ProtectedApp> apps = appsResult.valueOrNull!;
    final packages = apps.map((app) => app.packageName).toSet();
    final bool configured =
        credentialResult.valueOrNull!.hasAnyCredential && packages.isNotEmpty;
    final configuredResult = await _watcher.configureProtection(
      enabled: configured,
      protectedPackages: packages,
      policy: ProtectionPolicySnapshot(
        levels: <String, AppSecurityLevel>{
          for (final ProtectedApp app in apps)
            app.packageName: app.securityLevel,
        },
        session: session,
        revision: ++_revision,
        authorizedDowngrades: authorizedDowngrades.intersection(packages),
      ),
    );
    if (configuredResult.isFailure) {
      return Result.failure(configuredResult.errorOrNull!);
    }
    final ProtectionPolicyAck ack = configuredResult.valueOrNull!;
    if (ack.status != ProtectionPolicyStatus.unknown) _lastAck = ack;
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
