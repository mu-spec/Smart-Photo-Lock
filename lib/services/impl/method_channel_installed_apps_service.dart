import 'package:flutter/services.dart';

import '../../data/models/app_entry.dart';
import '../../utilities/result.dart';
import '../installed_apps_service.dart';

/// Production [InstalledAppsService] backed by the native PackageManager.
///
/// Wire format (channel `smart_app_lock/apps`):
///  * method `getInstalledApps`, arguments `{includeSystemApps: bool}`
///  * result: a list of maps with keys
///    `packageName` (String), `label` (String), `isSystemApp` (bool),
///    `versionName` (String?)
///
/// The native side returns only **launchable** applications (those with a
/// MAIN/LAUNCHER intent) — i.e. exactly the apps that are appropriate for
/// App Lock selection — and never returns this app's own package.
///
/// Usage-access methods are declared by the contract but deliberately not
/// wired yet: they fail closed until the usage-stats phase implements the
/// native side, so callers can safely feature-gate on the failure.
class MethodChannelInstalledAppsService implements InstalledAppsService {
  MethodChannelInstalledAppsService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('smart_app_lock/apps');

  static const String _channelName = 'smart_app_lock/apps';

  final MethodChannel _channel;

  @override
  Future<Result<List<AppEntry>>> getInstalledApps({
    bool includeSystemApps = false,
  }) async {
    try {
      final List<dynamic>? raw = await _channel
          .invokeMethod<List<dynamic>>('getInstalledApps', <String, dynamic>{
        'includeSystemApps': includeSystemApps,
      });
      if (raw == null) {
        return Result.success(const <AppEntry>[]);
      }
      final List<AppEntry> apps = raw
          .whereType<Map<dynamic, dynamic>>()
          .map((Map<dynamic, dynamic> map) => AppEntry.fromJson(
                map.cast<String, dynamic>(),
              ))
          .toList();
      return Result.success(apps);
    } on PlatformException catch (e) {
      return Result.failure(e);
    } on MissingPluginException catch (e) {
      // No native handler (e.g. running on a host without the plugin) —
      // fail closed, never fabricate an app list.
      return Result.failure(e);
    }
  }

  @override
  Future<Result<List<AppEntry>>> getRecentlyUsedApps({int limit = 10}) async {
    // Usage-stats backend arrives in a later phase; fail closed.
    return Result.failure(
      StateError('Usage access is not implemented yet.'),
    );
  }

  @override
  Future<Result<bool>> hasUsageAccess() async {
    return Result.failure(
      StateError('Usage access is not implemented yet.'),
    );
  }

  @override
  Future<Result<void>> requestUsageAccess() async {
    return Result.failure(
      StateError('Usage access is not implemented yet.'),
    );
  }

  /// The channel name, exported for tests.
  static String get channelName => _channelName;
}
