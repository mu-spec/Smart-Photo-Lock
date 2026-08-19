import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/services/impl/local_auth_biometric_service.dart';

/// Phase 2J: the platform service fails closed when no platform is present
/// (flutter test runs without Android plugins) — capability checks and
/// authentication must surface Failures, never fabricated successes.
void main() {
  final LocalAuthBiometricService service = LocalAuthBiometricService();

  test('isSupported fails closed without a platform', () async {
    final result = await service.isSupported();
    expect(result.isFailure, isTrue);
  });

  test('availableKinds fails closed without a platform', () async {
    final result = await service.availableKinds();
    expect(result.isFailure, isTrue);
  });

  test('authenticate fails closed without a platform', () async {
    final result =
        await service.authenticate(reason: 'Unlock Smart App Lock');
    expect(result.isFailure, isTrue);
  });
}
