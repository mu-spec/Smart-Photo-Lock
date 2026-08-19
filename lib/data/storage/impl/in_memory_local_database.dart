import '../../models/protected_app.dart';
import '../../../profiles/lock_profile.dart';
import '../../../rules/lock_rule.dart';
import '../local_database.dart';

/// Volatile [LocalDatabase] for tests and previews.
///
/// Implements the exact same contract as the SQLite store — including the
/// "exactly one active profile" invariant — without any platform plugin,
/// so `flutter test` never touches a real database.
class InMemoryLocalDatabase implements LocalDatabase {
  @override
  int get schemaVersion => 1;

  final Map<String, ProtectedApp> _protectedApps = <String, ProtectedApp>{};
  final Map<String, String> _settings = <String, String>{};
  final Map<String, LockProfile> _profiles = <String, LockProfile>{};
  List<LockRule> _rules = <LockRule>[];

  @override
  Future<void> init() async {}

  @override
  Future<void> close() async {}

  // -- protected applications ---------------------------------------------

  @override
  Future<List<ProtectedApp>> getProtectedApps() async {
    final List<ProtectedApp> apps = _protectedApps.values.toList()
      ..sort((ProtectedApp a, ProtectedApp b) {
        final int byOrder = a.sortOrder.compareTo(b.sortOrder);
        return byOrder != 0 ? byOrder : a.label.compareTo(b.label);
      });
    return List<ProtectedApp>.unmodifiable(apps);
  }

  @override
  Future<void> saveProtectedApp(ProtectedApp app) async {
    _protectedApps[app.packageName] = app;
  }

  @override
  Future<void> removeProtectedApp(String packageName) async {
    _protectedApps.remove(packageName);
  }

  // -- security settings ----------------------------------------------------

  @override
  Future<String?> getSetting(String key) async => _settings[key];

  @override
  Future<Map<String, String>> getAllSettings() async =>
      Map<String, String>.unmodifiable(_settings);

  @override
  Future<void> setSetting(String key, String value) async {
    _settings[key] = value;
  }

  @override
  Future<void> removeSetting(String key) async {
    _settings.remove(key);
  }

  // -- lock profiles -------------------------------------------------------

  @override
  Future<List<LockProfile>> getProfiles() async {
    final List<LockProfile> profiles = _profiles.values.toList()
      ..sort((LockProfile a, LockProfile b) => a.name.compareTo(b.name));
    return List<LockProfile>.unmodifiable(profiles);
  }

  @override
  Future<void> saveProfile(LockProfile profile) async {
    if (profile.isActive) {
      // Enforce the single-active invariant.
      for (final LockProfile existing in _profiles.values) {
        if (existing.id != profile.id && existing.isActive) {
          _profiles[existing.id] = existing.copyWith(isActive: false);
        }
      }
    }
    _profiles[profile.id] = profile;
  }

  @override
  Future<void> deleteProfile(String profileId) async {
    _profiles.remove(profileId);
  }

  // -- lock rules ----------------------------------------------------------

  @override
  Future<List<LockRule>> getRules() async =>
      List<LockRule>.unmodifiable(_rules);

  @override
  Future<void> saveRules(List<LockRule> rules) async {
    _rules = List<LockRule>.from(rules);
  }
}
