import 'dart:convert';
import 'dart:math';

import 'credential_hash.dart';
import 'pattern_codec.dart';
import 'pbkdf2.dart';

/// Pattern hashing boundary.
///
/// Same contract and threat model as [PinHasher]: only a derived hash is
/// stored. The hash covers the **exact ordered node sequence** — direction
/// and order are part of the credential, so the reverse of a pattern (or
/// any reordered drawing) does not verify.
abstract interface class PatternHasher {
  Future<CredentialHash> hash(List<int> nodes);

  Future<bool> verify(List<int> nodes, CredentialHash stored);
}

/// PBKDF2-HMAC-SHA256 over the ordered pattern serialization, with a fresh
/// random salt per hash.
///
/// Scheme versioning (QA fix, direction sensitivity):
///  * version `2` — hashes the exact ordered sequence (`1-2-3-6`).
///  * records without a version marker were created by the pre-fix scheme
///    (canonicalized/direction-insensitive). They are **ambiguous** (the
///    originally drawn orientation cannot be recovered), so verification
///    fails closed for them and the user must set the pattern again — no
///    fallback ever accepts both directions.
class Pbkdf2PatternHasher implements PatternHasher {
  Pbkdf2PatternHasher({
    this.iterations = 50000,
    this.keyLength = 32,
    Random? random,
  }) : _random = random ?? Random.secure();

  /// Current pattern hash scheme version (ordered/direction-sensitive).
  static const int patternSchemeVersion = 2;

  /// Work factor — kept aligned with [Pbkdf2PinHasher].
  final int iterations;

  /// Derived key length in bytes.
  final int keyLength;

  final Random _random;

  static const int _saltLength = 16;

  /// True when [stored] was produced by the legacy direction-insensitive
  /// scheme (or is otherwise unversioned) and must be re-enrolled.
  static bool isLegacyHash(CredentialHash stored) =>
      stored.schemeVersion != patternSchemeVersion;

  @override
  Future<CredentialHash> hash(List<int> nodes) async {
    final List<int> salt = _generateSalt(_saltLength);
    final List<int> digest = pbkdf2Sha256(
      password: utf8.encode(PatternCodec.serialize(nodes)),
      salt: salt,
      iterations: iterations,
      keyLength: keyLength,
    );
    return CredentialHash(
      salt: base64Encode(salt),
      digest: base64Encode(digest),
      iterations: iterations,
      keyLength: keyLength,
      schemeVersion: patternSchemeVersion,
    );
  }

  @override
  Future<bool> verify(List<int> nodes, CredentialHash stored) async {
    if (isLegacyHash(stored)) {
      // Fail closed: legacy hashes are direction-ambiguous. Re-enrollment
      // required — never accept both orientations.
      return false;
    }
    final List<int> candidate = pbkdf2Sha256(
      password: utf8.encode(PatternCodec.serialize(nodes)),
      salt: base64Decode(stored.salt),
      iterations: stored.iterations,
      keyLength: stored.keyLength,
    );
    return constantTimeEquals(candidate, base64Decode(stored.digest));
  }

  List<int> _generateSalt(int length) {
    final List<int> salt = List<int>.filled(length, 0);
    for (int i = 0; i < length; i++) {
      salt[i] = _random.nextInt(256);
    }
    return salt;
  }
}
