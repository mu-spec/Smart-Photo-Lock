import '../../security/pin_hasher.dart';

/// All user-configurable security settings, persisted as one JSON document
/// in the local database (`security_settings` key-value table).
///
/// This model only *stores* configuration — no protection logic lives here.
class SecuritySettings {
  const SecuritySettings({
    this.pinHash,
    this.intruderSelfieEnabled = false,
    this.breakInAlertsEnabled = false,
    this.stealthModeEnabled = false,
    this.uninstallProtectionEnabled = false,
    this.maxFailedAttempts = 5,
    this.lockoutDuration = const Duration(seconds: 30),
    this.unlockSessionWindow = const Duration(minutes: 2),
  });

  /// Factory-default settings (nothing configured yet).
  static const SecuritySettings defaults = SecuritySettings();

  /// Stored PIN credential (PBKDF2 hash) — null until the PIN phase.
  final PinHash? pinHash;

  /// Snap a photo after repeated wrong-PIN attempts.
  final bool intruderSelfieEnabled;

  /// Notify the owner about blocked attempts.
  final bool breakInAlertsEnabled;

  /// Hide the app from the launcher while protection is active.
  final bool stealthModeEnabled;

  /// Block casual uninstall while locks are active.
  final bool uninstallProtectionEnabled;

  /// Wrong attempts before the challenge screen locks out for a cooldown.
  final int maxFailedAttempts;

  /// Cooldown after too many failed attempts.
  final Duration lockoutDuration;

  /// How long a successful unlock keeps re-opening the same app free.
  final Duration unlockSessionWindow;

  /// True once a PIN exists (the core credential is set).
  bool get hasPin => pinHash != null;

  SecuritySettings copyWith({
    PinHash? pinHash,
    bool clearPin = false,
    bool? intruderSelfieEnabled,
    bool? breakInAlertsEnabled,
    bool? stealthModeEnabled,
    bool? uninstallProtectionEnabled,
    int? maxFailedAttempts,
    Duration? lockoutDuration,
    Duration? unlockSessionWindow,
  }) {
    return SecuritySettings(
      pinHash: clearPin ? null : (pinHash ?? this.pinHash),
      intruderSelfieEnabled: intruderSelfieEnabled ?? this.intruderSelfieEnabled,
      breakInAlertsEnabled: breakInAlertsEnabled ?? this.breakInAlertsEnabled,
      stealthModeEnabled: stealthModeEnabled ?? this.stealthModeEnabled,
      uninstallProtectionEnabled:
          uninstallProtectionEnabled ?? this.uninstallProtectionEnabled,
      maxFailedAttempts: maxFailedAttempts ?? this.maxFailedAttempts,
      lockoutDuration: lockoutDuration ?? this.lockoutDuration,
      unlockSessionWindow: unlockSessionWindow ?? this.unlockSessionWindow,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'pinHash': pinHash?.toJson(),
        'intruderSelfieEnabled': intruderSelfieEnabled,
        'breakInAlertsEnabled': breakInAlertsEnabled,
        'stealthModeEnabled': stealthModeEnabled,
        'uninstallProtectionEnabled': uninstallProtectionEnabled,
        'maxFailedAttempts': maxFailedAttempts,
        'lockoutDurationSeconds': lockoutDuration.inSeconds,
        'unlockSessionWindowSeconds': unlockSessionWindow.inSeconds,
      };

  factory SecuritySettings.fromJson(Map<String, dynamic> json) =>
      SecuritySettings(
        pinHash: json['pinHash'] == null
            ? null
            : PinHash.fromJson(
                (json['pinHash'] as Map<String, dynamic>).cast<String, dynamic>(),
              ),
        intruderSelfieEnabled: json['intruderSelfieEnabled'] as bool? ?? false,
        breakInAlertsEnabled: json['breakInAlertsEnabled'] as bool? ?? false,
        stealthModeEnabled: json['stealthModeEnabled'] as bool? ?? false,
        uninstallProtectionEnabled:
            json['uninstallProtectionEnabled'] as bool? ?? false,
        maxFailedAttempts: json['maxFailedAttempts'] as int? ?? 5,
        lockoutDuration: Duration(
          seconds: json['lockoutDurationSeconds'] as int? ?? 30,
        ),
        unlockSessionWindow: Duration(
          seconds: json['unlockSessionWindowSeconds'] as int? ?? 120,
        ),
      );

  @override
  String toString() => 'SecuritySettings(pin=${hasPin ? 'set' : 'not set'}, '
      'intruderSelfie=$intruderSelfieEnabled, stealth=$stealthModeEnabled)';
}
