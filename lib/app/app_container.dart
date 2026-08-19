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
import '../security/encryption/settings_cipher.dart';
import '../security/encryption/settings_cipher_impl.dart';
import '../security/credentials/credential_manager.dart';
import '../security/credentials/impl/default_credential_manager.dart';
import '../security/storage/impl/flutter_secure_secret_store.dart';
import '../security/storage/impl/in_memory_secret_store.dart';
import '../security/storage/secret_store.dart';

/// Application dependency container — the single wiring point for all
/// persistence and security storage.
///
/// Screens and controllers never construct stores themselves; they receive
/// the repositories from here. Two ways to build one:
///
///  * [AppContainer.create]  — production: shared_preferences + SQLite +
///    Android Keystore-backed secret store + AES-GCM settings encryption.
///  * [AppContainer.inMemory] — tests/previews: volatile stores.
class AppContainer {
  AppContainer._({
    required KeyValueStore keyValueStore,
    required LocalDatabase database,
    required SecretStore secretStore,
  })  : _keyValueStore = keyValueStore,
        _database = database,
        secretStore = secretStore {
    settingsCipher = AesGcmSettingsCipher(secretStore);
    preferences = PreferencesStoreImpl(_keyValueStore);
    protectedApps = ProtectedAppsRepositoryImpl(_database);
    securitySettings = SecuritySettingsRepositoryImpl(
      _database,
      cipher: settingsCipher,
    );
    lockSettings = LockSettingsRepositoryImpl(_database);
    auth = DefaultCredentialManager(settings: securitySettings);
  }

  /// Production container: real on-device persistence with
  /// Android Keystore-backed protection for sensitive values.
  static Future<AppContainer> create() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final SqfliteLocalDatabase database = SqfliteLocalDatabase();
    await database.init();
    return AppContainer._(
      keyValueStore: SharedPreferencesKeyValueStore(prefs),
      database: database,
      secretStore: FlutterSecureSecretStore(),
    );
  }

  /// Volatile container for tests and previews (no platform plugins).
  static AppContainer inMemory() => AppContainer._(
        keyValueStore: InMemoryKeyValueStore(),
        database: InMemoryLocalDatabase(),
        secretStore: InMemorySecretStore(),
      );

  final KeyValueStore _keyValueStore;
  final LocalDatabase _database;

  /// Sensitive values (master key, future tokens) — Keystore-backed in
  /// production. Nothing sensitive is ever written elsewhere.
  final SecretStore secretStore;

  /// AES-256-GCM cipher protecting the security settings document.
  late final SettingsCipher settingsCipher;

  /// Typed app preferences (onboarding, theme, language, notifications).
  late final PreferencesStore preferences;

  /// Protected applications list.
  late final ProtectedAppsRepository protectedApps;

  /// Security configuration (encrypted at rest; holds the PIN credential hash).
  late final SecuritySettingsRepository securitySettings;

  /// Lock profiles and rules.
  late final LockSettingsRepository lockSettings;

  /// Credential lifecycle (Phase 2A): enroll / status / authenticate /
  /// clear for PIN, pattern and biometric.
  late final CredentialManager auth;
}
