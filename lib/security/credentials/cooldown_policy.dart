/// Increasing cooldown schedule for repeated lockouts (Phase 2F).
///
/// `cooldownForStreak(n) = baseCooldown × factor^(n-1)`, capped at
/// [maxCooldown]. Streak 1 is the first lockout (base cooldown); every
/// consecutive lockout — i.e. the user locked out again without a
/// successful authentication in between — escalates the wait.
///
/// Defaults: 30s → 1m → 2m → 4m → 8m → 10m (cap).
class EscalatingCooldownPolicy {
  const EscalatingCooldownPolicy({
    this.baseCooldown = const Duration(seconds: 30),
    this.factor = 2,
    this.maxCooldown = const Duration(minutes: 10),
  }) : assert(factor >= 1, 'factor must be >= 1');

  /// Cooldown applied to the first lockout in a failure sequence.
  final Duration baseCooldown;

  /// Multiplier between consecutive cooldowns (2 = doubling).
  final int factor;

  /// Upper bound — the cooldown never grows past this.
  final Duration maxCooldown;

  /// Cooldown for the given lockout streak (1-based; values below 1 are
  /// clamped to the base cooldown).
  Duration cooldownForStreak(int streak) {
    final int n = streak < 1 ? 1 : streak;
    Duration duration = baseCooldown;
    for (int i = 1; i < n; i++) {
      final Duration doubled = duration * factor;
      if (doubled >= maxCooldown) {
        return maxCooldown;
      }
      duration = doubled;
    }
    return duration;
  }
}
