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

  /// Completes only once the dismissal is saved; throws otherwise.
  ///
  /// Phase 9 / M3: on a failed save the previous value is written back
  /// (best effort). Both `shared_preferences` and Android keep a value in
  /// memory even when its disk write fails; without this, the unsaved
  /// dismissal would still be read back in this process (or flushed by a
  /// later write) and then reappear, or not, after a restart.
  @override
  Future<void> dismissSecurityRecommendation(String key) async {
    if (key.isEmpty || key.contains('\n')) return;
    const String prefKey = AppPrefKeys.dismissedSecurityRecommendations;
    final String? previous = await _store.getString(prefKey);
    final Set<String> keys = await getDismissedSecurityRecommendations();
    if (!keys.add(key)) return;
    try {
      await _store.setString(prefKey, (keys.toList()..sort()).join('\n'));
    } catch (_) {
      try {
        if (previous == null) {
          await _store.remove(prefKey);
        } else {
          await _store.setString(prefKey, previous);
        }
      } catch (_) {
        // The original failure is what the caller must see.
      }
      rethrow;
    }
  }

  @override
  Future<void> clearAll() => _store.clear();
}
