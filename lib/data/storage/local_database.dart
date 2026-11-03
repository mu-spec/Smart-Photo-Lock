import '../models/app_security_level.dart';
import '../models/protected_app.dart';
import '../../profiles/lock_profile.dart';
import '../../rules/lock_rule.dart';

/// Local database boundary — the single on-device store for everything the
/// app persists beyond lightweight preferences:
///
///  * protected applications (`protected_apps` table)
///  * security settings (`security_settings` key-value table)
///  * lock profiles (`profiles` table)
///  * lock rules (`lock_rules` table)
///
/// The production implementation is SQLite (`SqfliteLocalDatabase`); tests
/// use `InMemoryLocalDatabase`. No protection logic lives here — this layer
/// only stores and retrieves.
abstract interface class LocalDatabase {
  /// Version of the on-disk schema (drives migrations in the SQLite impl).
  int get schemaVersion;

  /// Opens/prepares the store. Must be called once before use.
  Future<void> init();

  Future<void> close();

  // -- protected applications ---------------------------------------------

  /// All protected apps, ordered by [ProtectedApp.sortOrder] then label.
  Future<List<ProtectedApp>> getProtectedApps();

  /// Upsert by package name (one record per package). A new record is
  /// stored with [ProtectedApp.securityLevel]. For an existing record the
  /// label, addedAt and sortOrder are replaced but the stored security
  /// level is KEPT (Phase 8 / M1): a repeated protect never resets a level;
  /// only [updateProtectedAppSecurityLevel] changes it. Atomic.
  Future<void> saveProtectedApp(ProtectedApp app);

  /// Sets the security level of an existing protected app, atomically.
  /// Returns false (and stores nothing) when [packageName] is not
  /// protected: a level change never protects or unprotects an app.
  Future<bool> updateProtectedAppSecurityLevel(
    String packageName,
    AppSecurityLevel level,
  );

  Future<void> removeProtectedApp(String packageName);

  // -- security settings (key-value) ---------------------------------------

  Future<String?> getSetting(String key);

  Future<Map<String, String>> getAllSettings();

  Future<void> setSetting(String key, String value);

  Future<void> removeSetting(String key);

  // -- lock profiles -------------------------------------------------------

  Future<List<LockProfile>> getProfiles();

  /// Upserts a profile. When [profile.isActive] is true, all other profiles
  /// are deactivated first — exactly one profile stays active.
  Future<void> saveProfile(LockProfile profile);

  Future<void> deleteProfile(String profileId);

  // -- lock rules ----------------------------------------------------------

  Future<List<LockRule>> getRules();

  /// Replaces the entire rule set (rules are edited as a whole).
  Future<void> saveRules(List<LockRule> rules);
}
