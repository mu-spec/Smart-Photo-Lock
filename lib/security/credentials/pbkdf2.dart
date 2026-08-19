import 'package:crypto/crypto.dart';

/// Shared PBKDF2 (RFC 2898) core with HMAC-SHA256 as the PRF.
///
/// Used by every credential hasher (PIN, pattern) so the key-derivation
/// behaviour lives in exactly one place.
List<int> pbkdf2Sha256({
  required List<int> password,
  required List<int> salt,
  required int iterations,
  required int keyLength,
}) {
  const int sha256Length = 32;
  final Hmac hmac = Hmac(sha256, password);
  final int blockCount = (keyLength / sha256Length).ceil();
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

/// Timing-safe comparison for fixed-length digests.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  int diff = 0;
  for (int i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
