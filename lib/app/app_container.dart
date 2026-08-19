import 'package:shared_preferences/shared_preferences.dart';

import '../data/repositories/impl/lock_settings_repository_impl.dart';
import '../data/repositories/impl/protected_apps_repository_impl.dart';
import '../data/repositories/impl/security_settings_repository_impl.dart';
import '../data/repositories/lock_settings_repository.dart';
import '../data/repositories/protected_apps_repository.dart';
import '../data/repositories/security_settings_repository.dart';
import '../data/storage/impl/in_memory_key_value_store.dart';
import '../data/storage/impl/in_memory_local_database.dart';
import '../data/storage/impl/preferences_store_impl.dart';
import '../data/storage/impl/shared_prefs_key_value_store.dart';
import '../data/storage/impl/sqflite_local_database.dart';
import '../data/storage/key_value_store.dart';
import '../data/storage/local_database.dart';
import '../data/storage/preferences_store.dart';

/// Application dependency container — the single wiring point for all
/// persistence.
///
/// Screens and controllers never construct stores themselves; they receive
/// the repositories from here. Two ways to build one:
///
///  * [AppContainer.create]  — production: shared_preferences + SQLite.
///  * [AppContainer.inMemory] — tests/previews: volatile stores.
class AppContainer {
  AppContainer._({
    required KeyValueStore keyValueStore,
    required LocalDatabase database,
  })  : _keyValueStore = keyValueStore,
        _database = database {
    preferences = PreferencesStoreImpl(_keyValueStore);
    protectedApps = ProtectedAppsRepositoryImpl(_database);
    securitySettings = SecuritySettingsRepositoryImpl(_database);
    lockSettings = LockSettingsRepositoryImpl(_database);
  }

  /// Production container: real on-device persistence.
  static Future<AppContainer> create() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final SqfliteLocalDatabase database = SqfliteLocalDatabase();
    await database.init();
    return AppContainer._(
      keyValueStore: SharedPreferencesKeyValueStore(prefs),
      database: database,
    );
  }

  /// Volatile container for tests and previews (no platform plugins).
  static AppContainer inMemory() => AppContainer._(
        keyValueStore: InMemoryKeyValueStore(),
        database: InMemoryLocalDatabase(),
      );

  final KeyValueStore _keyValueStore;
  final LocalDatabase _database;

  /// Typed app preferences (onboarding, theme, language, notifications).
  late final PreferencesStore preferences;

  /// Protected applications list.
  late final ProtectedAppsRepository protectedApps;

  /// Security configuration (PIN credential, intruder selfie, ...).
  late final SecuritySettingsRepository securitySettings;

  /// Lock profiles and rules.
  late final LockSettingsRepository lockSettings;
}
