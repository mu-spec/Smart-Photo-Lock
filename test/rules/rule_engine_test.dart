import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/rules/lock_rule.dart';
import 'package:smart_app_lock/rules/rule_engine.dart';

void main() {
  const RuleEngine engine = RuleEngine();
  final DateTime noon = DateTime(2026, 8, 19, 12, 0); // 720 minutes
  final DateTime night = DateTime(2026, 8, 19, 23, 0); // 1380 minutes
  final DateTime earlyMorning = DateTime(2026, 8, 20, 3, 0); // 180 minutes

  test('always-rule locks its package', () {
    const List<LockRule> rules = <LockRule>[
      LockRule(id: 'r1', type: LockRuleType.always, packageName: 'com.whatsapp'),
    ];
    expect(
      engine.shouldLock(packageName: 'com.whatsapp', rules: rules, now: noon),
      isTrue,
    );
  });

  test('scoped rule ignores other packages', () {
    const List<LockRule> rules = <LockRule>[
      LockRule(id: 'r1', type: LockRuleType.always, packageName: 'com.whatsapp'),
    ];
    expect(
      engine.shouldLock(packageName: 'com.instagram', rules: rules, now: noon),
      isFalse,
    );
  });

  test('global rule (no package) applies to every app', () {
    const List<LockRule> rules = <LockRule>[
      LockRule(id: 'r0', type: LockRuleType.always),
    ];
    expect(
      engine.shouldLock(packageName: 'com.anything', rules: rules, now: noon),
      isTrue,
    );
  });

  test('disabled rules are skipped', () {
    const List<LockRule> rules = <LockRule>[
      LockRule(
        id: 'r1',
        type: LockRuleType.always,
        packageName: 'com.whatsapp',
        enabled: false,
      ),
    ];
    expect(
      engine.shouldLock(packageName: 'com.whatsapp', rules: rules, now: noon),
      isFalse,
    );
  });

  test('time-window rule matches only inside the window', () {
    const List<LockRule> rules = <LockRule>[
      LockRule(
        id: 'r2',
        type: LockRuleType.timeWindow,
        startMinuteOfDay: 600,
        endMinuteOfDay: 1080,
      ),
    ];
    expect(
      engine.shouldLock(packageName: 'com.whatsapp', rules: rules, now: noon),
      isTrue,
    );
    expect(
      engine.shouldLock(
          packageName: 'com.whatsapp', rules: rules, now: earlyMorning),
      isFalse,
    );
  });

  test('time-window rule wraps past midnight', () {
    const List<LockRule> rules = <LockRule>[
      LockRule(
        id: 'r3',
        type: LockRuleType.timeWindow,
        startMinuteOfDay: 1320, // 22:00
        endMinuteOfDay: 360, // 06:00
      ),
    ];
    expect(
      engine.shouldLock(packageName: 'com.whatsapp', rules: rules, now: night),
      isTrue,
    );
    expect(
      engine.shouldLock(
          packageName: 'com.whatsapp', rules: rules, now: earlyMorning),
      isTrue,
    );
    expect(
      engine.shouldLock(packageName: 'com.whatsapp', rules: rules, now: noon),
      isFalse,
    );
  });

  test('launch-limit rule triggers at the cap', () {
    const List<LockRule> rules = <LockRule>[
      LockRule(
        id: 'r4',
        type: LockRuleType.launchLimit,
        packageName: 'com.whatsapp',
        maxLaunchesPerDay: 5,
      ),
    ];
    expect(
      engine.shouldLock(
          packageName: 'com.whatsapp', rules: rules, launchesToday: 4),
      isFalse,
    );
    expect(
      engine.shouldLock(
          packageName: 'com.whatsapp', rules: rules, launchesToday: 5),
      isTrue,
    );
  });

  test('rules serialize and restore via JSON', () {
    const LockRule original = LockRule(
      id: 'r5',
      type: LockRuleType.timeWindow,
      packageName: 'com.whatsapp',
      startMinuteOfDay: 600,
      endMinuteOfDay: 1080,
    );
    final LockRule restored = LockRule.fromJson(original.toJson());
    expect(restored, original);
    expect(restored.type, LockRuleType.timeWindow);
    expect(restored.startMinuteOfDay, 600);
  });
}
