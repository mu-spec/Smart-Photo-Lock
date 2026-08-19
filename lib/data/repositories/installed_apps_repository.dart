import '../../utilities/result.dart';
import '../models/app_entry.dart';

/// Source of truth for the installed-apps list.
///
/// Implemented in the app-list phase: wraps the native `InstalledAppsService`
/// (MethodChannel to PackageManager) plus a local cache for labels/icons.
/// The rest of the app depends only on this interface, never on the platform
/// implementation.
abstract interface class InstalledAppsRepository {
  Future<Result<List<AppEntry>>> getInstalledApps({
    bool includeSystemApps = false,
  });

  /// Best-effort refresh of the cached app list (used by the foreground-app
  /// monitor before evaluating rules).
  Future<Result<void>> refresh();
}
