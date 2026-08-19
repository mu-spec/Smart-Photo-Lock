import '../data/models/app_entry.dart';
import '../utilities/result.dart';

/// Bridge to the Android package manager (native side).
///
/// Implemented in the app-list phase:
///  * MethodChannel `smart_app_lock/apps` backed by `PackageManager`
///  * `PACKAGE_USAGE_STATS` permission + `Settings.ACTION_USAGE_ACCESS_SETTINGS`
///    for the "recently used / most launched" data
///  * `<queries>` manifest entry so Android 11+ lets us see other apps
abstract interface class InstalledAppsService {
  Future<Result<List<AppEntry>>> getInstalledApps({
    bool includeSystemApps = false,
  });

  /// Most-recently-used apps from the usage-stats backend.
  Future<Result<List<AppEntry>>> getRecentlyUsedApps({int limit = 10});

  /// True when the user granted the Usage Access permission.
  Future<Result<bool>> hasUsageAccess();

  /// Opens the system Usage Access settings screen.
  Future<Result<void>> requestUsageAccess();
}
