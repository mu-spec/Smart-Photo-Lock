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
/// never receives a fabricated success.
class LocalAuthBiometricService implements BiometricService {
  LocalAuthBiometricService({LocalAuthentication? auth})
      : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<Result<bool>> isSupported() async {
    try {
      return Result.success(await _auth.canCheckBiometrics);
    } catch (e) {
      return Result.failure(e);
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
    } catch (e) {
      return Result.failure(e);
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
    } catch (e) {
      // MissingPluginException (tests), LocalAuthException (canceled,
      // not-enrolled, locked-out, ...) — all fail closed.
      return Result.failure(e);
    }
  }
}
