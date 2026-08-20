import '../../data/models/app_entry.dart';
import '../../utilities/result.dart';
import '../installed_apps_service.dart';

/// In-memory [InstalledAppsService] for tests, previews and the in-memory
/// [AppContainer].
///
/// Backed by a configurable static list; the same contract as the
/// MethodChannel implementation so repository logic is exercised against
/// identical behavior (filtering by system flag, usage-access stubs).
class StaticInstalledAppsService implements InstalledAppsService {
  StaticInstalledAppsService(this._apps);

  final List<AppEntry> _apps;

  /// Tracks calls so tests can assert caching behavior of consumers.
  int getInstalledAppsCalls = 0;

  @override
  Future<Result<List<AppEntry>>> getInstalledApps({
    bool includeSystemApps = false,
  }) async {
    getInstalledAppsCalls++;
    return Result.success(
      _apps
          .where((AppEntry app) => includeSystemApps || !app.isSystemApp)
          .toList(growable: false),
    );
  }

  @override
  Future<Result<List<AppEntry>>> getRecentlyUsedApps({int limit = 10}) async {
    return Result.success(_apps.take(limit).toList(growable: false));
  }

  @override
  Future<Result<bool>> hasUsageAccess() async => Result.success(true);

  @override
  Future<Result<void>> requestUsageAccess() async => Result.success(null);
}
