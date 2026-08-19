import '../security/credentials/biometric_options.dart';
import '../utilities/result.dart';

/// User-safe error wrapper for biometric platform failures (Phase 2J QA).
///
/// Carries a stable machine-readable [code] (for logs/tests) and a
/// user-facing [message]. [toString] returns ONLY the safe message — raw
/// exception traces are never exposed to the UI.
class BiometricAuthException implements Exception {
  const BiometricAuthException({required this.code, required this.message});

  /// Platform-level availability problems. When a failure carries one of
  /// these codes, it is NOT an authentication rejection and must not count
  /// as a failed attempt (see CredentialManager).
  static const Set<String> availabilityCodes = <String>{
    'notAvailable',
    'noBiometricHardware',
    'biometricHardwareTemporarilyUnavailable',
    'noBiometricsEnrolled',
    'noCredentialsSet',
    'temporaryLockout',
    'biometricLockout',
    'uiUnavailable',
    'authInProgress',
  };

  /// Stable, non-localized code (e.g. `userCanceled`, `temporaryLockout`).
  final String code;

  /// Safe, user-presentable description.
  final String message;

  bool get isAvailabilityError => availabilityCodes.contains(code);

  @override
  String toString() => message;
}

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
