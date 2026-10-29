/// The kinds of platform biometric/credential mechanisms that can be used
/// to authenticate.
enum BiometricKind {
  /// Hardware-backed strong biometrics: fingerprint, face, iris.
  strong,

  /// The device is secure (a device PIN/pattern/password is set).
  ///
  /// H-3: capability information only. The device credential is NEVER
  /// accepted as Smart App Lock authentication.
  deviceCredential,
}

/// Configuration for the biometric authentication method.
///
/// The app stores **no biometric secret** — the OS owns all biometric
/// material. This model only captures *how* biometric unlock may be used.
class BiometricOptions {
  const BiometricOptions({
    this.allowStrongBiometrics = true,
    this.allowDeviceCredential = false,
    this.requireConfirmation = true,
  });

  static const BiometricOptions defaults = BiometricOptions();

  /// Accept hardware-backed biometrics (fingerprint/face/iris).
  final bool allowStrongBiometrics;

  /// Legacy flag, kept only so stored documents keep decoding.
  ///
  /// H-3: defaults to false and is NEVER honoured. The platform bridge
  /// always requests a biometric-only prompt, so a stored `true` (written
  /// by builds before H-3) cannot enable a device-credential fallback.
  final bool allowDeviceCredential;

  /// Require explicit user confirmation after passive biometrics (face).
  /// Mirrors Android's `setConfirmationRequired` behaviour.
  final bool requireConfirmation;

  /// The kinds this configuration permits.
  Set<BiometricKind> get allowedKinds => <BiometricKind>{
        if (allowStrongBiometrics) BiometricKind.strong,
        if (allowDeviceCredential) BiometricKind.deviceCredential,
      };

  BiometricOptions copyWith({
    bool? allowStrongBiometrics,
    bool? allowDeviceCredential,
    bool? requireConfirmation,
  }) {
    return BiometricOptions(
      allowStrongBiometrics:
          allowStrongBiometrics ?? this.allowStrongBiometrics,
      allowDeviceCredential: allowDeviceCredential ?? this.allowDeviceCredential,
      requireConfirmation: requireConfirmation ?? this.requireConfirmation,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'allowStrongBiometrics': allowStrongBiometrics,
        'allowDeviceCredential': allowDeviceCredential,
        'requireConfirmation': requireConfirmation,
      };

  factory BiometricOptions.fromJson(Map<String, dynamic> json) =>
      BiometricOptions(
        allowStrongBiometrics: json['allowStrongBiometrics'] as bool? ?? true,
        allowDeviceCredential: json['allowDeviceCredential'] as bool? ?? false,
        requireConfirmation: json['requireConfirmation'] as bool? ?? true,
      );

  @override
  bool operator ==(Object other) =>
      other is BiometricOptions &&
      other.allowStrongBiometrics == allowStrongBiometrics &&
      other.allowDeviceCredential == allowDeviceCredential &&
      other.requireConfirmation == requireConfirmation;

  @override
  int get hashCode =>
      Object.hash(allowStrongBiometrics, allowDeviceCredential, requireConfirmation);
}
