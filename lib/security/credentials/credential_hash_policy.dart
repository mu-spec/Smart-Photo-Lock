import 'dart:convert';

import 'credential_hash.dart';

/// Why a persisted credential hash was rejected.
enum HashPolicyViolation {
  /// The PBKDF2 work factor is below the enforced minimum.
  iterationsBelowMinimum,

  /// The derived key length differs from the configured value.
  unexpectedKeyLength,

  /// The salt is too short for the required entropy.
  saltTooShort,

  /// The digest length does not match [CredentialHash.keyLength].
  digestLengthMismatch,

  /// Salt or digest is not valid base64.
  malformedEncoding,
}

/// Storage security policy for persisted credential hashes.
///
/// Every hash read from storage is validated before use (defense in depth):
/// a corrupted, truncated, or deliberately weakened record fails **closed**
/// instead of silently weakening authentication.
class CredentialHashPolicy {
  const CredentialHashPolicy({
    this.minIterations = 1,
    this.expectedKeyLength = 32,
    this.minSaltLengthBytes = 16,
  });

  /// Test-friendly policy: structural checks only (encoding, lengths).
  static const CredentialHashPolicy lenient = CredentialHashPolicy();

  /// Production policy: requires a real PBKDF2 work factor (our hashers use
  /// 50k), 32-byte keys and full-entropy salts.
  static const CredentialHashPolicy strict = CredentialHashPolicy(
    minIterations: 10000,
    expectedKeyLength: 32,
    minSaltLengthBytes: 16,
  );

  /// Minimum acceptable PBKDF2 iteration count.
  final int minIterations;

  /// Required derived key length in bytes.
  final int expectedKeyLength;

  /// Minimum salt length in bytes.
  final int minSaltLengthBytes;

  /// Returns null when [hash] satisfies the policy, otherwise the
  /// first violated rule.
  HashPolicyViolation? validate(CredentialHash hash) {
    if (hash.iterations < minIterations) {
      return HashPolicyViolation.iterationsBelowMinimum;
    }
    if (hash.keyLength != expectedKeyLength) {
      return HashPolicyViolation.unexpectedKeyLength;
    }

    final List<int> salt;
    try {
      salt = base64Decode(hash.salt);
    } on FormatException {
      return HashPolicyViolation.malformedEncoding;
    }
    if (salt.length < minSaltLengthBytes) {
      return HashPolicyViolation.saltTooShort;
    }

    final List<int> digest;
    try {
      digest = base64Decode(hash.digest);
    } on FormatException {
      return HashPolicyViolation.malformedEncoding;
    }
    if (digest.length != hash.keyLength) {
      return HashPolicyViolation.digestLengthMismatch;
    }

    return null;
  }
}
