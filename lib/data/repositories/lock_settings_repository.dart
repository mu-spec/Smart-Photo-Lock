import '../../profiles/lock_profile.dart';
import '../../rules/lock_rule.dart';
import '../../utilities/result.dart';

/// Persistence boundary for everything the user configures about locking:
/// the active [LockProfile] and the global [LockRule] set.
///
/// Implemented in the settings phase on top of a local database (e.g.
/// sqflite) or a key-value store.
abstract interface class LockSettingsRepository {
  Future<Result<LockProfile?>> getActiveProfile();

  Future<Result<void>> setActiveProfile(String profileId);

  Future<Result<List<LockProfile>>> getProfiles();

  Future<Result<void>> saveProfile(LockProfile profile);

  Future<Result<void>> deleteProfile(String profileId);

  Future<Result<List<LockRule>>> getRules();

  Future<Result<void>> saveRules(List<LockRule> rules);
}
