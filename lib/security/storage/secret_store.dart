/// Well-known keys for the sensitive-value tier ([SecretStore]).
abstract final class SecretKeys {
  /// 256-bit master key (base64) that encrypts the security settings
  /// document at rest. Created on first boot; never leaves the secret store.
  static const String settingsMasterKey = 'sec.settings_master_key';

  // Reserved for later phases:
  // static const String backupEncryptionKey = 'sec.backup_key';
  // static const String intruderPhotoKey     = 'sec.intruder_photo_key';
}

/// Sensitive-value storage boundary — the ONLY place sensitive material
/// (encryption keys, future auth tokens) may live.
///
/// The production implementation
/// (`impl/flutter_secure_secret_store.dart`) is backed by the Android
/// Keystore: values are encrypted with a device-bound AES key that never
/// leaves the hardware/OS keystore, and are written via
/// EncryptedSharedPreferences. Nothing sensitive is ever persisted in
/// plaintext on disk.
///
/// **Policy: raw PINs/passwords are NEVER stored anywhere — not here, not in
/// the database, not in preferences.** Only derived values (e.g. a PBKDF2
/// hash) may be persisted, and those live encrypted in the database tier.
abstract interface class SecretStore {
  Future<bool> containsKey(String key);

  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);

  /// Wipes every secret (used by "clear all data" flows).
  Future<void> clear();
}
