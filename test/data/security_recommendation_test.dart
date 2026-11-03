// Phase 8 / M2 (PRD 8F) — security level recommendations: deterministic,
// explainable, advisory. Production catalog and PreferencesStoreImpl over
// the in-memory key-value store (SIMULATED storage).

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/security_recommendation.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_key_value_store.dart';
import 'package:smart_app_lock/data/storage/impl/preferences_store_impl.dart';
import 'package:smart_app_lock/data/storage/preferences_store.dart';

void main() {
  group('SecurityRecommendations (production catalog)', () {
    test('21. covers every PRD 8F category with a reason', () {
      final Set<SensitiveAppCategory> covered =
          SecurityRecommendations.catalog.values.toSet();
      expect(covered, SensitiveAppCategory.values.toSet());
      expect(
        SecurityRecommendations.catalog['com.x8bit.bitwarden'],
        SensitiveAppCategory.passwordManager,
      );
      expect(
        SecurityRecommendations
            .catalog['com.google.android.apps.authenticator2'],
        SensitiveAppCategory.authenticator,
      );
      expect(
        SecurityRecommendations.catalog['pk.com.telenor.phoenix'],
        SensitiveAppCategory.finance,
      );
      for (final SensitiveAppCategory c in SensitiveAppCategory.values) {
        expect(c.reason, isNotEmpty);
        expect(c.recommendedLevel, isNot(AppSecurityLevel.standard));
      }
      expect(SensitiveAppCategory.finance.recommendedLevel,
          AppSecurityLevel.critical);
      expect(SensitiveAppCategory.privacy.recommendedLevel,
          AppSecurityLevel.sensitive);
    });

    test('22. exact package names only: no keyword or prefix matching', () {
      for (final String pkg in <String>[
        'com.example.mybank',
        'com.bank.app',
        'com.whatsapp.fake',
        'com.whatsapp.w4b',
        'xcom.whatsapp',
        'COM.WHATSAPP',
        ' com.whatsapp',
        'com.example.password.manager',
        'com.authenticator',
        '',
      ]) {
        expect(
          SecurityRecommendations.forApp(pkg, AppSecurityLevel.standard),
          isNull,
          reason: pkg,
        );
      }
      // Catalog entries are well-formed package names.
      final RegExp packageName = RegExp(r'^[a-zA-Z][\w]*(\.[a-zA-Z_][\w]*)+$');
      for (final String pkg in SecurityRecommendations.catalog.keys) {
        expect(packageName.hasMatch(pkg), isTrue, reason: pkg);
      }
    });

    test('23. only suggests a STRICTER level; at or above it, no suggestion',
        () {
      final SecurityRecommendation? s = SecurityRecommendations.forApp(
        'com.x8bit.bitwarden',
        AppSecurityLevel.standard,
      );
      expect(s!.level, AppSecurityLevel.critical);
      expect(s.reason, SensitiveAppCategory.passwordManager.reason);
      expect(
        SecurityRecommendations.forApp(
            'com.x8bit.bitwarden', AppSecurityLevel.sensitive),
        isNotNull,
      );
      expect(
        SecurityRecommendations.forApp(
            'com.x8bit.bitwarden', AppSecurityLevel.critical),
        isNull,
      );
      expect(
        SecurityRecommendations.forApp(
            'com.whatsapp', AppSecurityLevel.sensitive),
        isNull,
      );
      expect(
        SecurityRecommendations.forApp(
            'com.whatsapp', AppSecurityLevel.critical),
        isNull,
        reason: 'never suggests lowering',
      );
    });

    test(
        '24. a dismissal hides exactly that suggestion and survives a '
        'restart; local storage only', () async {
      final InMemoryKeyValueStore kv = InMemoryKeyValueStore();
      final PreferencesStore prefs = PreferencesStoreImpl(kv);
      final SecurityRecommendation s = SecurityRecommendations.forApp(
        'com.whatsapp',
        AppSecurityLevel.standard,
      )!;
      expect(s.dismissalKey, 'com.whatsapp@sensitive');
      expect(await prefs.getDismissedSecurityRecommendations(), isEmpty);
      await prefs.dismissSecurityRecommendation(s.dismissalKey);
      await prefs.dismissSecurityRecommendation(s.dismissalKey); // idempotent
      await prefs.dismissSecurityRecommendation(
        'com.x8bit.bitwarden@critical',
      );
      await prefs.dismissSecurityRecommendation('bad\nkey'); // ignored

      final PreferencesStore restarted = PreferencesStoreImpl(kv);
      final Set<String> dismissed =
          await restarted.getDismissedSecurityRecommendations();
      expect(dismissed, <String>{
        'com.whatsapp@sensitive',
        'com.x8bit.bitwarden@critical',
      });
      expect(
        SecurityRecommendations.forApp(
          'com.whatsapp',
          AppSecurityLevel.standard,
          dismissed: dismissed,
        ),
        isNull,
      );
      expect(
        SecurityRecommendations.forApp(
          'org.telegram.messenger',
          AppSecurityLevel.standard,
          dismissed: dismissed,
        ),
        isNotNull,
        reason: 'other apps are unaffected',
      );
      expect(
        await kv.getString(AppPrefKeys.dismissedSecurityRecommendations),
        'com.whatsapp@sensitive\ncom.x8bit.bitwarden@critical',
      );
    });
  });
}
