import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/protected_apps_repository.dart';
import 'package:smart_app_lock/protection/protection_bootstrap.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/utilities/result.dart';

void main() {
  test('nothing configured keeps native recovery stopped', () async {
    final container = AppContainer.inMemory();
    final watcher = container.watcher as StaticWatcherService;

    final result = await container.protectionBootstrap.synchronize();

    expect(result.isSuccess, isTrue);
    expect(result.valueOrNull!.configured, isFalse);
    expect(watcher.protectionConfigured, isFalse);
    expect(watcher.running, isFalse);
    expect(watcher.protectedPackages, isEmpty);
  });

  test('credential plus protected app persists and starts recovery', () async {
    final container = AppContainer.inMemory();
    final watcher = container.watcher as StaticWatcherService;
    await container.auth.enrollPin('2468');
    await container.protectedApps.add(
      ProtectedApp(
        packageName: 'com.example.private',
        label: 'Private',
        addedAt: DateTime(2026, 9, 6),
      ),
    );

    final result = await container.protectionBootstrap.synchronize();

    expect(result.valueOrNull!.configured, isTrue);
    expect(watcher.running, isTrue);
    expect(watcher.engineAvailable, isTrue);
    expect(watcher.protectedPackages, {'com.example.private'});
  });

  test('protected app without credential never enables recovery', () async {
    final container = AppContainer.inMemory();
    final watcher = container.watcher as StaticWatcherService;
    await container.protectedApps.add(
      ProtectedApp(
        packageName: 'com.example.private',
        label: 'Private',
        addedAt: DateTime(2026, 9, 6),
      ),
    );

    await container.protectionBootstrap.synchronize();

    expect(watcher.protectionConfigured, isFalse);
    expect(watcher.running, isFalse);
  });

  test('repository failure does not overwrite enabled native state', () async {
    final container = AppContainer.inMemory();
    final watcher = container.watcher as StaticWatcherService;
    await container.auth.enrollPin('2468');
    await watcher.configureProtection(
      enabled: true,
      protectedPackages: {'com.example.private'},
    );
    final bootstrap = ProtectionBootstrap(
      protectedApps: _FailingProtectedAppsRepository(),
      credentials: container.auth,
      watcher: watcher,
    );

    final result = await bootstrap.synchronize();

    expect(result.isFailure, isTrue);
    expect(watcher.protectionConfigured, isTrue);
    expect(watcher.protectedPackages, {'com.example.private'});
  });

  test('pending native challenge remains latched until rendered handoff',
      () async {
    final watcher = StaticWatcherService()
      ..pendingChallenge = 'com.example.private';

    expect(
      (await watcher.takePendingChallenge()).valueOrNull,
      'com.example.private',
    );
    expect(
      (await watcher.takePendingChallenge()).valueOrNull,
      'com.example.private',
    );
  });
}

class _FailingProtectedAppsRepository implements ProtectedAppsRepository {
  @override
  Future<Result<List<ProtectedApp>>> getProtectedApps() async =>
      Result.failure(StateError('database unavailable'));

  @override
  Future<Result<void>> add(ProtectedApp app) async => Result.success(null);

  @override
  Future<Result<void>> remove(String packageName) async => Result.success(null);

  @override
  Future<Result<bool>> isProtected(String packageName) async =>
      Result.failure(StateError('database unavailable'));

  @override
  Future<Result<int>> count() async =>
      Result.failure(StateError('database unavailable'));
}
