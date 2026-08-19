import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/security/credentials/auth_type.dart';

void main() {
  test('auth types expose labels and descriptions', () {
    expect(AuthType.pin.label, 'PIN');
    expect(AuthType.pattern.label, 'Pattern');
    expect(AuthType.biometric.label, 'Biometric');
    expect(AuthType.pin.description, contains('4-6'));
    expect(AuthType.pattern.description, contains('3x3'));
  });

  test('pin and pattern can be primary; biometric cannot', () {
    expect(AuthType.pin.canBePrimary, isTrue);
    expect(AuthType.pattern.canBePrimary, isTrue);
    expect(AuthType.biometric.canBePrimary, isFalse);
  });

  test('storage names round-trip', () {
    for (final AuthType type in AuthType.values) {
      expect(AuthType.fromStorageName(type.storageName), type);
    }
  });

  test('unknown storage names throw', () {
    expect(() => AuthType.fromStorageName('voice'), throwsArgumentError);
  });
}
