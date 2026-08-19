/// Authenticated-encryption boundary for the security settings document.
///
/// The production implementation ([AesGcmSettingsCipher]) encrypts with
/// AES-256-GCM using a master key held in the [SecretStore] (Android
/// Keystore-backed). GCM provides both confidentiality and integrity — any
/// tampering with the stored ciphertext fails decryption loudly.
abstract interface class SettingsCipher {
  /// Encrypts [plaintext] and returns the self-contained ciphertext string
  /// (nonce + ciphertext + auth tag, base64).
  Future<String> encryptString(String plaintext);

  /// Decrypts a string produced by [encryptString].
  ///
  /// Throws if the ciphertext is malformed or was tampered with.
  Future<String> decryptString(String ciphertext);
}
