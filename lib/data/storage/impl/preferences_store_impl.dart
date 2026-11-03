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
  Future<bool> wasCapabilityEverGranted(String kindName) async =>
      await _store.getBool(AppPrefKeys.capabilityEverGranted(kindName)) ??
      false;

  @override
  Future<void> markCapabilityEverGranted(String kindName) =>
      _store.setBool(AppPrefKeys.capabilityEverGranted(kindName), true);

  @override
  Future<Set<String>> getDismissedSecurityRecommendations() async {
    final String? raw =
        await _store.getString(AppPrefKeys.dismissedSecurityRecommendations);
    if (raw == null || raw.isEmpty) return <String>{};
    return raw.split('\n').where((String k) => k.isNotEmpty).toSet();
  }

  @override
  Future<void> dismissSecurityRecommendation(String key) async {
    if (key.isEmpty || key.contains('\n')) return;
    final Set<String> keys = await getDismissedSecurityRecommendations();
    if (!keys.add(key)) return;
    await _store.setString(
      AppPrefKeys.dismissedSecurityRecommendations,
      (keys.toList()..sort()).join('\n'),
    );
  }

  @override
  Future<void> clearAll() => _store.clear();
}
