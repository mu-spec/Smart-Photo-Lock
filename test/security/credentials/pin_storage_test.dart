import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/data/repositories/impl/security_settings_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/security_settings_repository.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/security/credentials/credential_hash.dart';
import 'package:smart_app_lock/security/credentials/credential_hash_policy.dart';
import 'package:smart_app_lock/security/credentials/impl/default_credential_manager.dart';
import 'package:smart_app_lock/security/credentials/impl/default_pin_credential_store.dart';
import 'package:smart_app_lock/security/credentials/pin_storage.dart';
import 'package:smart_app_lock/security/pin_hasher.dart';

/// Phase 2D: secure PIN storage — only derived/verifiable material is
/// persisted; the raw PIN never reaches storage, and corrupted or weakened
/// records fail closed.
void main() {
  late InMemoryLocalDatabase db;
  late SecuritySettingsRepository settings;
  late PinCredentialStore store;
  late Pbkdf2PinHasher hasher;

  setUp(() {
    db = InMemoryLocalDatabase();
    settings = SecuritySettingsRepositoryImpl(db); // plaintext repo: lets us
    // inspect exactly which bytes reach storage.
    store = DefaultPinCredentialStore(
      settings,
      policy: CredentialHashPolicy.lenient,
    );
    hasher = Pbkdf2PinHasher(iterations: 500);
  });

  test('save/load round-trip stores the derived hash only', () async {
    final PinHash hash = await hasher.hash('1234');
    expect((await store.save(hash)).isSuccess, isTrue);

    final PinHash? loaded = (await store.load()).valueOrNull;
    expect(loaded, isNotNull);
    expect(loaded!.salt, hash.salt);
    expect(loaded.digest, hash.digest);
    expect(loaded.iterations, 500);

    // The stored record verifies the original PIN.
    expect(await hasher.verify('1234', loaded), isTrue);
  });

  test('load returns null when no PIN is enrolled', () async {
    final result = await store.load();
    expect(result.isSuccess, isTrue);
    expect(result.valueOrNull, isNull);
  });

  test('THE RAW PIN NEVER REACHES STORAGE', () async {
    const String rawPin = '1234';
    await store.save(await hasher.hash(rawPin));

    // Inspect the exact bytes the repository persisted.
    final String? raw = await db.getSetting('security_settings');
    expect(raw, isNotNull);
    expect(raw, isNot(contains(rawPin)));

    // The digest is derived material — provably not the raw PIN.
    final PinHash? loaded = (await store.load()).valueOrNull;
    expect(loaded!.digest, isNot(rawPin));
    expect(loaded.digest, isNot(contains(rawPin)));

    // And the stored JSON never carries a plaintext credential field.
    expect(raw, isNot(contains('"pin" :')));
    expect(raw, isNot(contains('"rawPin"')));
  });

  test('delete removes the stored credential', () async {
    await store.save(await hasher.hash('1234'));
    expect((await store.load()).valueOrNull, isNotNull);

    await store.delete();
    expect((await store.load()).valueOrNull, isNull);
    expect((await settings.hasPin()).valueOrNull, isFalse);
  });

  test('save refuses hashes below the storage policy', () async {
    final PinCredentialStore strictStore = DefaultPinCredentialStore(
      settings,
      policy: CredentialHashPolicy.strict,
    );
    // A genuine but weak hash: PBKDF2 with only 100 iterations (< 10k).
    final Pbkdf2PinHasher weakHasher = Pbkdf2PinHasher(iterations: 100);
    final PinHash weakHash = await weakHasher.hash('1234');

    final result = await strictStore.save(weakHash);
    expect(result.isFailure, isTrue);
    expect(result.errorOrNull.toString(), contains('iterationsBelowMinimum'));

    // Nothing was persisted.
    expect((await settings.hasPin()).valueOrNull, isFalse);
  });

  test('load fails closed on a corrupted/weakened stored record', () async {
    final PinCredentialStore strictStore = DefaultPinCredentialStore(
      settings,
      policy: CredentialHashPolicy.strict,
    );

    // Plant a weak hash directly in the settings document (simulates a
    // tampered or legacy record).
    final Pbkdf2PinHasher weakHasher = Pbkdf2PinHasher(iterations: 100);
    await settings.saveSettings(
      (await settings.getSettings()).valueOrNull!.copyWith(
        pinHash: await weakHasher.hash('1234'),
      ),
    );

    final result = await strictStore.load();
    expect(result.isFailure, isTrue);
    expect(result.errorOrNull.toString(), contains('iterationsBelowMinimum'));
  });

  test('full manager enrollment keeps the raw PIN out of storage',
      () async {
    // The complete path (manager.enrollPin) must leave zero raw-PIN bytes
    // behind in any persisted document.
    final DefaultCredentialManager manager = DefaultCredentialManager(
      settings: settings,
      pinHasher: hasher,
      pinStore: store,
    );
    await manager.enrollPin('2468');

    final String? raw = await db.getSetting('security_settings');
    expect(raw, isNotNull);
    expect(raw, isNot(contains('2468')));

    // And the enrolled credential verifies the PIN through the store.
    final PinHash? loaded = (await store.load()).valueOrNull;
    expect(loaded, isNotNull);
    expect(await hasher.verify('2468', loaded!), isTrue);
  });
}
