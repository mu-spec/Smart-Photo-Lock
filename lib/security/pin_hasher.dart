import 'dart:convert';
import 'dart:math';

import 'credentials/credential_hash.dart';
import 'credentials/pbkdf2.dart';

export 'credentials/credential_hash.dart' show PinHash;

/// PIN hashing boundary.
///
/// Stores only a derived hash — never the PIN itself — so a leaked database
/// does not leak PINs. Used by the pin-setup and lock-challenge flows.
/// This module contains primitives only; it performs no locking.
abstract interface class PinHasher {
  Future<PinHash> hash(String pin);

  Future<bool> verify(String pin, PinHash stored);
}

/// PBKDF2-HMAC-SHA256 implementation with a fresh random salt per hash.
///
/// Note: PBKDF2 slows down brute-force attempts on a *leaked* hash. On-device
/// protection is layered on top via Android Keystore (secure storage tier).
class Pbkdf2PinHasher implements PinHasher {
  Pbkdf2PinHasher({
    this.iterations = 50000,
    this.keyLength = 32,
    Random? random,
  }) : _random = random ?? Random.secure();

  /// Work factor — tune in the hardening phase.
  final int iterations;

  /// Derived key length in bytes.
  final int keyLength;

  final Random _random;

  static const int _saltLength = 16;

  @override
  Future<PinHash> hash(String pin) async {
    final List<int> salt = _generateSalt(_saltLength);
    final List<int> digest = pbkdf2Sha256(
      password: utf8.encode(pin),
      salt: salt,
      iterations: iterations,
      keyLength: keyLength,
    );
    return PinHash(
      salt: base64Encode(salt),
      digest: base64Encode(digest),
      iterations: iterations,
      keyLength: keyLength,
    );
  }

  @override
  Future<bool> verify(String pin, PinHash stored) async {
    final List<int> candidate = pbkdf2Sha256(
      password: utf8.encode(pin),
      salt: base64Decode(stored.salt),
      iterations: stored.iterations,
      keyLength: stored.keyLength,
    );
    return constantTimeEquals(candidate, base64Decode(stored.digest));
  }

  List<int> _generateSalt(int length) {
    final List<int> salt = List<int>.filled(length, 0);
    // `Random` (dart:math) has no nextBytes(); draw each byte via
    // nextInt(256). `_random` is `Random.secure()` by default, so the salt
    // is cryptographically secure.
    for (int i = 0; i < length; i++) {
      salt[i] = _random.nextInt(256);
    }
    return salt;
  }
}
