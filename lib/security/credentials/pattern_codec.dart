/// Unlock-pattern model + codec.
///
/// A pattern is an ordered sequence of nodes on a 3x3 grid, numbered
/// row-major 1-9 (like Android). Only the *shape* matters, not the drawing
/// direction: `1-4-7` and `7-4-1` are the same pattern, so the codec
/// canonicalizes by keeping the lexicographically smaller orientation.
abstract final class PatternCodec {
  static const int gridSize = 3;

  /// Minimum / maximum node values.
  static const int minNode = 1;
  static const int maxNode = 9;

  /// Returns the canonical (direction-independent) node sequence.
  static List<int> canonicalize(List<int> nodes) {
    final List<int> reversed = nodes.reversed.toList();
    return _compare(nodes, reversed) <= 0
        ? List<int>.from(nodes)
        : reversed;
  }

  /// Canonical, stable string used for hashing and storage.
  /// Example: `1-4-7-8`.
  static String serialize(List<int> nodes) =>
      canonicalize(nodes).join('-');

  /// Parses a string produced by [serialize].
  static List<int> parse(String encoded) =>
      encoded.split('-').map(int.parse).toList(growable: false);

  /// True when two node sequences describe the same shape.
  static bool sameShape(List<int> a, List<int> b) =>
      serialize(a) == serialize(b);

  static int _compare(List<int> a, List<int> b) {
    final int length = a.length < b.length ? a.length : b.length;
    for (int i = 0; i < length; i++) {
      if (a[i] != b[i]) {
        return a[i] < b[i] ? -1 : 1;
      }
    }
    return a.length.compareTo(b.length);
  }
}
