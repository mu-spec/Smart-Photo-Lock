import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/security/credentials/credential_hash.dart';
import 'package:smart_app_lock/security/credentials/pattern_hasher.dart';

void main() {
  group('Pbkdf2PatternHasher', () {
    final Pbkdf2PatternHasher hasher = Pbkdf2PatternHasher(iterations: 500);

    test('accepts the correct pattern', () async {
      final CredentialHash stored = await hasher.hash(const <int>[1, 2, 3, 6]);
      expect(await hasher.verify(const <int>[1, 2, 3, 6], stored), isTrue);
    });

    test('accepts the same shape drawn in reverse (direction-independent)',
        () async {
      final CredentialHash stored = await hasher.hash(const <int>[1, 2, 3, 6]);
      expect(await hasher.verify(const <int>[6, 3, 2, 1], stored), isTrue);
    });

    test('rejects a different shape', () async {
      final CredentialHash stored = await hasher.hash(const <int>[1, 2, 3, 6]);
      expect(await hasher.verify(const <int>[1, 2, 3, 5], stored), isFalse);
    });

    test('produces a unique salt per hash', () async {
      final CredentialHash a = await hasher.hash(const <int>[1, 2, 3, 6]);
      final CredentialHash b = await hasher.hash(const <int>[1, 2, 3, 6]);
      expect(a.salt, isNot(b.salt));
      expect(a.digest, isNot(b.digest));
    });

    test('survives JSON round-trip (storage format)', () async {
      final CredentialHash stored = await hasher.hash(const <int>[1, 4, 7, 8]);
      final CredentialHash restored =
          CredentialHash.fromJson(stored.toJson());
      expect(await hasher.verify(const <int>[1, 4, 7, 8], restored), isTrue);
    });
  });
}
