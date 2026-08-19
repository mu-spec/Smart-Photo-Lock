import 'dart:convert';
import 'dart:math';

import 'credential_hash.dart';
import 'pattern_codec.dart';
import 'pbkdf2.dart';

/// Pattern hashing boundary.
///
/// Same contract and threat model as [PinHasher]: only a derived hash is
/// stored, and the hash covers the *canonical* shape so drawing direction
/// does not affect verification.
abstract interface class PatternHasher {
  Future<CredentialHash> hash(List<int> nodes);

  Future<bool> verify(List<int> nodes, CredentialHash stored);
}

/// PBKDF2-HMAC-SHA256 over the canonical pattern serialization, with a
/// fresh random salt per hash.
class Pbkdf2PatternHasher implements PatternHasher {
  Pbkdf2PatternHasher({
    this.iterations = 50000,
    this.keyLength = 32,
    Random? random,
  }) : _random = random ?? Random.secure();

  /// Work factor — kept aligned with [Pbkdf2PinHasher].
  final int iterations;

  /// Derived key length in bytes.
  final int keyLength;

  final Random _random;

  static const int _saltLength = 16;

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
    );
  }

  @override
  Future<bool> verify(List<int> nodes, CredentialHash stored) async {
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
