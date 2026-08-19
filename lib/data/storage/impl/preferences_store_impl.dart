import '../key_value_store.dart';
import '../preferences_store.dart';

/// [PreferencesStore] over any [KeyValueStore] (production or in-memory).
class PreferencesStoreImpl implements PreferencesStore {
  PreferencesStoreImpl(this._store);

  final KeyValueStore _store;

  @override
  Future<bool> isOnboardingCompleted() async =>
      await _store.getBool(AppPrefKeys.onboardingCompleted) ?? false;

  @override
  Future<void> setOnboardingCompleted(bool completed) =>
      _store.setBool(AppPrefKeys.onboardingCompleted, completed);

  @override
  Future<String?> getThemeMode() => _store.getString(AppPrefKeys.themeMode);

  @override
  Future<void> setThemeMode(String mode) =>
      _store.setString(AppPrefKeys.themeMode, mode);

  @override
  Future<String?> getLanguageCode() =>
      _store.getString(AppPrefKeys.languageCode);

  @override
  Future<void> setLanguageCode(String code) =>
      _store.setString(AppPrefKeys.languageCode, code);

  @override
  Future<bool> areNotificationsEnabled() async =>
      await _store.getBool(AppPrefKeys.notificationsEnabled) ?? true;

  @override
  Future<void> setNotificationsEnabled(bool enabled) =>
      _store.setBool(AppPrefKeys.notificationsEnabled, enabled);

  @override
  Future<String?> getLastActiveProfileId() =>
      _store.getString(AppPrefKeys.lastActiveProfileId);

  @override
  Future<void> setLastActiveProfileId(String profileId) =>
      _store.setString(AppPrefKeys.lastActiveProfileId, profileId);

  @override
  Future<void> clearAll() => _store.clear();
}
