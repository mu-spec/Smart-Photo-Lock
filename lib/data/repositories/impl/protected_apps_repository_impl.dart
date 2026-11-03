import '../../../utilities/result.dart';
import '../../models/app_security_level.dart';
import '../../models/protected_app.dart';
import '../../storage/local_database.dart';
import '../protected_apps_repository.dart';

/// [ProtectedAppsRepository] over the [LocalDatabase].
class ProtectedAppsRepositoryImpl implements ProtectedAppsRepository {
  ProtectedAppsRepositoryImpl(this._database);

  final LocalDatabase _database;

  @override
  Future<Result<List<ProtectedApp>>> getProtectedApps() async {
    try {
      return Result.success(await _database.getProtectedApps());
    } catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<void>> add(ProtectedApp app) async {
    try {
      await _database.saveProtectedApp(app);
      return Result.success(null);
    } catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<void>> setSecurityLevel(
    String packageName,
    AppSecurityLevel level,
  ) async {
    if (packageName.trim().isEmpty) {
      return Result.failure(ArgumentError.value(packageName, 'packageName'));
    }
    try {
      final bool updated =
          await _database.updateProtectedAppSecurityLevel(packageName, level);
      return updated
          ? Result.success(null)
          : Result.failure(
              StateError('$packageName is not protected; level not saved.'),
            );
    } catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<void>> remove(String packageName) async {
    try {
      await _database.removeProtectedApp(packageName);
      return Result.success(null);
    } catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<bool>> isProtected(String packageName) async {
    final Result<List<ProtectedApp>> apps = await getProtectedApps();
    return apps.fold(
      (List<ProtectedApp> list) => Result.success(
          list.any((ProtectedApp a) => a.packageName == packageName)),
      Result.failure,
    );
  }

  @override
  Future<Result<int>> count() async {
    final Result<List<ProtectedApp>> apps = await getProtectedApps();
    return apps.fold(
      (List<ProtectedApp> list) => Result.success(list.length),
      Result.failure,
    );
  }
}
