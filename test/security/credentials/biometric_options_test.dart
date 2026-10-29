import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/security/credentials/biometric_options.dart';

void main() {
  // H-3: the device credential is never a default (and the platform
  // bridge never honours it at all).
  test('defaults allow strong biometrics only, never the device credential',
      () {
    const BiometricOptions options = BiometricOptions.defaults;
    expect(options.allowStrongBiometrics, isTrue);
    expect(options.allowDeviceCredential, isFalse);
    expect(options.requireConfirmation, isTrue);
    expect(options.allowedKinds, <BiometricKind>{BiometricKind.strong});
  });

  test('allowedKinds reflects the configuration', () {
    const BiometricOptions options = BiometricOptions(
      allowStrongBiometrics: false,
      allowDeviceCredential: true,
    );
    expect(options.allowedKinds, <BiometricKind>{BiometricKind.deviceCredential});
  });

  test('copyWith replaces individual fields', () {
    const BiometricOptions base = BiometricOptions.defaults;
    final BiometricOptions changed = base.copyWith(requireConfirmation: false);
    expect(changed.requireConfirmation, isFalse);
    expect(changed.allowStrongBiometrics, isTrue);
    expect(changed.allowDeviceCredential, isFalse);
  });

  test('JSON round-trip preserves fields', () {
    const BiometricOptions options = BiometricOptions(
      allowStrongBiometrics: false,
      allowDeviceCredential: true,
      requireConfirmation: false,
    );
    final BiometricOptions restored =
        BiometricOptions.fromJson(options.toJson());
    expect(restored, options);
  });

  test('JSON with missing keys falls back to defaults', () {
    final BiometricOptions restored =
        BiometricOptions.fromJson(<String, dynamic>{});
    expect(restored, BiometricOptions.defaults);
  });
}
