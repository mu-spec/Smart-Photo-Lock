import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/data/repositories/impl/lock_settings_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/lock_settings_repository.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/profiles/lock_profile.dart';
import 'package:smart_app_lock/rules/lock_rule.dart';

void main() {
  late LockSettingsRepository repo;

  setUp(() {
    repo = LockSettingsRepositoryImpl(InMemoryLocalDatabase());
  });

  group('profiles', () {
    test('starts with no profiles and no active profile', () async {
      expect((await repo.getProfiles()).valueOrNull, isEmpty);
      expect((await repo.getActiveProfile()).valueOrNull, isNull);
    });

    test('save + get round-trip', () async {
      const LockProfile profile = LockProfile(
        id: 'work',
        name: 'Work mode',
        description: 'Locks social apps during work hours',
        lockedPackages: <String>['com.whatsapp', 'com.instagram'],
      );
      await repo.saveProfile(profile);
      final profiles = (await repo.getProfiles()).valueOrNull!;
      expect(profiles, hasLength(1));
      expect(profiles.single.id, 'work');
      expect(profiles.single.lockedPackages, <String>['com.whatsapp', 'com.instagram']);
      expect(profiles.single.isActive, isFalse);
    });

    test('saveProfile with isActive keeps exactly one active', () async {
      const LockProfile a = LockProfile(id: 'a', name: 'A', isActive: true);
      const LockProfile b = LockProfile(id: 'b', name: 'B');
      await repo.saveProfile(a);
      await repo.saveProfile(b);
      await repo.saveProfile(b.copyWith(isActive: true));

      final profiles = (await repo.getProfiles()).valueOrNull!;
      expect(profiles.where((LockProfile p) => p.isActive), hasLength(1));
      expect(
        (await repo.getActiveProfile()).valueOrNull!.id,
        'b',
      );
    });

    test('setActiveProfile switches the active profile', () async {
      await repo.saveProfile(
        const LockProfile(id: 'a', name: 'A', isActive: true),
      );
      await repo.saveProfile(const LockProfile(id: 'b', name: 'B'));
      await repo.setActiveProfile('b');

      final profiles = (await repo.getProfiles()).valueOrNull!;
      expect(profiles.where((LockProfile p) => p.isActive), hasLength(1));
      expect((await repo.getActiveProfile()).valueOrNull!.id, 'b');
    });

    test('delete removes a profile', () async {
      await repo.saveProfile(const LockProfile(id: 'a', name: 'A'));
      await repo.deleteProfile('a');
      expect((await repo.getProfiles()).valueOrNull, isEmpty);
    });
  });

  group('rules', () {
    test('starts empty', () async {
      expect((await repo.getRules()).valueOrNull, isEmpty);
    });

    test('saveRules persists the whole set', () async {
      const List<LockRule> rules = <LockRule>[
        LockRule(id: 'r1', type: LockRuleType.always, packageName: 'com.whatsapp'),
        LockRule(
          id: 'r2',
          type: LockRuleType.timeWindow,
          startMinuteOfDay: 1320,
          endMinuteOfDay: 360,
        ),
        LockRule(
          id: 'r3',
          type: LockRuleType.launchLimit,
          packageName: 'com.tiktok',
          maxLaunchesPerDay: 5,
          enabled: false,
        ),
      ];
      await repo.saveRules(rules);

      final restored = (await repo.getRules()).valueOrNull!;
      expect(restored, hasLength(3));
      expect(restored.map((LockRule r) => r.id).toSet(),
          <String>{'r1', 'r2', 'r3'});

      final LockRule r1 = restored.firstWhere((LockRule r) => r.id == 'r1');
      expect(r1.type, LockRuleType.always);
      expect(r1.packageName, 'com.whatsapp');

      final LockRule r2 = restored.firstWhere((LockRule r) => r.id == 'r2');
      expect(r2.startMinuteOfDay, 1320);
      expect(r2.endMinuteOfDay, 360);

      final LockRule r3 = restored.firstWhere((LockRule r) => r.id == 'r3');
      expect(r3.enabled, isFalse);
      expect(r3.maxLaunchesPerDay, 5);
    });

    test('saveRules replaces the previous set', () async {
      await repo.saveRules(
        const <LockRule>[
          LockRule(id: 'old', type: LockRuleType.always),
        ],
      );
      await repo.saveRules(
        const <LockRule>[
          LockRule(id: 'new1', type: LockRuleType.always),
          LockRule(id: 'new2', type: LockRuleType.always),
        ],
      );
      final rules = (await repo.getRules()).valueOrNull!;
      expect(rules, hasLength(2));
      expect(rules.any((LockRule r) => r.id == 'old'), isFalse);
    });
  });

  group('re-lock grace (Phase 5L)', () {
    test('defaults to zero (immediate re-lock)', () async {
      expect((await repo.getGracePeriod()).valueOrNull, Duration.zero);
    });

    test('set + get round-trips whole seconds', () async {
      await repo.setGracePeriod(const Duration(minutes: 1));
      expect(
        (await repo.getGracePeriod()).valueOrNull,
        const Duration(minutes: 1),
      );

      await repo.setGracePeriod(const Duration(seconds: 30));
      expect(
        (await repo.getGracePeriod()).valueOrNull,
        const Duration(seconds: 30),
      );
    });

    test('a negative period clamps to zero', () async {
      await repo.setGracePeriod(const Duration(seconds: -30));
      expect((await repo.getGracePeriod()).valueOrNull, Duration.zero);
    });

    test('an unparsable stored value reads as zero (fail-quiet)',
        () async {
      await repo.setGracePeriod(const Duration(minutes: 5));
      // Corrupt the raw stored value directly in the database layer.
      final InMemoryLocalDatabase db = InMemoryLocalDatabase();
      await db.setSetting(
        LockSettingsRepositoryImpl.gracePeriodKey,
        'not-a-number',
      );
      final LockSettingsRepository corrupted = LockSettingsRepositoryImpl(db);
      expect(
        (await corrupted.getGracePeriod()).valueOrNull,
        Duration.zero,
      );
    });
  });
}
