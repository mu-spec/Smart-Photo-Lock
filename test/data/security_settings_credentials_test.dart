import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/data/models/security_settings.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/credentials/biometric_options.dart';
import 'package:smart_app_lock/security/credentials/credential_hash.dart';
import 'package:smart_app_lock/security/pin_hasher.dart';

/// Phase 2A: the extended SecuritySettings model round-trips every new
/// credential-state field.
void main() {
  test('new fields round-trip through JSON', () async {
    final Pbkdf2PinHasher pinHasher = Pbkdf2PinHasher(iterations: 200);
    final PinHash pinHash = await pinHasher.hash('1234');

    const CredentialHash patternHash = CredentialHash(
      salt: 'c2FsdA==',
      digest: 'ZGlnZXN0',
      iterations: 500,
      keyLength: 32,
    );

    final SecuritySettings settings = SecuritySettings.defaults.copyWith(
      pinHash: pinHash,
      patternHash: patternHash,
      biometricOptions: const BiometricOptions(
        allowStrongBiometrics: false,
        requireConfirmation: false,
      ),
      primaryAuthType: AuthType.pattern,
      failedAttempts: 4,
      lockedOutUntil: DateTime(2026, 8, 19, 12, 5),
      pinLength: 6,
    );

    final SecuritySettings restored =
        SecuritySettings.fromJson(settings.toJson());

    expect(restored.hasPin, isTrue);
    expect(restored.hasPattern, isTrue);
    expect(restored.pinHash!.digest, pinHash.digest);
    expect(restored.patternHash!.iterations, 500);
    expect(restored.biometricOptions!.allowStrongBiometrics, isFalse);
    expect(restored.biometricOptions!.requireConfirmation, isFalse);
    expect(restored.primaryAuthType, AuthType.pattern);
    expect(restored.failedAttempts, 4);
    expect(restored.lockedOutUntil, DateTime(2026, 8, 19, 12, 5));
    expect(restored.pinLength, 6);
  });

  test('pinLength round-trips and can be cleared', () {
    final SecuritySettings settings =
        SecuritySettings.defaults.copyWith(pinLength: 4);
    expect(SecuritySettings.fromJson(settings.toJson()).pinLength, 4);
    expect(settings.copyWith(clearPinLength: true).pinLength, isNull);
  });

  test('lockoutStreak round-trips and defaults to zero', () {
    expect(SecuritySettings.defaults.lockoutStreak, 0);
    final SecuritySettings settings =
        SecuritySettings.defaults.copyWith(lockoutStreak: 3);
    expect(SecuritySettings.fromJson(settings.toJson()).lockoutStreak, 3);
    // Legacy JSON (Phase 2E) has no field -> defaults to zero.
    final SecuritySettings legacy = SecuritySettings.fromJson(
      <String, dynamic>{'pinLength': 4},
    );
    expect(legacy.lockoutStreak, 0);
  });

  test('randomizedKeypadEnabled defaults off and round-trips', () {
    expect(SecuritySettings.defaults.randomizedKeypadEnabled, isFalse);
    final SecuritySettings enabled =
        SecuritySettings.defaults.copyWith(randomizedKeypadEnabled: true);
    expect(
      SecuritySettings.fromJson(enabled.toJson()).randomizedKeypadEnabled,
      isTrue,
    );
    // Legacy JSON has no field -> defaults to false (accessible default).
    final SecuritySettings legacy =
        SecuritySettings.fromJson(<String, dynamic>{'pinLength': 4});
    expect(legacy.randomizedKeypadEnabled, isFalse);
  });

  test('legacy JSON (Phase 1) still parses with the new defaults', () {
    final SecuritySettings restored = SecuritySettings.fromJson(
      <String, dynamic>{
        'stealthModeEnabled': true,
        'maxFailedAttempts': 5,
        'lockoutDurationSeconds': 30,
        'unlockSessionWindowSeconds': 120,
      },
    );
    expect(restored.stealthModeEnabled, isTrue);
    expect(restored.hasAnyCredential, isFalse);
    expect(restored.patternHash, isNull);
    expect(restored.biometricOptions, isNull);
    expect(restored.primaryAuthType, isNull);
    expect(restored.failedAttempts, 0);
    expect(restored.lockedOutUntil, isNull);
  });

  test('copyWith can clear individual credentials', () {
    final SecuritySettings settings = SecuritySettings.defaults.copyWith(
      pinHash: const PinHash(salt: 's', digest: 'd', iterations: 100, keyLength: 32),
      patternHash:
          const CredentialHash(salt: 's2', digest: 'd2', iterations: 100, keyLength: 32),
      biometricOptions: BiometricOptions.defaults,
      primaryAuthType: AuthType.pin,
      lockedOutUntil: DateTime(2026, 8, 19),
    );

    final SecuritySettings cleared = settings.copyWith(
      clearPin: true,
      clearBiometricOptions: true,
      clearPrimaryAuthType: true,
      clearLockout: true,
    );
    expect(cleared.hasPin, isFalse);
    expect(cleared.hasPattern, isTrue);
    expect(cleared.biometricOptions, isNull);
    expect(cleared.primaryAuthType, isNull);
    expect(cleared.lockedOutUntil, isNull);
  });

  test('hasAnyCredential reflects both secret types', () {
    expect(SecuritySettings.defaults.hasAnyCredential, isFalse);
    final SecuritySettings withPattern = SecuritySettings.defaults.copyWith(
      patternHash: const CredentialHash(
        salt: 's',
        digest: 'd',
        iterations: 100,
        keyLength: 32,
      ),
    );
    expect(withPattern.hasAnyCredential, isTrue);
    expect(withPattern.hasPin, isFalse);
    expect(withPattern.hasPattern, isTrue);
  });
}
