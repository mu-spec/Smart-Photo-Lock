/// Well-known keys for the preferences tier ([KeyValueStore]).
abstract final class AppPrefKeys {
  static const String onboardingCompleted = 'pref.onboarding.completed';
  static const String themeMode = 'pref.theme.mode';
  static const String languageCode = 'pref.language.code';
  static const String notificationsEnabled = 'pref.notifications.enabled';
  static const String lastActiveProfileId = 'pref.profile.last_active_id';

  /// Prefix for the capability grant-history keys (Phase 4 UX: setup vs
  /// revocation distinction). One boolean per capability kind name.
  static const String capabilityEverGrantedPrefix =
      'pref.capability.ever_granted.';

  static String capabilityEverGranted(String kindName) =>
      '$capabilityEverGrantedPrefix$kindName';

  /// Phase 8 / M2 (8F): security-level suggestions the user dismissed,
  /// one `package@level` entry per line. Local only; never uploaded.
  static const String dismissedSecurityRecommendations =
      'pref.security_recommendation.dismissed';
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

  // Capability grant history (Phase 4 UX). Records whether a required
  // capability was granted AT LEAST ONCE, so a currently-missing
  // capability can be classified as either first-install setup or a
  // post-grant revocation. Not sensitive — just a boolean per kind.
  Future<bool> wasCapabilityEverGranted(String kindName);
  Future<void> markCapabilityEverGranted(String kindName);

  /// Phase 8 / M2 (8F): dismissed security-level suggestions, as
  /// `package@level` keys (see `SecurityRecommendation.dismissalKey`).
  /// Advisory UI state only; it never affects how an app is locked.
  Future<Set<String>> getDismissedSecurityRecommendations();
  Future<void> dismissSecurityRecommendation(String key);

  Future<void> clearAll();
}
