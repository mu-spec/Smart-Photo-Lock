import 'package:shared_preferences/shared_preferences.dart';

import '../key_value_store.dart';

/// Production [KeyValueStore] backed by `shared_preferences`.
///
/// The `SharedPreferences` instance is injected (obtained once in
/// `AppContainer.create`), so this class stays trivial and testable.
class SharedPreferencesKeyValueStore implements KeyValueStore {
  SharedPreferencesKeyValueStore(this._prefs);

  final SharedPreferences _prefs;

  @override
  Future<bool?> getBool(String key) async => _prefs.getBool(key);

  @override
  Future<int?> getInt(String key) async => _prefs.getInt(key);

  @override
  Future<String?> getString(String key) async => _prefs.getString(key);

  @override
  Future<void> setBool(String key, bool value) async {
    await _prefs.setBool(key, value);
  }

  @override
  Future<void> setInt(String key, int value) async {
    await _prefs.setInt(key, value);
  }

  /// Throws when the platform reports that the value was not stored
  /// (`false`), so callers never treat an unsaved value as saved. Phase 9 /
  /// M3: "Don't suggest again" is confirmed only after a real save.
  @override
  Future<void> setString(String key, String value) async {
    if (!await _prefs.setString(key, value)) {
      throw StateError('Preference "$key" was not saved.');
    }
  }

  @override
  Future<void> remove(String key) async {
    await _prefs.remove(key);
  }

  @override
  Future<void> clear() async {
    await _prefs.clear();
  }
}
