import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../secret_store.dart';

/// Production [SecretStore] backed by the Android Keystore.
///
/// flutter_secure_storage v11 dropped the legacy
/// `encryptedSharedPreferences` flag together with the deprecated
/// EncryptedSharedPreferences backend (removed upstream by androidx).
/// Its current Android implementation is **Keystore-backed by default**:
///
///  * secret key protection: RSA/ECB/OAEPWithSHA-256AndMGF1Padding key
///    wrapping in the Android Keystore (hardware-backed where the device
///    provides TEE/StrongBox);
///  * data encryption: AES/GCM/NoPadding;
///  * supported from API 23+.
///
/// `AndroidOptions()` therefore needs no extra flags to be secure — every
/// value is encrypted with a device-bound key that never leaves the OS
/// keystore, and nothing is written to disk in plaintext.
class FlutterSecureSecretStore implements SecretStore {
  FlutterSecureSecretStore()
      : _storage = const FlutterSecureStorage(
          aOptions: AndroidOptions(),
        );

  final FlutterSecureStorage _storage;

  @override
  Future<bool> containsKey(String key) => _storage.containsKey(key: key);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<void> clear() => _storage.deleteAll();
}
