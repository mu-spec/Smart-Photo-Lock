import 'dart:typed_data';

import '../data/models/app_entry.dart';
import '../utilities/result.dart';

/// Bridge to the Android package manager (native side).
///
/// Implemented in Phase 3A:
///  * MethodChannel `smart_app_lock/apps` backed by `PackageManager`
///  * `<queries>` manifest entry so Android 11+ lets us see other apps
///
/// Usage-stats methods are declared by the contract but deliberately not
/// wired yet: they fail closed until the usage-stats phase implements the
/// native side.
abstract interface class InstalledAppsService {
  Future<Result<List<AppEntry>>> getInstalledApps({
    bool includeSystemApps = false,
  });

  /// PNG bytes for the app's launcher icon, or null when the system cannot
  /// provide one (callers fall back to a placeholder icon).
  Future<Result<Uint8List?>> getAppIcon(String packageName);

  /// Most-recently-used apps from the usage-stats backend.
  Future<Result<List<AppEntry>>> getRecentlyUsedApps({int limit = 10});

  /// True when the user granted the Usage Access permission.
  Future<Result<bool>> hasUsageAccess();

  /// Opens the system Usage Access settings screen.
  Future<Result<void>> requestUsageAccess();
}
