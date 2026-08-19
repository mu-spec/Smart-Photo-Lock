import '../secret_store.dart';

/// Volatile [SecretStore] for tests and previews.
///
/// Same contract as the Keystore-backed implementation, but values live in
/// memory only — which keeps `flutter test` completely platform-free.
class InMemorySecretStore implements SecretStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<bool> containsKey(String key) async => _values.containsKey(key);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<void> clear() async => _values.clear();
}
