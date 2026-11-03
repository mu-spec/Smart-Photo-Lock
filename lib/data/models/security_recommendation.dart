import 'app_security_level.dart';

/// Phase 8 / M2 (PRD 8F): why an app is suggested a stricter level.
enum SensitiveAppCategory {
  finance(
    AppSecurityLevel.critical,
    'Banking and payment apps can move money.',
  ),
  passwordManager(
    AppSecurityLevel.critical,
    'Password managers hold the keys to your other accounts.',
  ),
  authenticator(
    AppSecurityLevel.critical,
    'Authenticator codes can sign in to your accounts.',
  ),
  privacy(
    AppSecurityLevel.sensitive,
    'This app usually holds private messages or photos.',
  );

  const SensitiveAppCategory(this.recommendedLevel, this.reason);

  /// The level suggested for apps in this category.
  final AppSecurityLevel recommendedLevel;

  /// Plain-language reason shown with the suggestion.
  final String reason;
}

/// An advisory suggestion to raise [packageName] to [level].
///
/// Suggestions are shown only; accepting one is an explicit user choice that
/// goes through the normal level change. Nothing here changes a level,
/// protects an app, or leaves the device.
class SecurityRecommendation {
  const SecurityRecommendation({
    required this.packageName,
    required this.category,
  });

  final String packageName;
  final SensitiveAppCategory category;

  AppSecurityLevel get level => category.recommendedLevel;
  String get reason => category.reason;

  /// Persisted when the user taps "Don't suggest again". Bound to the
  /// suggested level so a dismissal never hides a different suggestion.
  String get dismissalKey => '$packageName@${level.storageId}';
}

/// Phase 8 / M2 (PRD 8F): deterministic, explainable suggestions from a
/// small, reviewed list of EXACT package names. No keyword matching, no
/// heuristics, no network, no analytics. A wrong or outdated entry can only
/// produce an advisory hint the user can dismiss; it can never change how
/// an app is locked.
abstract final class SecurityRecommendations {
  /// Phase 9 / M3: shown (Security Center and Apps tab) when "Don't suggest
  /// again" could not be saved. The suggestion stays visible; nothing else
  /// changed.
  static const String dismissNotSavedMessage =
      "Couldn't save your choice, so the suggestion is still shown. Nothing "
      'was changed.';
  static const String dismissRetryLabel = 'Try again';

  /// Reviewed exact package names (2026-11). Unknown apps get no hint.
  static const Map<String, SensitiveAppCategory> catalog =
      <String, SensitiveAppCategory>{
    // Banking, wallets and payments (Pakistan and international).
    'pk.com.telenor.phoenix': SensitiveAppCategory.finance, // Easypaisa
    'com.techlogix.mobilinkcustomer': SensitiveAppCategory.finance, // JazzCash
    'invo8.meezan.mb': SensitiveAppCategory.finance, // Meezan Bank
    'com.hbl.android.hblmobilebanking': SensitiveAppCategory.finance, // HBL
    'com.paypal.android.p2pmobile': SensitiveAppCategory.finance,
    'com.google.android.apps.walletnfcrel': SensitiveAppCategory.finance,
    'com.binance.dev': SensitiveAppCategory.finance,
    'com.coinbase.android': SensitiveAppCategory.finance,
    // Password managers.
    'com.x8bit.bitwarden': SensitiveAppCategory.passwordManager,
    'com.agilebits.onepassword': SensitiveAppCategory.passwordManager,
    'com.lastpass.lpandroid': SensitiveAppCategory.passwordManager,
    'com.dashlane': SensitiveAppCategory.passwordManager,
    'keepass2android.keepass2android': SensitiveAppCategory.passwordManager,
    'com.kunzisoft.keepass.free': SensitiveAppCategory.passwordManager,
    'com.callpod.android_apps.keeper': SensitiveAppCategory.passwordManager,
    'proton.android.pass': SensitiveAppCategory.passwordManager,
    // Authenticators.
    'com.google.android.apps.authenticator2':
        SensitiveAppCategory.authenticator,
    'com.azure.authenticator': SensitiveAppCategory.authenticator,
    'com.authy.authy': SensitiveAppCategory.authenticator,
    'com.beemdevelopment.aegis': SensitiveAppCategory.authenticator,
    'org.fedorahosted.freeotp': SensitiveAppCategory.authenticator,
    'com.twofasapp': SensitiveAppCategory.authenticator,
    // Private messages and photos.
    'com.whatsapp': SensitiveAppCategory.privacy,
    'org.thoughtcrime.securesms': SensitiveAppCategory.privacy, // Signal
    'org.telegram.messenger': SensitiveAppCategory.privacy,
    'com.google.android.apps.photos': SensitiveAppCategory.privacy,
  };

  /// The suggestion for a PROTECTED app currently at [current], or null
  /// when there is none: unknown package, already at or above the
  /// suggested level, or dismissed by the user.
  static SecurityRecommendation? forApp(
    String packageName,
    AppSecurityLevel current, {
    Set<String> dismissed = const <String>{},
  }) {
    final SensitiveAppCategory? category = catalog[packageName];
    if (category == null) return null;
    final SecurityRecommendation suggestion = SecurityRecommendation(
      packageName: packageName,
      category: category,
    );
    if (!suggestion.level.isStricterThan(current)) return null;
    if (dismissed.contains(suggestion.dismissalKey)) return null;
    return suggestion;
  }
}
