import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/security/credentials/cooldown_policy.dart';

void main() {
  group('EscalatingCooldownPolicy (defaults)', () {
    const EscalatingCooldownPolicy policy = EscalatingCooldownPolicy();

    test('first lockout uses the base cooldown', () {
      expect(policy.cooldownForStreak(1), const Duration(seconds: 30));
    });

    test('cooldown doubles with each consecutive lockout', () {
      expect(policy.cooldownForStreak(2), const Duration(seconds: 60));
      expect(policy.cooldownForStreak(3), const Duration(minutes: 2));
      expect(policy.cooldownForStreak(4), const Duration(minutes: 4));
      expect(policy.cooldownForStreak(5), const Duration(minutes: 8));
    });

    test('cooldown is capped at maxCooldown', () {
      expect(policy.cooldownForStreak(6), const Duration(minutes: 10));
      expect(policy.cooldownForStreak(7), const Duration(minutes: 10));
      expect(policy.cooldownForStreak(100), const Duration(minutes: 10));
    });

    test('streaks below 1 clamp to the base cooldown', () {
      expect(policy.cooldownForStreak(0), const Duration(seconds: 30));
      expect(policy.cooldownForStreak(-3), const Duration(seconds: 30));
    });
  });

  group('EscalatingCooldownPolicy (custom)', () {
    const EscalatingCooldownPolicy triple = EscalatingCooldownPolicy(
      baseCooldown: Duration(seconds: 5),
      factor: 3,
      maxCooldown: Duration(minutes: 1),
    );

    test('custom base and factor', () {
      expect(triple.cooldownForStreak(1), const Duration(seconds: 5));
      expect(triple.cooldownForStreak(2), const Duration(seconds: 15));
      expect(triple.cooldownForStreak(3), const Duration(seconds: 45));
    });

    test('custom cap', () {
      expect(triple.cooldownForStreak(4), const Duration(minutes: 1));
      expect(triple.cooldownForStreak(10), const Duration(minutes: 1));
    });

    test('factor 1 keeps the cooldown flat (opt-out of escalation)', () {
      const EscalatingCooldownPolicy flat = EscalatingCooldownPolicy(
        baseCooldown: Duration(seconds: 30),
        factor: 1,
      );
      expect(flat.cooldownForStreak(1), const Duration(seconds: 30));
      expect(flat.cooldownForStreak(5), const Duration(seconds: 30));
    });
  });
}
