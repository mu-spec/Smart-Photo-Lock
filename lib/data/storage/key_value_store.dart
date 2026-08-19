/// Raw key-value persistence boundary (the "preferences" tier).
///
/// The production implementation wraps `shared_preferences`; tests and
/// previews use the in-memory implementation
/// (`data/storage/impl/in_memory_key_value_store.dart`). All reads/writes
/// are async so swapping implementations never changes call sites.
abstract interface class KeyValueStore {
  Future<bool?> getBool(String key);

  Future<int?> getInt(String key);

  Future<String?> getString(String key);

  Future<void> setBool(String key, bool value);

  Future<void> setInt(String key, int value);

  Future<void> setString(String key, String value);

  Future<void> remove(String key);

  Future<void> clear();
}
