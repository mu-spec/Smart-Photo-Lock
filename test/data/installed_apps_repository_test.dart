import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/data/repositories/impl/installed_apps_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/installed_apps_repository.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/installed_apps_service.dart';
import 'package:smart_app_lock/utilities/result.dart';

/// Phase 3A: the discovery repository filters, sorts, caches and refreshes
/// exactly as the App Lock selection list needs.
void main() {
  const List<AppEntry> seed = <AppEntry>[
    AppEntry(packageName: 'com.whatsapp', label: 'WhatsApp'),
    AppEntry(packageName: 'com.smartapplock.app', label: 'Smart App Lock'),
    AppEntry(packageName: 'com.android.settings', label: 'Settings', isSystemApp: true),
    AppEntry(packageName: 'com.broken', label: ''),
    AppEntry(packageName: 'com.gmail', label: 'Gmail'),
  ];

  group('InstalledAppsRepositoryImpl', () {
    test('excludes the app locker itself', () async {
      final InstalledAppsRepository repo = InstalledAppsRepositoryImpl(
        StaticInstalledAppsService(seed),
      );
      final List<AppEntry> apps =
          (await repo.getInstalledApps(includeSystemApps: true)).valueOrNull!;
      expect(
        apps.map((AppEntry a) => a.packageName),
        isNot(contains('com.smartapplock.app')),
      );
    });

    test('filters system apps unless requested', () async {
      final InstalledAppsRepository repo = InstalledAppsRepositoryImpl(
        StaticInstalledAppsService(seed),
      );
      final List<AppEntry> user = (await repo.getInstalledApps()).valueOrNull!;
      expect(user.map((AppEntry a) => a.packageName),
          isNot(contains('com.android.settings')));

      final List<AppEntry> all =
          (await repo.getInstalledApps(includeSystemApps: true)).valueOrNull!;
      expect(all.map((AppEntry a) => a.packageName),
          contains('com.android.settings'));
    });

    test('sorts by label and normalizes empty labels to the package name',
        () async {
      final InstalledAppsRepository repo = InstalledAppsRepositoryImpl(
        StaticInstalledAppsService(seed),
      );
      final List<AppEntry> apps =
          (await repo.getInstalledApps(includeSystemApps: true)).valueOrNull!;
      final List<String> labels =
          apps.map((AppEntry a) => a.label.toLowerCase()).toList();
      expect(labels, orderedEquals(labels.toList()..sort()));

      final AppEntry broken =
          apps.firstWhere((AppEntry a) => a.packageName == 'com.broken');
      expect(broken.label, 'com.broken');
    });

    test('honors additional excluded packages', () async {
      final InstalledAppsRepository repo = InstalledAppsRepositoryImpl(
        StaticInstalledAppsService(seed),
        excludedPackages: const <String>['com.gmail'],
      );
      final List<AppEntry> apps =
          (await repo.getInstalledApps(includeSystemApps: true)).valueOrNull!;
      expect(apps.map((AppEntry a) => a.packageName),
          isNot(contains('com.gmail')));
    });

    test('caches per flag and only refetches on refresh()', () async {
      final StaticInstalledAppsService service =
          StaticInstalledAppsService(seed);
      final InstalledAppsRepository repo =
          InstalledAppsRepositoryImpl(service);

      await repo.getInstalledApps();
      await repo.getInstalledApps();
      expect(service.getInstalledAppsCalls, 1); // second call served from cache

      await repo.getInstalledApps(includeSystemApps: true);
      expect(service.getInstalledAppsCalls, 2); // different flag -> fetch

      await repo.refresh();
      await repo.getInstalledApps();
      expect(service.getInstalledAppsCalls, 4); // refresh cleared both caches
    });

    test('service failures propagate as Failures', () async {
      final InstalledAppsRepository repo =
          InstalledAppsRepositoryImpl(_FailingAppsService());
      final result = await repo.getInstalledApps();
      expect(result.isFailure, isTrue);
    });
  });

  group('AppContainer.inMemory wiring', () {
    test('installedApps repository is wired over the static service',
        () async {
      final AppContainer container = AppContainer.inMemory(apps: seed);
      final List<AppEntry> apps = (await container.installedApps
              .getInstalledApps(includeSystemApps: true))
          .valueOrNull!;
      expect(apps.map((AppEntry a) => a.packageName),
          isNot(contains('com.smartapplock.app')));
      expect(apps.map((AppEntry a) => a.packageName),
          contains('com.whatsapp'));
    });
  });
}

/// Always-failing service used to exercise failure propagation.
class _FailingAppsService implements InstalledAppsService {
  @override
  Future<Result<List<AppEntry>>> getInstalledApps({
    bool includeSystemApps = false,
  }) async =>
      Result.failure(StateError('simulated platform failure'));

  @override
  Future<Result<Uint8List?>> getAppIcon(String packageName) async =>
      Result.failure(StateError('simulated platform failure'));

  @override
  Future<Result<List<AppEntry>>> getRecentlyUsedApps({int limit = 10}) async =>
      Result.failure(StateError('n/a'));

  @override
  Future<Result<bool>> hasUsageAccess() async =>
      Result.failure(StateError('n/a'));

  @override
  Future<Result<void>> requestUsageAccess() async =>
      Result.failure(StateError('n/a'));
}
