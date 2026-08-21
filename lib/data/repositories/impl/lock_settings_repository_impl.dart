import '../../../profiles/lock_profile.dart';
import '../../../rules/lock_rule.dart';
import '../../../utilities/result.dart';
import '../../storage/local_database.dart';
import '../lock_settings_repository.dart';

/// [LockSettingsRepository] over the [LocalDatabase] — persists profiles
/// and rules (the two "configuration" domains).
class LockSettingsRepositoryImpl implements LockSettingsRepository {
  LockSettingsRepositoryImpl(this._database);

  final LocalDatabase _database;

  // -- profiles ------------------------------------------------------------

  @override
  Future<Result<LockProfile?>> getActiveProfile() async {
    try {
      final List<LockProfile> profiles = await _database.getProfiles();
      for (final LockProfile profile in profiles) {
        if (profile.isActive) {
          return Result.success(profile);
        }
      }
      return Result.success(null);
    } catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<void>> setActiveProfile(String profileId) async {
    try {
      final List<LockProfile> profiles = await _database.getProfiles();
      for (final LockProfile profile in profiles) {
        await _database.saveProfile(
          profile.copyWith(isActive: profile.id == profileId),
        );
      }
      return Result.success(null);
    } catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<List<LockProfile>>> getProfiles() async {
    try {
      return Result.success(await _database.getProfiles());
    } catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<void>> saveProfile(LockProfile profile) async {
    try {
      await _database.saveProfile(profile);
      return Result.success(null);
    } catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<void>> deleteProfile(String profileId) async {
    try {
      await _database.deleteProfile(profileId);
      return Result.success(null);
    } catch (e) {
      return Result.failure(e);
    }
  }

  // -- rules ---------------------------------------------------------------

  @override
  Future<Result<List<LockRule>>> getRules() async {
    try {
      return Result.success(await _database.getRules());
    } catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<void>> saveRules(List<LockRule> rules) async {
    try {
      await _database.saveRules(rules);
      return Result.success(null);
    } catch (e) {
      return Result.failure(e);
    }
  }

  // -- re-lock grace (Phase 5L) ---------------------------------------------

  /// DB key holding the grace period in whole seconds.
  static const String gracePeriodKey = 'lock.grace_period_seconds';

  @override
  Future<Result<Duration>> getGracePeriod() async {
    try {
      final String? raw = await _database.getSetting(gracePeriodKey);
      if (raw == null) {
        return Result.success(Duration.zero);
      }
      final int? seconds = int.tryParse(raw);
      if (seconds == null || seconds < 0) {
        return Result.success(Duration.zero);
      }
      return Result.success(Duration(seconds: seconds));
    } catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<void>> setGracePeriod(Duration period) async {
    try {
      final Duration clamped =
          period.isNegative ? Duration.zero : period;
      await _database.setSetting(
        gracePeriodKey,
        '${clamped.inSeconds}',
      );
      return Result.success(null);
    } catch (e) {
      return Result.failure(e);
    }
  }
}
