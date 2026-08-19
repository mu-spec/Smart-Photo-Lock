import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/data/models/security_settings.dart';
import 'package:smart_app_lock/data/repositories/impl/security_settings_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/security_settings_repository.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/data/storage/local_database.dart';
import 'package:smart_app_lock/security/encryption/settings_cipher_impl.dart';
import 'package:smart_app_lock/security/pin_hasher.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';

void main() {
  late InMemoryLocalDatabase db;
  late SecuritySettingsRepository repo;

  setUp(() {
    db = InMemoryLocalDatabase();
    repo = SecuritySettingsRepositoryImpl(
      db,
      cipher: AesGcmSettingsCipher(InMemorySecretStore()),
    );
  });

  test('settings are stored encrypted — never as plaintext JSON', () async {
    await repo.saveSettings(
      SecuritySettings.defaults.copyWith(stealthModeEnabled: true),
    );

    final String? raw = await db.getSetting('security_settings');
    expect(raw, isNotNull);
    expect(raw, startsWith('enc:v1:'));
    // The plaintext JSON (and its field names) must not appear in storage.
    expect(raw, isNot(contains('stealthModeEnabled')));
    expect(raw, isNot(contains('"pinHash"')));
  });

  test('encrypted round-trip preserves every field', () async {
    final SecuritySettings custom = SecuritySettings.defaults.copyWith(
      intruderSelfieEnabled: true,
      breakInAlertsEnabled: true,
      stealthModeEnabled: true,
      uninstallProtectionEnabled: true,
      maxFailedAttempts: 3,
      lockoutDuration: const Duration(seconds: 60),
      unlockSessionWindow: const Duration(minutes: 5),
    );
    await repo.saveSettings(custom);
    final SecuritySettings restored = (await repo.getSettings()).valueOrNull!;

    expect(restored.intruderSelfieEnabled, isTrue);
    expect(restored.breakInAlertsEnabled, isTrue);
    expect(restored.stealthModeEnabled, isTrue);
    expect(restored.uninstallProtectionEnabled, isTrue);
    expect(restored.maxFailedAttempts, 3);
    expect(restored.lockoutDuration, const Duration(seconds: 60));
    expect(restored.unlockSessionWindow, const Duration(minutes: 5));
  });

  test('PIN credential survives the encrypted round-trip', () async {
    final Pbkdf2PinHasher hasher = Pbkdf2PinHasher(iterations: 200);
    final PinHash pinHash = await hasher.hash('1234');
    await repo.saveSettings(
      SecuritySettings.defaults.copyWith(pinHash: pinHash),
    );

    final SecuritySettings restored = (await repo.getSettings()).valueOrNull!;
    expect(restored.hasPin, isTrue);
    expect(await hasher.verify('1234', restored.pinHash!), isTrue);
    expect(await hasher.verify('9999', restored.pinHash!), isFalse);
    expect((await repo.hasPin()).valueOrNull, isTrue);
  });

  test('legacy plaintext document (Phase 1E) is still readable', () async {
    // Simulate data written by the pre-encryption version.
    await db.setSetting(
      'security_settings',
      '{"stealthModeEnabled":true,"maxFailedAttempts":5,'
      '"lockoutDurationSeconds":30,"unlockSessionWindowSeconds":120}',
    );
    final SecuritySettings settings = (await repo.getSettings()).valueOrNull!;
    expect(settings.stealthModeEnabled, isTrue);
    expect(settings.maxFailedAttempts, 5);
    expect(settings.hasPin, isFalse);
  });

  test('tampered ciphertext fails closed with a Result failure', () async {
    await repo.saveSettings(SecuritySettings.defaults);

    // Corrupt the stored value by flipping a character in the payload.
    final String raw = (await db.getSetting('security_settings'))!;
    final int mid = raw.length ~/ 2;
    final String tampered = raw.replaceRange(
      mid,
      mid + 1,
      raw[mid] == 'A' ? 'B' : 'A',
    );
    await db.setSetting('security_settings', tampered);

    final result = await repo.getSettings();
    expect(result.isFailure, isTrue);
  });

  test('encrypted data without a cipher fails closed', () async {
    // Store encrypted data, then read through a cipherless repository
    // (e.g. a misconfigured container). Must refuse — never guess.
    final InMemoryLocalDatabase otherDb = InMemoryLocalDatabase();
    final SecuritySettingsRepository writer = SecuritySettingsRepositoryImpl(
      otherDb,
      cipher: AesGcmSettingsCipher(InMemorySecretStore()),
    );
    await writer.saveSettings(SecuritySettings.defaults);

    final SecuritySettingsRepository reader =
        SecuritySettingsRepositoryImpl(otherDb); // no cipher
    final result = await reader.getSettings();
    expect(result.isFailure, isTrue);
  });

  test('raw PIN never appears in storage', () async {
    final Pbkdf2PinHasher hasher = Pbkdf2PinHasher(iterations: 200);
    await repo.saveSettings(
      SecuritySettings.defaults.copyWith(pinHash: await hasher.hash('2468')),
    );
    final String? raw = await db.getSetting('security_settings');
    expect(raw, isNot(contains('2468')));
    final SecuritySettings restored = (await repo.getSettings()).valueOrNull!;
    expect(await hasher.verify('2468', restored.pinHash!), isTrue);
  });
}
