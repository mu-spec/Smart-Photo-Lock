/// Well-known keys for the preferences tier ([KeyValueStore]).
abstract final class AppPrefKeys {
  static const String onboardingCompleted = 'pref.onboarding.completed';
  static const String themeMode = 'pref.theme.mode';
  static const String languageCode = 'pref.language.code';
  static const String notificationsEnabled = 'pref.notifications.enabled';
  static const String lastActiveProfileId = 'pref.profile.last_active_id';
}

/// Typed, app-level preferences facade.
///
/// Screens read/write app preferences exclusively through this interface —
/// never through raw storage keys. Preferences are lightweight, fire-and-
/// forget values (theme, onboarding, language); anything security-relevant
/// goes through [SecuritySettingsRepository] instead.
abstract interface class PreferencesStore {
  // Onboarding
  Future<bool> isOnboardingCompleted();
  Future<void> setOnboardingCompleted(bool completed);

  // Appearance
  Future<String?> getThemeMode();
  Future<void> setThemeMode(String mode);

  // Localization
  Future<String?> getLanguageCode();
  Future<void> setLanguageCode(String code);

  // Notifications
  Future<bool> areNotificationsEnabled();
  Future<void> setNotificationsEnabled(bool enabled);

  // Profiles (last used — the canonical active profile lives in the DB)
  Future<String?> getLastActiveProfileId();
  Future<void> setLastActiveProfileId(String profileId);

  Future<void> clearAll();
}
