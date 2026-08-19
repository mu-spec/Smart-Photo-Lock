import 'package:local_auth/local_auth.dart';

import '../../security/credentials/biometric_options.dart';
import '../../utilities/result.dart';
import '../biometric_service.dart';

/// Production [BiometricService] backed by `local_auth` — the official
/// Flutter wrapper over the AndroidX **BiometricPrompt** (authentication)
/// and **BiometricManager** (capability detection) APIs.
///
/// Capability mapping:
///  * `canCheckBiometrics`      → hardware supports biometrics
///  * `getAvailableBiometrics()` → enrolled biometric types (face,
///    fingerprint, iris, strong, weak)
///  * `isDeviceSupported()`      → the system can use device credentials
///    (PIN/pattern/password) as a prompt fallback
///
/// Fails closed: every platform error surfaces as a [Failure] — the caller
/// never receives a fabricated success. Platform exceptions are mapped to
/// user-safe [BiometricAuthException]s; raw traces never leave this layer.
class LocalAuthBiometricService implements BiometricService {
  LocalAuthBiometricService({LocalAuthentication? auth})
      : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<Result<bool>> isSupported() async {
    try {
      return Result.success(await _auth.canCheckBiometrics);
    } on LocalAuthException catch (e) {
      return Result.failure(mapBiometricError(e));
    } catch (e) {
      return Result.failure(mapBiometricError(e));
    }
  }

  @override
  Future<Result<Set<BiometricKind>>> availableKinds() async {
    try {
      final Set<BiometricKind> kinds = <BiometricKind>{};
      final List<BiometricType> types = await _auth.getAvailableBiometrics();
      if (types.isNotEmpty) {
        kinds.add(BiometricKind.strong);
      }
      if (await _auth.isDeviceSupported()) {
        kinds.add(BiometricKind.deviceCredential);
      }
      return Result.success(kinds);
    } on LocalAuthException catch (e) {
      return Result.failure(mapBiometricError(e));
    } catch (e) {
      return Result.failure(mapBiometricError(e));
    }
  }

  @override
  Future<Result<bool>> authenticate({
    required String reason,
    BiometricOptions? options,
  }) async {
    final BiometricOptions opts = options ?? BiometricOptions.defaults;
    try {
      final bool ok = await _auth.authenticate(
        localizedReason: reason,
        // Device-credential fallback allowed? If not, biometric-only prompt.
        biometricOnly: !opts.allowDeviceCredential,
        // Android: maps to BiometricPrompt.setConfirmationRequired.
        sensitiveTransaction: opts.requireConfirmation,
      );
      return Result.success(ok);
    } on LocalAuthException catch (e) {
      // Canceled / not-enrolled / locked-out / ... — all fail closed, with
      // a user-safe, code-carrying error.
      return Result.failure(mapBiometricError(e));
    } catch (e) {
      // MissingPluginException (tests), unexpected platform errors.
      return Result.failure(mapBiometricError(e));
    }
  }
}

/// Maps a platform biometric error into a user-safe [BiometricAuthException].
///
/// Every [LocalAuthExceptionCode] gets a stable `code` and a presentable
/// message; unknown errors collapse to `unknown` with a generic message.
/// Raw descriptions/details are deliberately dropped.
BiometricAuthException mapBiometricError(Object error) {
  if (error is BiometricAuthException) {
    return error;
  }
  if (error is LocalAuthException) {
    final (String code, String message) = switch (error.code) {
      LocalAuthExceptionCode.authInProgress => (
          'authInProgress',
          'An authentication is already in progress.',
        ),
      LocalAuthExceptionCode.uiUnavailable => (
          'uiUnavailable',
          'The biometric prompt is unavailable right now.',
        ),
      LocalAuthExceptionCode.userCanceled => (
          'userCanceled',
          'Biometric authentication was cancelled.',
        ),
      LocalAuthExceptionCode.timeout => (
          'timeout',
          'Biometric authentication timed out.',
        ),
      LocalAuthExceptionCode.systemCanceled => (
          'systemCanceled',
          'Biometric authentication was cancelled by the system.',
        ),
      LocalAuthExceptionCode.noCredentialsSet => (
          'noCredentialsSet',
          'No device credential is configured.',
        ),
      LocalAuthExceptionCode.noBiometricsEnrolled => (
          'noBiometricsEnrolled',
          'No biometric credential is enrolled on this device.',
        ),
      LocalAuthExceptionCode.noBiometricHardware => (
          'noBiometricHardware',
          'Biometric hardware is not available.',
        ),
      LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable => (
          'biometricHardwareTemporarilyUnavailable',
          'Biometric hardware is temporarily unavailable.',
        ),
      LocalAuthExceptionCode.temporaryLockout => (
          'temporaryLockout',
          'Biometric authentication is temporarily locked out.',
        ),
      LocalAuthExceptionCode.biometricLockout => (
          'biometricLockout',
          'Biometric authentication is locked. Unlock with another method.',
        ),
      LocalAuthExceptionCode.userRequestedFallback => (
          'userRequestedFallback',
          'Use your PIN or pattern instead.',
        ),
      LocalAuthExceptionCode.deviceError => (
          'deviceError',
          'Biometric authentication failed on this device.',
        ),
      LocalAuthExceptionCode.unknownError => (
          'unknownError',
          'Biometric authentication failed.',
        ),
    };
    return BiometricAuthException(code: code, message: message);
  }
  return const BiometricAuthException(
    code: 'unknown',
    message: 'Biometric authentication failed.',
  );
}
