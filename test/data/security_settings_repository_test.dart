import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/data/models/security_settings.dart';
import 'package:smart_app_lock/data/repositories/impl/security_settings_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/security_settings_repository.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/security/pin_hasher.dart';

void main() {
  late SecuritySettingsRepository repo;

  setUp(() {
    repo = SecuritySettingsRepositoryImpl(InMemoryLocalDatabase());
  });

  test('returns factory defaults when nothing was saved', () async {
    final settings = (await repo.getSettings()).valueOrNull!;
    expect(settings.hasPin, isFalse);
    expect(settings.intruderSelfieEnabled, isFalse);
    expect(settings.stealthModeEnabled, isFalse);
    expect(settings.maxFailedAttempts, 5);
    expect(settings.lockoutDuration, const Duration(seconds: 30));
    expect(settings.unlockSessionWindow, const Duration(minutes: 2));
  });

  test('save/get round-trip preserves every field', () async {
    const SecuritySettings custom = SecuritySettings(
      intruderSelfieEnabled: true,
      breakInAlertsEnabled: true,
      stealthModeEnabled: true,
      uninstallProtectionEnabled: true,
      maxFailedAttempts: 3,
      lockoutDuration: Duration(seconds: 60),
      unlockSessionWindow: Duration(minutes: 5),
    );
    await repo.saveSettings(custom);
    final restored = (await repo.getSettings()).valueOrNull!;
    expect(restored.intruderSelfieEnabled, isTrue);
    expect(restored.breakInAlertsEnabled, isTrue);
    expect(restored.stealthModeEnabled, isTrue);
    expect(restored.uninstallProtectionEnabled, isTrue);
    expect(restored.maxFailedAttempts, 3);
    expect(restored.lockoutDuration, const Duration(seconds: 60));
    expect(restored.unlockSessionWindow, const Duration(minutes: 5));
  });

  test('PIN credential (PinHash) survives the round-trip', () async {
    final Pbkdf2PinHasher hasher = Pbkdf2PinHasher(iterations: 200);
    final PinHash pinHash = await hasher.hash('1234');

    final SecuritySettings withPin =
        SecuritySettings.defaults.copyWith(pinHash: pinHash);
    await repo.saveSettings(withPin);

    final restored = (await repo.getSettings()).valueOrNull!;
    expect(restored.hasPin, isTrue);
    expect(restored.pinHash, isNotNull);
    expect(await hasher.verify('1234', restored.pinHash!), isTrue);
    expect(await hasher.verify('9999', restored.pinHash!), isFalse);
  });

  test('hasPin() reports the credential state', () async {
    expect((await repo.hasPin()).valueOrNull, isFalse);

    final Pbkdf2PinHasher hasher = Pbkdf2PinHasher(iterations: 200);
    final PinHash pinHash = await hasher.hash('1234');
    await repo.saveSettings(
      SecuritySettings.defaults.copyWith(pinHash: pinHash),
    );
    expect((await repo.hasPin()).valueOrNull, isTrue);
  });

  test('copyWith can clear the PIN', () {
    const SecuritySettings withPin = SecuritySettings(
      pinHash: PinHash(salt: 's', digest: 'd', iterations: 100, keyLength: 32),
    );
    final cleared = withPin.copyWith(clearPin: true);
    expect(cleared.hasPin, isFalse);
    expect(cleared.intruderSelfieEnabled, isFalse);
  });

  test('JSON round-trip with defaults intact', () {
    final SecuritySettings restored = SecuritySettings.fromJson(
      SecuritySettings.defaults.toJson(),
    );
    expect(restored.hasPin, isFalse);
    expect(restored.maxFailedAttempts, 5);
    expect(restored.unlockSessionWindow, const Duration(minutes: 2));
  });
}
