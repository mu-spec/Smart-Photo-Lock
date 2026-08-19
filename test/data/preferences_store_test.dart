import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/data/storage/impl/in_memory_key_value_store.dart';
import 'package:smart_app_lock/data/storage/impl/preferences_store_impl.dart';
import 'package:smart_app_lock/data/storage/preferences_store.dart';

void main() {
  late InMemoryKeyValueStore kv;
  late PreferencesStore store;

  setUp(() {
    kv = InMemoryKeyValueStore();
    store = PreferencesStoreImpl(kv);
  });

  group('KeyValueStore (in-memory)', () {
    test('bool round-trip', () async {
      expect(await kv.getBool('a'), isNull);
      await kv.setBool('a', true);
      expect(await kv.getBool('a'), isTrue);
    });

    test('int round-trip', () async {
      await kv.setInt('n', 42);
      expect(await kv.getInt('n'), 42);
      expect(await kv.getInt('missing'), isNull);
    });

    test('string round-trip', () async {
      await kv.setString('s', 'hello');
      expect(await kv.getString('s'), 'hello');
    });

    test('remove deletes a single key', () async {
      await kv.setString('s', 'hello');
      await kv.remove('s');
      expect(await kv.getString('s'), isNull);
    });

    test('clear wipes everything', () async {
      await kv.setBool('a', true);
      await kv.setString('s', 'x');
      await kv.clear();
      expect(await kv.getBool('a'), isNull);
      expect(await kv.getString('s'), isNull);
    });
  });

  group('PreferencesStore (typed facade)', () {
    test('onboarding defaults to false, then persists', () async {
      expect(await store.isOnboardingCompleted(), isFalse);
      await store.setOnboardingCompleted(true);
      expect(await store.isOnboardingCompleted(), isTrue);
    });

    test('theme mode round-trip', () async {
      expect(await store.getThemeMode(), isNull);
      await store.setThemeMode('dark');
      expect(await store.getThemeMode(), 'dark');
    });

    test('language code round-trip', () async {
      await store.setLanguageCode('ur');
      expect(await store.getLanguageCode(), 'ur');
    });

    test('notifications default to enabled', () async {
      expect(await store.areNotificationsEnabled(), isTrue);
      await store.setNotificationsEnabled(false);
      expect(await store.areNotificationsEnabled(), isFalse);
    });

    test('last active profile id round-trip', () async {
      expect(await store.getLastActiveProfileId(), isNull);
      await store.setLastActiveProfileId('kids-mode');
      expect(await store.getLastActiveProfileId(), 'kids-mode');
    });

    test('clearAll empties every preference', () async {
      await store.setOnboardingCompleted(true);
      await store.setThemeMode('dark');
      await store.setLastActiveProfileId('p1');
      await store.clearAll();
      expect(await store.isOnboardingCompleted(), isFalse);
      expect(await store.getThemeMode(), isNull);
      expect(await store.getLastActiveProfileId(), isNull);
    });
  });
}
