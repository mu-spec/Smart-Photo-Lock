/// The authentication methods Smart App Lock supports.
enum AuthType {
  pin(
    label: 'PIN',
    description: '4-6 digit numeric code',
    canBePrimary: true,
  ),
  pattern(
    label: 'Pattern',
    description: 'Draw a shape on a 3x3 grid',
    canBePrimary: true,
  ),
  biometric(
    label: 'Biometric',
    description: 'Fingerprint, face, or device credential',
    canBePrimary: false,
  );

  const AuthType({
    required this.label,
    required this.description,
    required this.canBePrimary,
  });

  /// Human-readable name shown in setup screens.
  final String label;

  final String description;

  /// True for credential types that can act as the primary fallback
  /// secret. Biometric is always an *accelerator* on top of a primary
  /// secret (the OS owns the biometric material, we store nothing).
  final bool canBePrimary;

  /// Serialized name used by persistence layers.
  String get storageName => name;

  static AuthType fromStorageName(String name) => AuthType.values.byName(name);
}
