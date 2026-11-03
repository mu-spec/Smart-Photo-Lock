// Phase 9 / M3 — "Don't suggest again" persistence (PRODUCTION storage code).
//
// The production SharedPreferences key-value store and PreferencesStoreImpl.
// SIMULATED: SharedPreferences is a test double (or the plugin's in-memory
// mock); no Android disk write is observed.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_key_value_store.dart';
import 'package:smart_app_lock/data/storage/impl/preferences_store_impl.dart';
import 'package:smart_app_lock/data/storage/impl/shared_prefs_key_value_store.dart';
import 'package:smart_app_lock/data/storage/preferences_store.dart';

const String _pref = AppPrefKeys.dismissedSecurityRecommendations;

/// SharedPreferences whose platform write reports [result].
class _Prefs implements SharedPreferences {
  bool result = true;
  final List<(String, String)> writes = <(String, String)>[];

  @override
  Future<bool> setString(String key, String value) async {
    writes.add((key, value));
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Behaves like shared_preferences on a failed disk write: the value lands
/// in memory first, then the write fails.
class _CacheThenFail extends InMemoryKeyValueStore {
  bool fail = false;
  int failures = 0;

  @override
  Future<void> setString(String key, String value) async {
    await super.setString(key, value);
    if (fail && key == _pref) {
      failures++;
      throw StateError('write $failures failed');
    }
  }
}

void main() {
  group('production SharedPreferences store', () {
    test('a write the platform reports as failed is an error, never success',
        () async {
      final _Prefs prefs = _Prefs()..result = false;
      final SharedPreferencesKeyValueStore store =
          SharedPreferencesKeyValueStore(prefs);
      await expectLater(store.setString(_pref, 'a@b'), throwsStateError);
      expect(prefs.writes, <(String, String)>[(_pref, 'a@b')]);

      prefs.result = true;
      await store.setString(_pref, 'a@b');
      expect(prefs.writes, hasLength(2));
    });

    test('end to end over the plugin: a saved dismissal is read back',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final PreferencesStoreImpl store = PreferencesStoreImpl(
        SharedPreferencesKeyValueStore(await SharedPreferences.getInstance()),
      );
      await store.dismissSecurityRecommendation('com.whatsapp@sensitive');
      // A fresh instance over the same backing values (simulated restart).
      final PreferencesStoreImpl again = PreferencesStoreImpl(
        SharedPreferencesKeyValueStore(await SharedPreferences.getInstance()),
      );
      expect(await again.getDismissedSecurityRecommendations(),
          <String>{'com.whatsapp@sensitive'});
    });
  });

  group('PreferencesStoreImpl.dismissSecurityRecommendation', () {
    test('success: saved, sorted, earlier keys kept, repeat is a no-op',
        () async {
      final _CacheThenFail kv = _CacheThenFail();
      final PreferencesStoreImpl store = PreferencesStoreImpl(kv);
      await store.dismissSecurityRecommendation('z@critical');
      await store.dismissSecurityRecommendation('#relock@300');
      await store.dismissSecurityRecommendation('z@critical');
      expect(await store.getDismissedSecurityRecommendations(),
          <String>{'z@critical', '#relock@300'});
      expect(await kv.getString(_pref), '#relock@300\nz@critical');
    });

    test(
        'failure with nothing saved before: throws and leaves no unsaved '
        'dismissal in memory', () async {
      final _CacheThenFail kv = _CacheThenFail()..fail = true;
      final PreferencesStoreImpl store = PreferencesStoreImpl(kv);
      await expectLater(
        store.dismissSecurityRecommendation('com.whatsapp@sensitive'),
        throwsA(isA<StateError>()),
      );
      expect(await store.getDismissedSecurityRecommendations(), isEmpty);
      expect(await kv.getString(_pref), isNull);
    });

    test(
        'failure with earlier dismissals: throws the original error and '
        'restores the earlier set exactly', () async {
      final _CacheThenFail kv = _CacheThenFail();
      final PreferencesStoreImpl store = PreferencesStoreImpl(kv);
      await store.dismissSecurityRecommendation('a@sensitive');
      kv.fail = true;
      await expectLater(
        store.dismissSecurityRecommendation('b@critical'),
        throwsA(isA<StateError>()
            .having((StateError e) => e.message, 'message', 'write 1 failed')),
        reason: 'the rollback failing too never masks the original error',
      );
      expect(kv.failures, 2, reason: 'the write, then the rollback');
      expect(await store.getDismissedSecurityRecommendations(),
          <String>{'a@sensitive'});
    });

    test('invalid keys are ignored without a write', () async {
      final _CacheThenFail kv = _CacheThenFail()..fail = true;
      final PreferencesStoreImpl store = PreferencesStoreImpl(kv);
      await store.dismissSecurityRecommendation('');
      await store.dismissSecurityRecommendation('a\nb');
      expect(kv.failures, 0);
    });
  });
}
