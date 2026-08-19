import '../security/credentials/biometric_options.dart';
import '../utilities/result.dart';

/// Bridge to the platform biometric prompt (BiometricPrompt / BiometricManager).
///
/// Contract only — implemented in the biometric phase (backed by a native
/// plugin such as `local_auth` or the biometric options of the secure
/// storage plugin). The OS owns all biometric material; this service only
/// asks it to verify the user.
abstract interface class BiometricService {
  /// True when the hardware + OS can perform biometric authentication.
  Future<Result<bool>> isSupported();

  /// Which kinds are available on this device right now.
  Future<Result<Set<BiometricKind>>> availableKinds();

  /// Prompts the user; resolves true when the OS confirms their identity.
  ///
  /// [options] tailors the prompt (biometric-only vs device-credential
  /// fallback, confirmation requirement); defaults apply when null.
  Future<Result<bool>> authenticate({
    required String reason,
    BiometricOptions? options,
  });
}
