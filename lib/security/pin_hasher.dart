import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// PIN hashing boundary.
///
/// Stores only a derived hash — never the PIN itself — so a leaked database
/// does not leak PINs. Used by the pin-setup and lock-challenge phases.
/// This module contains primitives only; it performs no locking.
abstract interface class PinHasher {
  Future<PinHash> hash(String pin);

  Future<bool> verify(String pin, PinHash stored);
}

/// Immutable, serializable result of hashing a PIN (safe to persist).
class PinHash {
  const PinHash({
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

  factory PinHash.fromJson(Map<String, dynamic> json) => PinHash(
        salt: json['salt'] as String,
        digest: json['digest'] as String,
        iterations: json['iterations'] as int,
        keyLength: json['keyLength'] as int,
      );
}

/// PBKDF2-HMAC-SHA256 implementation with a fresh random salt per hash.
///
/// Note: PBKDF2 slows down brute-force attempts on a *leaked* hash. On-device
/// protection is layered on top in a later phase via Android Keystore.
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
  static const int _sha256Length = 32;

  @override
  Future<PinHash> hash(String pin) async {
    final List<int> salt = _generateSalt(_saltLength);
    final List<int> digest =
        _pbkdf2(utf8.encode(pin), salt, iterations, keyLength);
    return PinHash(
      salt: base64Encode(salt),
      digest: base64Encode(digest),
      iterations: iterations,
      keyLength: keyLength,
    );
  }

  @override
  Future<bool> verify(String pin, PinHash stored) async {
    final List<int> candidate = _pbkdf2(
      utf8.encode(pin),
      base64Decode(stored.salt),
      stored.iterations,
      stored.keyLength,
    );
    return _constantTimeEquals(candidate, base64Decode(stored.digest));
  }

  List<int> _generateSalt(int length) {
    final List<int> salt = List<int>.filled(length, 0);
    _random.nextBytes(salt);
    return salt;
  }

  /// PBKDF2 (RFC 2898) with HMAC-SHA256 as the PRF.
  List<int> _pbkdf2(
    List<int> password,
    List<int> salt,
    int iterations,
    int keyLength,
  ) {
    final Hmac hmac = Hmac(sha256, password);
    final int blockCount = (keyLength / _sha256Length).ceil();
    final List<int> output = <int>[];

    for (int block = 1; block <= blockCount; block++) {
      final List<int> blockIndex = <int>[
        (block >> 24) & 0xff,
        (block >> 16) & 0xff,
        (block >> 8) & 0xff,
        block & 0xff,
      ];
      List<int> u = hmac.convert(<int>[...salt, ...blockIndex]).bytes;
      final List<int> t = List<int>.from(u);
      for (int i = 1; i < iterations; i++) {
        u = hmac.convert(u).bytes;
        for (int j = 0; j < t.length; j++) {
          t[j] ^= u[j];
        }
      }
      output.addAll(t);
    }
    return output.sublist(0, keyLength);
  }

  /// Timing-safe comparison (identical lengths only — digests are fixed size).
  bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
