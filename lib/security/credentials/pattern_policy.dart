/// Validation result for a candidate unlock pattern.
enum PatternValidation {
  /// Pattern satisfies the policy.
  valid,

  /// Fewer nodes than the policy minimum.
  tooShort,

  /// A node outside the 3x3 grid (valid nodes: 1-9).
  invalidNode,

  /// The same node appears more than once.
  duplicateNode,
}

/// Configurable unlock-pattern rules.
///
/// Mirrors Android's default: at least 4 distinct points on the 3x3 grid.
class PatternPolicy {
  const PatternPolicy({this.minNodes = 4, this.maxNodes = 9});

  static const PatternPolicy defaults = PatternPolicy();

  final int minNodes;
  final int maxNodes;

  /// Validates a candidate node sequence against this policy.
  PatternValidation validate(List<int> nodes) {
    if (nodes.length < minNodes) {
      return PatternValidation.tooShort;
    }
    final Set<int> seen = <int>{};
    for (final int node in nodes) {
      if (node < 1 || node > maxNodes) {
        return PatternValidation.invalidNode;
      }
      if (!seen.add(node)) {
        return PatternValidation.duplicateNode;
      }
    }
    return PatternValidation.valid;
  }

  /// Human-readable message for each validation outcome.
  String messageFor(PatternValidation result) => switch (result) {
        PatternValidation.valid => 'OK',
        PatternValidation.tooShort =>
          'Pattern must connect at least $minNodes dots',
        PatternValidation.invalidNode =>
          'Pattern dots must be within the 3x3 grid',
        PatternValidation.duplicateNode =>
          'A dot can only be used once per pattern',
      };
}
