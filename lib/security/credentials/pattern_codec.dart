/// Unlock-pattern model + codec.
///
/// A pattern is an **ordered, direction-sensitive sequence** of nodes on a
/// 3x3 grid, numbered row-major 1-9 (Android-style).
///
/// `1-2-3-6` and `6-3-2-1` are **different** patterns: the exact sequence
/// drawn during setup is the exact sequence required to authenticate.
/// No canonicalization, sorting, reversing, or shape-only comparison is
/// performed — the raw drawing order is the credential.
abstract final class PatternCodec {
  static const int gridSize = 3;

  /// Minimum / maximum node values.
  static const int minNode = 1;
  static const int maxNode = 9;

  /// Stable, order-preserving string used for hashing and storage.
  /// Example: `1-4-7-8`. The reverse `8-7-4-1` serializes differently —
  /// ordering is part of the credential.
  static String serialize(List<int> nodes) => nodes.join('-');

  /// Parses a string produced by [serialize].
  static List<int> parse(String encoded) =>
      encoded.split('-').map(int.parse).toList(growable: false);

  /// True when two node sequences are **exactly equal, in order**.
  static bool matches(List<int> a, List<int> b) =>
      serialize(a) == serialize(b);
}
