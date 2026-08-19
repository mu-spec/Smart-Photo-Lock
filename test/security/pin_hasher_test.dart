import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/security/pin_hasher.dart';

void main() {
  group('Pbkdf2PinHasher', () {
    // Low iteration count keeps the test suite fast.
    final Pbkdf2PinHasher hasher = Pbkdf2PinHasher(iterations: 500);

    test('accepts the correct PIN', () async {
      final PinHash stored = await hasher.hash('1234');
      expect(await hasher.verify('1234', stored), isTrue);
    });

    test('rejects wrong PINs', () async {
      final PinHash stored = await hasher.hash('1234');
      expect(await hasher.verify('0000', stored), isFalse);
      expect(await hasher.verify('12345', stored), isFalse);
    });

    test('produces a unique salt per hash', () async {
      final PinHash a = await hasher.hash('1234');
      final PinHash b = await hasher.hash('1234');
      expect(a.salt, isNot(b.salt));
      expect(a.digest, isNot(b.digest));
    });

    test('survives JSON round-trip (storage format)', () async {
      final PinHash stored = await hasher.hash('2468');
      final PinHash restored = PinHash.fromJson(stored.toJson());
      expect(await hasher.verify('2468', restored), isTrue);
    });
  });
}
