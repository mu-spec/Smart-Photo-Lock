import '../utilities/result.dart';
import 'lock_profile.dart';

/// CRUD + activation boundary for [LockProfile]s.
///
/// Implemented in the profiles phase on top of `LockSettingsRepository`.
/// Screens talk to this interface; they never touch storage directly.
abstract interface class ProfileManager {
  Future<Result<List<LockProfile>>> getAll();

  Future<Result<LockProfile>> create(
    String name, {
    String? description,
    List<String> lockedPackages = const <String>[],
  });

  Future<Result<void>> update(LockProfile profile);

  Future<Result<void>> delete(String profileId);

  /// Makes [profileId] the single active profile.
  Future<Result<void>> activate(String profileId);

  Future<Result<LockProfile?>> getActive();
}
