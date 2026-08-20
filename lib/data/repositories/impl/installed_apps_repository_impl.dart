import 'dart:typed_data';

import '../../../services/installed_apps_service.dart';
import '../../../utilities/result.dart';
import '../../models/app_entry.dart';
import '../installed_apps_repository.dart';

/// [InstalledAppsRepository] over an [InstalledAppsService].
///
/// Responsibilities:
///  * normalize labels (fall back to the package name when the system
///    reports an empty label);
///  * exclude Smart App Lock's own package — locking yourself would be
///    nonsense and breaks the UI;
///  * exclude any additionally configured packages;
///  * sort by label (case-insensitive);
///  * cache per [includeSystemApps] flag so repeated list opens are free;
///    [refresh] clears the cache so the foreground monitor can re-poll.
class InstalledAppsRepositoryImpl implements InstalledAppsRepository {
  InstalledAppsRepositoryImpl(
    this._service, {
    String ownPackage = 'com.smartapplock.app',
    List<String> excludedPackages = const <String>[],
  }) : _excluded = Set<String>.from(excludedPackages)..add(ownPackage);

  final InstalledAppsService _service;

  /// Package names never shown (always includes this app's own package —
  /// locking yourself would break the UI).
  final Set<String> _excluded;

  /// Cache per system-apps flag (a flag-specific list is a different
  /// answer).
  final Map<bool, List<AppEntry>> _cache = <bool, List<AppEntry>>{};

  @override
  Future<Result<List<AppEntry>>> getInstalledApps({
    bool includeSystemApps = false,
  }) async {
    final List<AppEntry>? cached = _cache[includeSystemApps];
    if (cached != null) {
      return Result.success(cached);
    }

    final Result<List<AppEntry>> fetched = await _service.getInstalledApps(
      includeSystemApps: includeSystemApps,
    );
    if (fetched.isFailure) {
      return fetched;
    }

    final List<AppEntry> apps = _normalize(fetched.valueOrNull!);
    _cache[includeSystemApps] = apps;
    return Result.success(apps);
  }

  @override
  Future<Result<Uint8List?>> getAppIcon(String packageName) =>
      _service.getAppIcon(packageName);

  @override
  Future<Result<void>> refresh() async {
    _cache.clear();
    // Best-effort re-fetch so the next read is warm; failures here do not
    // break the caller (the next getInstalledApps re-fetches anyway).
    await _service.getInstalledApps(includeSystemApps: true);
    return Result.success(null);
  }

  /// Excludes ineligible packages, normalizes labels and sorts.
  List<AppEntry> _normalize(List<AppEntry> source) {
    final List<AppEntry> apps = source
        .where((AppEntry app) => !_excluded.contains(app.packageName))
        .map(
          (AppEntry app) => app.label.trim().isEmpty
              ? app.copyWith(label: app.packageName)
              : app,
        )
        .toList();
    apps.sort((AppEntry a, AppEntry b) =>
        a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return List<AppEntry>.unmodifiable(apps);
  }
}
