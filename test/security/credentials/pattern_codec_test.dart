import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/security/credentials/pattern_codec.dart';
import 'package:smart_app_lock/security/credentials/pattern_policy.dart';

void main() {
  group('PatternPolicy', () {
    const PatternPolicy policy = PatternPolicy.defaults;

    test('accepts valid patterns', () {
      expect(policy.validate(const <int>[1, 2, 3, 6]), PatternValidation.valid);
      expect(policy.validate(const <int>[1, 4, 7, 8, 9]), PatternValidation.valid);
    });

    test('rejects short patterns', () {
      expect(policy.validate(const <int>[1, 2, 3]), PatternValidation.tooShort);
    });

    test('rejects out-of-grid nodes', () {
      expect(
        policy.validate(const <int>[1, 2, 3, 10]),
        PatternValidation.invalidNode,
      );
      expect(
        policy.validate(const <int>[0, 1, 2, 3]),
        PatternValidation.invalidNode,
      );
    });

    test('rejects duplicate nodes', () {
      expect(
        policy.validate(const <int>[1, 1, 2, 3]),
        PatternValidation.duplicateNode,
      );
    });

    test('messages are human-readable', () {
      expect(policy.messageFor(PatternValidation.tooShort), contains('4 dots'));
      expect(policy.messageFor(PatternValidation.duplicateNode), contains('once'));
    });
  });

  group('PatternCodec (ordered, direction-sensitive)', () {
    test('serialize preserves the exact drawing order', () {
      expect(
        PatternCodec.serialize(const <int>[1, 2, 3, 6]),
        '1-2-3-6',
      );
      expect(
        PatternCodec.serialize(const <int>[6, 3, 2, 1]),
        '6-3-2-1',
      );
    });

    test('a pattern and its reverse serialize differently', () {
      expect(
        PatternCodec.serialize(const <int>[1, 2, 3, 6]),
        isNot(PatternCodec.serialize(const <int>[6, 3, 2, 1])),
      );
    });

    test('reordered sequences serialize differently', () {
      expect(
        PatternCodec.serialize(const <int>[1, 2, 3, 6]),
        isNot(PatternCodec.serialize(const <int>[1, 3, 2, 6])),
      );
    });

    test('matches is strict about order', () {
      expect(
        PatternCodec.matches(const <int>[1, 2, 3, 6], const <int>[1, 2, 3, 6]),
        isTrue,
      );
      expect(
        PatternCodec.matches(const <int>[1, 2, 3, 6], const <int>[6, 3, 2, 1]),
        isFalse,
      );
      expect(
        PatternCodec.matches(const <int>[1, 2, 3, 6], const <int>[1, 3, 2, 6]),
        isFalse,
      );
    });

    test('serialize/parse round-trip preserves order', () {
      const List<int> nodes = <int>[1, 5, 9, 8, 7];
      expect(PatternCodec.parse(PatternCodec.serialize(nodes)), nodes);
    });

    test('input is not mutated', () {
      final List<int> original = <int>[7, 4, 1];
      final List<int> snapshot = List<int>.from(original);
      PatternCodec.serialize(original);
      expect(original, snapshot);
    });
  });
}
