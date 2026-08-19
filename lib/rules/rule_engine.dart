import '../utilities/time_utils.dart';
import 'lock_rule.dart';

/// Pure, side-effect-free lock decision logic.
///
/// [RuleEngine] answers exactly one question: "should this app be locked
/// right now?" It never touches Android — enforcement (overlays, services)
/// lives in the protection layer and only *consults* this engine.
class RuleEngine {
  const RuleEngine();

  /// Returns true when any enabled rule that applies to [packageName]
  /// matches at [now].
  ///
  /// [launchesToday] feeds the launch-limit rule and is supplied by the
  /// usage-tracking service (default 0 = "no data yet").
  bool shouldLock({
    required String packageName,
    required List<LockRule> rules,
    DateTime? now,
    int launchesToday = 0,
  }) {
    final DateTime t = now ?? DateTime.now();
    for (final LockRule rule in rules) {
      if (!rule.enabled || !rule.appliesTo(packageName)) {
        continue;
      }
      final bool matches = switch (rule.type) {
        LockRuleType.always => true,
        LockRuleType.timeWindow => TimeUtils.isWithinWindow(
            TimeUtils.minutesOfDay(t),
            rule.startMinuteOfDay ?? 0,
            rule.endMinuteOfDay ?? 0,
          ),
        LockRuleType.launchLimit => _launchLimitReached(rule, launchesToday),
      };
      if (matches) {
        return true;
      }
    }
    return false;
  }

  bool _launchLimitReached(LockRule rule, int launchesToday) {
    final int? max = rule.maxLaunchesPerDay;
    if (max == null || max <= 0) {
      return false; // rule not fully configured yet — treat as no-op
    }
    return launchesToday >= max;
  }
}
