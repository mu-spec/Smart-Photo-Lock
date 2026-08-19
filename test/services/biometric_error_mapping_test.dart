import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';

import 'package:smart_app_lock/services/biometric_service.dart';
import 'package:smart_app_lock/services/impl/local_auth_biometric_service.dart';

/// Phase 2J QA: platform biometric errors are mapped to user-safe,
/// code-carrying exceptions — raw traces never leak to the UI, and
/// availability problems are distinguishable from rejections.
void main() {
  group('mapBiometricError', () {
    test('maps every LocalAuthExceptionCode to a safe message', () {
      for (final LocalAuthExceptionCode code in LocalAuthExceptionCode.values) {
        final BiometricAuthException mapped = mapBiometricError(
          LocalAuthException(code: code, description: 'raw-detail'),
        );
        expect(mapped.code, isNotEmpty);
        expect(mapped.message, isNotEmpty);
        // The safe message is a fixed, user-presentable string.
        expect(mapped.message, isNot(contains('raw-detail')));
      }
    });

    test('availability codes are classified as availability errors', () {
      expect(
        mapBiometricError(
          const LocalAuthException(code: LocalAuthExceptionCode.noBiometricHardware),
        ).isAvailabilityError,
        isTrue,
      );
      expect(
        mapBiometricError(
          const LocalAuthException(code: LocalAuthExceptionCode.noBiometricsEnrolled),
        ).isAvailabilityError,
        isTrue,
      );
      expect(
        mapBiometricError(
          const LocalAuthException(code: LocalAuthExceptionCode.temporaryLockout),
        ).isAvailabilityError,
        isTrue,
      );
      expect(
        mapBiometricError(
          const LocalAuthException(code: LocalAuthExceptionCode.biometricLockout),
        ).isAvailabilityError,
        isTrue,
      );
    });

    test('user cancellation is NOT an availability error (it counts)', () {
      final BiometricAuthException canceled = mapBiometricError(
        const LocalAuthException(code: LocalAuthExceptionCode.userCanceled),
      );
      expect(canceled.code, 'userCanceled');
      expect(canceled.isAvailabilityError, isFalse);
    });

    test('unknown non-platform errors collapse to a generic safe error', () {
      final BiometricAuthException mapped = mapBiometricError(
        StateError('internal detail that must not leak'),
      );
      expect(mapped.code, 'unknown');
      expect(mapped.message, 'Biometric authentication failed.');
      expect(mapped.toString(), mapped.message); // toString is the safe text
    });

    test('already-mapped exceptions pass through unchanged', () {
      const BiometricAuthException original = BiometricAuthException(
        code: 'userCanceled',
        message: 'Biometric authentication was cancelled.',
      );
      expect(mapBiometricError(original), same(original));
    });

    test('toString never exposes raw traces', () {
      final BiometricAuthException mapped = mapBiometricError(
        const LocalAuthException(
          code: LocalAuthExceptionCode.deviceError,
          description: 'CERTIFICATE_FAILURE_0x8123',
          details: 'secret-trace',
        ),
      );
      expect(mapped.toString(), isNot(contains('CERTIFICATE')));
      expect(mapped.toString(), isNot(contains('secret-trace')));
    });
  });

  group('LocalAuthBiometricService (fail closed, safe errors)', () {
    final LocalAuthBiometricService service = LocalAuthBiometricService();

    test('isSupported fails closed with a mapped error (no platform)', () async {
      final result = await service.isSupported();
      expect(result.isFailure, isTrue);
      expect(result.errorOrNull, isA<BiometricAuthException>());
      expect(result.errorOrNull.toString(), isNot(contains('Exception')));
    });

    test('availableKinds fails closed with a mapped error (no platform)',
        () async {
      final result = await service.availableKinds();
      expect(result.isFailure, isTrue);
      expect(result.errorOrNull, isA<BiometricAuthException>());
    });

    test('authenticate fails closed with a mapped error (no platform)',
        () async {
      final result =
          await service.authenticate(reason: 'Unlock Smart App Lock');
      expect(result.isFailure, isTrue);
      expect(result.errorOrNull, isA<BiometricAuthException>());
    });
  });
}
