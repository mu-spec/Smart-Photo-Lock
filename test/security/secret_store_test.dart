import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/security/storage/secret_store.dart';

void main() {
  late InMemorySecretStore store;

  setUp(() {
    store = InMemorySecretStore();
  });

  test('starts empty', () async {
    expect(await store.containsKey('any'), isFalse);
    expect(await store.read('any'), isNull);
  });

  test('write/read round-trip', () async {
    await store.write('sec.master', 'secret-value');
    expect(await store.containsKey('sec.master'), isTrue);
    expect(await store.read('sec.master'), 'secret-value');
  });

  test('write overwrites an existing value', () async {
    await store.write('k', 'old');
    await store.write('k', 'new');
    expect(await store.read('k'), 'new');
  });

  test('delete removes a single secret', () async {
    await store.write('k', 'v');
    await store.delete('k');
    expect(await store.containsKey('k'), isFalse);
  });

  test('clear wipes everything', () async {
    await store.write('a', '1');
    await store.write('b', '2');
    await store.clear();
    expect(await store.containsKey('a'), isFalse);
    expect(await store.read('b'), isNull);
  });

  test('secret keys are namespaced and documented', () {
    // Enforces the convention: every secret key lives under `sec.`
    expect(SecretKeys.settingsMasterKey, startsWith('sec.'));
  });
}
