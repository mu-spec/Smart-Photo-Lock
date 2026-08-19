/// Immutable, serializable result of hashing a credential secret
/// (PIN or pattern) — safe to persist.
///
/// Shared container for every hashed credential type. The `PinHash` alias
/// (see `security/pin_hasher.dart`) keeps Phase 1 code unchanged.
class CredentialHash {
  const CredentialHash({
    required this.salt,
    required this.digest,
    required this.iterations,
    required this.keyLength,
  });

  /// Random salt, base64-encoded.
  final String salt;

  /// Derived key, base64-encoded.
  final String digest;

  /// PBKDF2 iteration count used to produce [digest].
  final int iterations;

  /// Derived key length in bytes.
  final int keyLength;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'salt': salt,
        'digest': digest,
        'iterations': iterations,
        'keyLength': keyLength,
      };

  factory CredentialHash.fromJson(Map<String, dynamic> json) => CredentialHash(
        salt: json['salt'] as String,
        digest: json['digest'] as String,
        iterations: json['iterations'] as int,
        keyLength: json['keyLength'] as int,
      );

  @override
  bool operator ==(Object other) =>
      other is CredentialHash &&
      other.salt == salt &&
      other.digest == digest &&
      other.iterations == iterations &&
      other.keyLength == keyLength;

  @override
  int get hashCode => Object.hash(salt, digest, iterations, keyLength);

  @override
  String toString() =>
      'CredentialHash(iterations: $iterations, keyLength: $keyLength)';
}

/// Backward-compatible name for the hashed PIN credential (Phase 1).
/// Type aliases support constructor and factory invocations, so all
/// existing `PinHash(...)` / `PinHash.fromJson(...)` code keeps working.
typedef PinHash = CredentialHash;
