import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/security/credentials/credential_hash.dart';
import 'package:smart_app_lock/security/credentials/credential_hash_policy.dart';

void main() {
  const CredentialHash valid = CredentialHash(
    salt: 'c2FsdHNhbHRzYWx0c2FsdA==', // 16 bytes
    digest: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=', // 32 bytes
    iterations: 50000,
    keyLength: 32,
  );

  String digestOfLength(int bytes) =>
      base64Encode(List<int>.filled(bytes, 7));

  group('CredentialHashPolicy', () {
    test('lenient policy only checks structure', () {
      // Property access (valid.salt) is not allowed in const expressions,
      // so this record is a plain final instance.
      final CredentialHash lowIterations = CredentialHash(
        salt: valid.salt,
        digest: valid.digest,
        iterations: 1,
        keyLength: 32,
      );
      expect(CredentialHashPolicy.lenient.validate(lowIterations), isNull);
    });

    test('strict policy rejects weak work factors', () {
      final CredentialHash weak = CredentialHash(
        salt: valid.salt,
        digest: digestOfLength(32),
        iterations: 9999,
        keyLength: 32,
      );
      expect(
        CredentialHashPolicy.strict.validate(weak),
        HashPolicyViolation.iterationsBelowMinimum,
      );
    });

    test('rejects unexpected key lengths', () {
      final CredentialHash odd = CredentialHash(
        salt: valid.salt,
        digest: digestOfLength(16),
        iterations: 50000,
        keyLength: 16,
      );
      expect(
        CredentialHashPolicy.lenient.validate(odd),
        HashPolicyViolation.unexpectedKeyLength,
      );
    });

    test('rejects short salts', () {
      final CredentialHash shortSalt = CredentialHash(
        salt: base64Encode(const <int>[1, 2, 3, 4]), // 4 bytes
        digest: digestOfLength(32),
        iterations: 50000,
        keyLength: 32,
      );
      expect(
        CredentialHashPolicy.lenient.validate(shortSalt),
        HashPolicyViolation.saltTooShort,
      );
    });

    test('rejects digests whose length does not match keyLength', () {
      final CredentialHash badDigest = CredentialHash(
        salt: valid.salt,
        digest: digestOfLength(16), // 16 bytes vs keyLength 32
        iterations: 50000,
        keyLength: 32,
      );
      expect(
        CredentialHashPolicy.lenient.validate(badDigest),
        HashPolicyViolation.digestLengthMismatch,
      );
    });

    test('rejects malformed encodings', () {
      final CredentialHash badSalt = CredentialHash(
        salt: '!!not-base64!!',
        digest: digestOfLength(32),
        iterations: 50000,
        keyLength: 32,
      );
      expect(
        CredentialHashPolicy.lenient.validate(badSalt),
        HashPolicyViolation.malformedEncoding,
      );

      final CredentialHash badDigestB64 = CredentialHash(
        salt: valid.salt,
        digest: '!!also-not-base64!!',
        iterations: 50000,
        keyLength: 32,
      );
      expect(
        CredentialHashPolicy.lenient.validate(badDigestB64),
        HashPolicyViolation.malformedEncoding,
      );
    });

    test('a well-formed hash passes both policies', () {
      final CredentialHash good = CredentialHash(
        salt: valid.salt,
        digest: digestOfLength(32),
        iterations: 50000,
        keyLength: 32,
      );
      expect(CredentialHashPolicy.lenient.validate(good), isNull);
      expect(CredentialHashPolicy.strict.validate(good), isNull);
    });
  });
}
