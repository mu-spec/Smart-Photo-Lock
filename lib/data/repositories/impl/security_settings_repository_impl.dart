import 'dart:convert';

import '../../../security/encryption/settings_cipher.dart';
import '../../../utilities/result.dart';
import '../../models/security_settings.dart';
import '../../storage/local_database.dart';
import '../security_settings_repository.dart';

/// [SecuritySettingsRepository] over the [LocalDatabase] with
/// **authenticated encryption at rest**.
///
/// Storage format in the `security_settings` key-value table:
///  * encrypted (default, since Phase 1F):
///    `enc:v1:<base64(nonce || AES-256-GCM ciphertext || auth tag)>`
///  * legacy plaintext JSON (written by Phase 1E) is still *readable* so
///    existing installs upgrade seamlessly — and is re-encrypted on the
///    next save.
///
/// **No raw PIN or password is ever stored.** The settings document holds
/// only the PBKDF2 [PinHash] (see `security/pin_hasher.dart`), and that
/// document is encrypted with a master key that lives exclusively in the
/// Android Keystore-backed [SecretStore].
class SecuritySettingsRepositoryImpl implements SecuritySettingsRepository {
  SecuritySettingsRepositoryImpl(
    this._database, {
    SettingsCipher? cipher,
  }) : _cipher = cipher;

  static const String _storageKey = 'security_settings';
  static const String _encryptedPrefix = 'enc:v1:';

  final LocalDatabase _database;
  final SettingsCipher? _cipher;

  @override
  Future<Result<SecuritySettings>> getSettings() async {
    try {
      final String? raw = await _database.getSetting(_storageKey);
      if (raw == null) {
        return Result.success(SecuritySettings.defaults);
      }

      final String jsonText;
      if (raw.startsWith(_encryptedPrefix)) {
        final SettingsCipher? cipher = _cipher;
        if (cipher == null) {
          // Encrypted data but no secure storage available — refuse to
          // return anything (fails closed, never falls back to guessing).
          return Result.failure(
            StateError('Secure storage unavailable; cannot decrypt settings.'),
          );
        }
        jsonText = await cipher.decryptString(
          raw.substring(_encryptedPrefix.length),
        );
      } else {
        // Legacy plaintext document from Phase 1E.
        jsonText = raw;
      }

      final Map<String, dynamic> json =
          jsonDecode(jsonText) as Map<String, dynamic>;
      return Result.success(
        SecuritySettings.fromJson(json.cast<String, dynamic>()),
      );
    } catch (e) {
      // Includes tamper-detection failures from the cipher (GCM auth).
      return Result.failure(e);
    }
  }

  @override
  Future<Result<void>> saveSettings(SecuritySettings settings) async {
    try {
      final String json = jsonEncode(settings.toJson());
      final SettingsCipher? cipher = _cipher;
      final String stored = cipher == null
          ? json // only used by legacy/plaintext tests — production always encrypts
          : '$_encryptedPrefix${await cipher.encryptString(json)}';
      await _database.setSetting(_storageKey, stored);
      return Result.success(null);
    } catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<bool>> hasPin() async {
    final Result<SecuritySettings> settings = await getSettings();
    return settings.fold(
      (SecuritySettings s) => Result.success(s.hasPin),
      Result.failure,
    );
  }
}
