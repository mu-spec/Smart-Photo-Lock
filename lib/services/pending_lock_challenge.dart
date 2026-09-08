/// Non-secret identity of one native lock presentation attempt.
///
/// Android replaces [generation] on screen-off. Flutter must echo the exact
/// ticket when acknowledging a rendered challenge or granting a successful
/// authentication, preventing callbacks from a pre-sleep route from affecting
/// the wake recovery shield.
class PendingLockChallenge {
  const PendingLockChallenge({
    required this.packageName,
    required this.generation,
  });

  factory PendingLockChallenge.fromMap(Map<dynamic, dynamic> map) {
    final String? packageName = map['packageName'] as String?;
    final int? generation = map['generation'] as int?;
    if (packageName == null || packageName.isEmpty || generation == null) {
      throw const FormatException('Invalid pending lock challenge.');
    }
    return PendingLockChallenge(
      packageName: packageName,
      generation: generation,
    );
  }

  final String packageName;
  final int generation;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'packageName': packageName,
        'generation': generation,
      };

  @override
  bool operator ==(Object other) =>
      other is PendingLockChallenge &&
      other.packageName == packageName &&
      other.generation == generation;

  @override
  int get hashCode => Object.hash(packageName, generation);
}
