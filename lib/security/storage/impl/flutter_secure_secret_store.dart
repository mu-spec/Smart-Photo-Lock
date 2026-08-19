import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../secret_store.dart';

/// Production [SecretStore] backed by the Android Keystore.
///
/// On Android this uses **EncryptedSharedPreferences**: every value is
/// encrypted with a device-bound AES-256 key held in the Android Keystore
/// (hardware-backed where the device provides TEE/StrongBox). The key
/// material never leaves the OS keystore and values are never written to
/// disk in plaintext.
class FlutterSecureSecretStore implements SecretStore {
  FlutterSecureSecretStore()
      : _storage = const FlutterSecureStorage(
          aOptions: AndroidOptions(
            // Explicit: use the Keystore-backed encrypted preferences
            // implementation (default on modern versions).
            encryptedSharedPreferences: true,
          ),
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
