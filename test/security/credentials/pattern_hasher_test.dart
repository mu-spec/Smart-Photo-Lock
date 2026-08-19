import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/security/credentials/credential_hash.dart';
import 'package:smart_app_lock/security/credentials/pattern_hasher.dart';

void main() {
  group('Pbkdf2PatternHasher (ordered, direction-sensitive)', () {
    final Pbkdf2PatternHasher hasher = Pbkdf2PatternHasher(iterations: 500);

    test('accepts the exact ordered sequence', () async {
      final CredentialHash stored = await hasher.hash(const <int>[1, 2, 3, 6]);
      expect(await hasher.verify(const <int>[1, 2, 3, 6], stored), isTrue);
    });

    test('REJECTS the reverse of the saved pattern', () async {
      final CredentialHash stored = await hasher.hash(const <int>[1, 2, 3, 6]);
      expect(await hasher.verify(const <int>[6, 3, 2, 1], stored), isFalse);
    });

    test('REJECTS a different ordering', () async {
      final CredentialHash stored = await hasher.hash(const <int>[1, 2, 3, 6]);
      expect(await hasher.verify(const <int>[1, 3, 2, 6], stored), isFalse);
    });

    test('produces a unique salt per hash', () async {
      final CredentialHash a = await hasher.hash(const <int>[1, 2, 3, 6]);
      final CredentialHash b = await hasher.hash(const <int>[1, 2, 3, 6]);
      expect(a.salt, isNot(b.salt));
      expect(a.digest, isNot(b.digest));
    });

    test('hashes carry the current ordered scheme version', () async {
      final CredentialHash stored = await hasher.hash(const <int>[1, 4, 7, 8]);
      expect(stored.schemeVersion, Pbkdf2PatternHasher.patternSchemeVersion);
      expect(Pbkdf2PatternHasher.isLegacyHash(stored), isFalse);
    });

    test('survives JSON round-trip (storage format)', () async {
      final CredentialHash stored = await hasher.hash(const <int>[1, 4, 7, 8]);
      final CredentialHash restored =
          CredentialHash.fromJson(stored.toJson());
      expect(await hasher.verify(const <int>[1, 4, 7, 8], restored), isTrue);
      expect(await hasher.verify(const <int>[8, 7, 4, 1], restored), isFalse);
      expect(Pbkdf2PatternHasher.isLegacyHash(restored), isFalse);
    });
  });

  group('legacy (direction-insensitive) records fail closed', () {
    final Pbkdf2PatternHasher hasher = Pbkdf2PatternHasher(iterations: 500);

    test('an unversioned hash is detected as legacy', () {
      const CredentialHash legacy = CredentialHash(
        salt: 'c2FsdHNhbHRzYWx0c2FsdA==',
        digest: 'ZGlmZmllcg==',
        iterations: 500,
        keyLength: 32,
        // No schemeVersion — as persisted by the pre-fix scheme.
      );
      expect(Pbkdf2PatternHasher.isLegacyHash(legacy), isTrue);
    });

    test('verification against a legacy hash fails (no dual acceptance)',
        () async {
      // A hash produced by the pre-fix scheme over the canonical shape:
      // it would previously have accepted BOTH orientations.
      final CredentialHash legacyStored = await hasher.hash(
        const <int>[1, 2, 3, 6],
      );
      final CredentialHash unversioned = CredentialHash(
        salt: legacyStored.salt,
        digest: legacyStored.digest,
        iterations: legacyStored.iterations,
        keyLength: legacyStored.keyLength,
      );
      expect(Pbkdf2PatternHasher.isLegacyHash(unversioned), isTrue);
      // Neither orientation may verify against an ambiguous record.
      expect(await hasher.verify(const <int>[1, 2, 3, 6], unversioned), isFalse);
      expect(await hasher.verify(const <int>[6, 3, 2, 1], unversioned), isFalse);
    });
  });
}
