import '../../security/credentials/auth_type.dart';
import '../../security/credentials/biometric_options.dart';
import '../../security/credentials/credential_hash.dart';
import '../../security/pin_hasher.dart';

/// All user-configurable security settings, persisted as one JSON document
/// in the local database (`security_settings` key-value table, encrypted at
/// rest — see Phase 1F).
///
/// Phase 2A adds the credential-state surface: enrolled credential hashes
/// (PIN + pattern), biometric configuration, the primary credential type,
/// and the attempt/lockout counters. This model only *stores* state — the
/// logic lives in the security module (`CredentialStateMachine`,
/// `CredentialManager`).
class SecuritySettings {
  const SecuritySettings({
    this.pinHash,
    this.patternHash,
    this.biometricOptions,
    this.primaryAuthType,
    this.intruderSelfieEnabled = false,
    this.breakInAlertsEnabled = false,
    this.stealthModeEnabled = false,
    this.uninstallProtectionEnabled = false,
    this.maxFailedAttempts = 5,
    this.lockoutDuration = const Duration(seconds: 30),
    this.unlockSessionWindow = const Duration(minutes: 2),
    this.failedAttempts = 0,
    this.lockedOutUntil,
    this.pinLength,
    this.lockoutStreak = 0,
    this.randomizedKeypadEnabled = false,
    this.patternVisibilityEnabled = true,
  });

  /// Factory-default settings (nothing configured yet).
  static const SecuritySettings defaults = SecuritySettings();

  /// Stored PIN credential (PBKDF2 hash) — null until a PIN is enrolled.
  final PinHash? pinHash;

  /// Stored pattern credential (PBKDF2 hash over the exact ordered node
  /// sequence — direction-sensitive).
  final CredentialHash? patternHash;

  /// Biometric accelerator configuration; null = biometric not configured.
  /// (The app never stores biometric secrets — the OS owns them.)
  final BiometricOptions? biometricOptions;

  /// Which credential acts as the primary fallback secret
  /// ([AuthType.pin] or [AuthType.pattern]).
  final AuthType? primaryAuthType;

  /// Snap a photo after repeated wrong-credential attempts.
  final bool intruderSelfieEnabled;

  /// Notify the owner about blocked attempts.
  final bool breakInAlertsEnabled;

  /// Hide the app from the launcher while protection is active.
  final bool stealthModeEnabled;

  /// Block casual uninstall while locks are active.
  final bool uninstallProtectionEnabled;

  /// Wrong attempts before the challenge locks out for a cooldown.
  final int maxFailedAttempts;

  /// Cooldown after too many failed attempts.
  final Duration lockoutDuration;

  /// How long a successful unlock keeps re-opening the same app free.
  final Duration unlockSessionWindow;

  /// Consecutive failed attempts since the last success.
  final int failedAttempts;

  /// When the current lockout expires (null = not locked out).
  final DateTime? lockedOutUntil;

  /// Length of the enrolled PIN (4 or 6). Recorded at enrollment so the
  /// unlock screen knows how many digits to expect without inspecting the
  /// stored hash.
  final int? pinLength;

  /// Consecutive lockout count (0 = none). Drives the escalating cooldown
  /// schedule (Phase 2F); persists so restarts do not reset it.
  final int lockoutStreak;

  /// Randomizes the unlock-screen keypad layout (Phase 2G). Off by default
  /// so the standard 1-9 layout stays the accessible baseline.
  final bool randomizedKeypadEnabled;

  /// Shows the pattern drawing trail while unlocking (Phase 2K). Default
  /// true (visible); turning it off hides the trail + node highlights for
  /// privacy (anti-shoulder-surfing).
  final bool patternVisibilityEnabled;

  /// True once a PIN credential exists (the original primary secret).
  bool get hasPin => pinHash != null;

  /// True once a pattern credential exists.
  bool get hasPattern => patternHash != null;

  /// True when any credential is enrolled.
  bool get hasAnyCredential => hasPin || hasPattern;

  SecuritySettings copyWith({
    PinHash? pinHash,
    bool clearPin = false,
    CredentialHash? patternHash,
    bool clearPattern = false,
    BiometricOptions? biometricOptions,
    bool clearBiometricOptions = false,
    AuthType? primaryAuthType,
    bool clearPrimaryAuthType = false,
    bool? intruderSelfieEnabled,
    bool? breakInAlertsEnabled,
    bool? stealthModeEnabled,
    bool? uninstallProtectionEnabled,
    int? maxFailedAttempts,
    Duration? lockoutDuration,
    Duration? unlockSessionWindow,
    int? failedAttempts,
    DateTime? lockedOutUntil,
    bool clearLockout = false,
    int? pinLength,
    bool clearPinLength = false,
    int? lockoutStreak,
    bool? randomizedKeypadEnabled,
  }) {
    return SecuritySettings(
      pinHash: clearPin ? null : (pinHash ?? this.pinHash),
      patternHash: clearPattern ? null : (patternHash ?? this.patternHash),
      biometricOptions: clearBiometricOptions
          ? null
          : (biometricOptions ?? this.biometricOptions),
      primaryAuthType: clearPrimaryAuthType
          ? null
          : (primaryAuthType ?? this.primaryAuthType),
      intruderSelfieEnabled: intruderSelfieEnabled ?? this.intruderSelfieEnabled,
      breakInAlertsEnabled: breakInAlertsEnabled ?? this.breakInAlertsEnabled,
      stealthModeEnabled: stealthModeEnabled ?? this.stealthModeEnabled,
      uninstallProtectionEnabled:
          uninstallProtectionEnabled ?? this.uninstallProtectionEnabled,
      maxFailedAttempts: maxFailedAttempts ?? this.maxFailedAttempts,
      lockoutDuration: lockoutDuration ?? this.lockoutDuration,
      unlockSessionWindow: unlockSessionWindow ?? this.unlockSessionWindow,
      failedAttempts: failedAttempts ?? this.failedAttempts,
      lockedOutUntil:
          clearLockout ? null : (lockedOutUntil ?? this.lockedOutUntil),
      pinLength:
          clearPinLength ? null : (pinLength ?? this.pinLength),
      lockoutStreak: lockoutStreak ?? this.lockoutStreak,
      randomizedKeypadEnabled:
          randomizedKeypadEnabled ?? this.randomizedKeypadEnabled,
      patternVisibilityEnabled:
          patternVisibilityEnabled ?? this.patternVisibilityEnabled,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'pinHash': pinHash?.toJson(),
        'patternHash': patternHash?.toJson(),
        'biometricOptions': biometricOptions?.toJson(),
        'primaryAuthType': primaryAuthType?.storageName,
        'intruderSelfieEnabled': intruderSelfieEnabled,
        'breakInAlertsEnabled': breakInAlertsEnabled,
        'stealthModeEnabled': stealthModeEnabled,
        'uninstallProtectionEnabled': uninstallProtectionEnabled,
        'maxFailedAttempts': maxFailedAttempts,
        'lockoutDurationSeconds': lockoutDuration.inSeconds,
        'unlockSessionWindowSeconds': unlockSessionWindow.inSeconds,
        'failedAttempts': failedAttempts,
        'lockedOutUntilEpochMs': lockedOutUntil?.millisecondsSinceEpoch,
        'pinLength': pinLength,
        'lockoutStreak': lockoutStreak,
        'randomizedKeypadEnabled': randomizedKeypadEnabled,
        'patternVisibilityEnabled': patternVisibilityEnabled,
      };

  factory SecuritySettings.fromJson(Map<String, dynamic> json) =>
      SecuritySettings(
        pinHash: json['pinHash'] == null
            ? null
            : PinHash.fromJson(
                (json['pinHash'] as Map<String, dynamic>).cast<String, dynamic>(),
              ),
        patternHash: json['patternHash'] == null
            ? null
            : CredentialHash.fromJson(
                (json['patternHash'] as Map<String, dynamic>)
                    .cast<String, dynamic>(),
              ),
        biometricOptions: json['biometricOptions'] == null
            ? null
            : BiometricOptions.fromJson(
                (json['biometricOptions'] as Map<String, dynamic>)
                    .cast<String, dynamic>(),
              ),
        primaryAuthType: json['primaryAuthType'] == null
            ? null
            : AuthType.fromStorageName(json['primaryAuthType'] as String),
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
        failedAttempts: json['failedAttempts'] as int? ?? 0,
        lockedOutUntil: json['lockedOutUntilEpochMs'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                json['lockedOutUntilEpochMs'] as int,
              ),
        pinLength: json['pinLength'] as int?,
        lockoutStreak: json['lockoutStreak'] as int? ?? 0,
        randomizedKeypadEnabled:
            json['randomizedKeypadEnabled'] as bool? ?? false,
        patternVisibilityEnabled:
            json['patternVisibilityEnabled'] as bool? ?? true,
      );

  @override
  String toString() => 'SecuritySettings(pin=${hasPin ? 'set' : 'not set'}, '
      'pattern=${hasPattern ? 'set' : 'not set'}, '
      'primary=${primaryAuthType?.name ?? 'none'}, '
      'intruderSelfie=$intruderSelfieEnabled, stealth=$stealthModeEnabled)';
}
