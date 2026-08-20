import 'dart:typed_data';

import '../../data/models/app_entry.dart';
import '../../utilities/result.dart';
import '../installed_apps_service.dart';

/// In-memory [InstalledAppsService] for tests, previews and the in-memory
/// [AppContainer].
///
/// Backed by a configurable static list; the same contract as the
/// MethodChannel implementation so repository logic is exercised against
/// identical behavior. Icons resolve to null (callers show their
/// fallback), unless [iconBytesFor] provides PNG bytes for a package.
class StaticInstalledAppsService implements InstalledAppsService {
  StaticInstalledAppsService(
    this._apps, {
    Map<String, Uint8List> iconBytesFor = const <String, Uint8List>{},
    this.usageAccessGranted = true,
  }) : _icons = Map<String, Uint8List>.from(iconBytesFor);

  final List<AppEntry> _apps;
  final Map<String, Uint8List> _icons;

  /// Current usage-access grant state. Mutable so tests can simulate the
  /// system settings screen granting the capability between checks.
  bool usageAccessGranted;

  /// Tracks how often the settings screen was requested (tests assert
  /// the "send user to settings" step actually fired).
  int requestUsageAccessCalls = 0;

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
  Future<Result<Uint8List?>> getAppIcon(String packageName) async =>
      Result.success(_icons[packageName]);

  @override
  Future<Result<List<AppEntry>>> getRecentlyUsedApps({int limit = 10}) async {
    return Result.success(_apps.take(limit).toList(growable: false));
  }

  @override
  Future<Result<bool>> hasUsageAccess() async =>
      Result.success(usageAccessGranted);

  @override
  Future<Result<void>> requestUsageAccess() async {
    requestUsageAccessCalls++;
    return Result.success(null);
  }
}
