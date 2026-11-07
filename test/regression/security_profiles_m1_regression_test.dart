// Phase 11 / M1 regression: Security Profiles wired through the REAL
// container (ProtectionBootstrap → StaticWatcherService → DefaultAccess
// Controller), with non-Normal profiles activated ONLY by this harness
// writing the stored document (no user-facing activation exists in M1).
//
// SIMULATED: in-memory stores, static watcher (mirrors native KEPT / HELD /
// APPLIED resolution); no device, no native code.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/impl/security_profile_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/impl/smart_rule_repository_impl.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_key_value_store.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/profiles/security_profile.dart';
import 'package:smart_app_lock/profiles/security_profile_document.dart';
import 'package:smart_app_lock/profiles/security_profile_policy.dart';
import 'package:smart_app_lock/protection/access_controller.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/rules/smart_rule_policy.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/watcher_service.dart';

typedef _L = AppSecurityLevel;

const String _pin = '2468';
const String _std = 'com.example.notes'; // protected, Standard
const String _sens = 'com.example.chat'; // protected, Sensitive
const String _maps = 'com.example.maps'; // installed, NOT protected
const String _profileKey = SecurityProfileRepositoryImpl.storageKey;

const List<AppEntry> _installed = <AppEntry>[
  AppEntry(packageName: _std, label: 'notes'),
  AppEntry(packageName: _sens, label: 'chat'),
  AppEntry(packageName: _maps, label: 'maps'),
];

final SmartRule _chatCritical = SmartRule(
  id: 'chat-critical',
  name: 'Chat always Critical',
  targetPackages: const <String>[_sens],
  days: SmartRuleDays.everyDay,
  time: const SmartRuleTime.allDay(),
  action: SmartRuleAction.critical,
);

class _Db extends InMemoryLocalDatabase {
  bool failProfileReads = false;
  bool failRuleReads = false;
  int profileWrites = 0;

  @override
  Future<String?> getSetting(String key) async {
    if (key == _profileKey && failProfileReads) {
      throw StateError('simulated profile read failure');
    }
    if (key == SmartRuleRepositoryImpl.storageKey && failRuleReads) {
      throw StateError('simulated rule read failure');
    }
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) {
    if (key == _profileKey) profileWrites++;
    return super.setSetting(key, value);
  }
}

SecurityProfileSet _active(SecurityProfile p) => SecurityProfileSet(
      profiles: <SecurityProfile>[
        for (final SecurityProfileKind k in SecurityProfileKind.values)
          k == p.kind ? p : SecurityProfile.preset(k),
      ],
      activeProfileId: p.id,
    );

final SecurityProfile _guest =
    SecurityProfile.preset(SecurityProfileKind.guest);

class _Fx {
  _Fx(this.c, this.db, this.kv, this.secrets);

  final AppContainer c;
  final _Db db;
  final InMemoryKeyValueStore kv;
  final InMemorySecretStore secrets;

  StaticWatcherService get watcher => c.watcher as StaticWatcherService;

  static Future<_Fx> create({
    List<SmartRule> rules = const <SmartRule>[],
    SecurityProfileSet? profiles,
  }) async {
    final _Db db = _Db();
    final InMemoryKeyValueStore kv = InMemoryKeyValueStore();
    final InMemorySecretStore secrets = InMemorySecretStore();
    final AppContainer c = _container(db, kv, secrets);
    await c.auth.enrollPin(_pin);
    await c.protectedApps.add(ProtectedApp(
      packageName: _std,
      label: 'notes',
      addedAt: DateTime(2026, 11, 1),
    ));
    await c.protectedApps.add(ProtectedApp(
      packageName: _sens,
      label: 'chat',
      addedAt: DateTime(2026, 11, 1),
      securityLevel: _L.sensitive,
    ));
    for (final SmartRule r in rules) {
      expect((await c.smartRules.saveRule(r)).isSuccess, isTrue);
    }
    if (profiles != null) {
      // HARNESS-ONLY activation (M1 has no user-facing switch).
      expect(
        (await c.securityProfiles.saveProfiles(profiles,
                expected: SecurityProfileSet.defaults()))
            .isSuccess,
        isTrue,
      );
    }
    db.profileWrites = 0;
    return _Fx(c, db, kv, secrets).restart();
  }

  static AppContainer _container(
    _Db db,
    InMemoryKeyValueStore kv,
    InMemorySecretStore secrets,
  ) =>
      AppContainer.inMemory(
        apps: _installed,
        database: db,
        secretStore: secrets,
        keyValueStore: kv,
        accessibilityEnabled: true,
        overlayGranted: true,
        accessClock: () => DateTime(2026, 11, 2, 12),
      );

  /// SIMULATED process restart over the same persisted stores (the static
  /// watcher, standing in for native, keeps its previously applied rules).
  _Fx restart() {
    final List<Map<String, Object?>> nativeRules =
        List<Map<String, Object?>>.of(watcher.smartRules);
    final AppContainer next = _container(db, kv, secrets);
    (next.watcher as StaticWatcherService)
      ..protectionConfigured = true
      ..running = true
      ..accessibilityServiceConnected = true
      ..shieldArmed = true
      ..challengePending = false
      ..smartRules.addAll(nativeRules);
    return _Fx(next, db, kv, secrets);
  }

  Future<Map<String, _L>> savedLevels() async => <String, _L>{
        for (final ProtectedApp a
            in (await c.protectedApps.getProtectedApps()).valueOrNull!)
          a.packageName: a.securityLevel,
      };

  Future<_L> grant(String pkg) async =>
      (await c.accessController.grantAccess(pkg)).valueOrNull!.securityLevel;

  List<Map<String, Object?>>? get lastSent =>
      watcher.receivedPolicies.last?.smartRules;
}

List<String> _sorted(Iterable<Map<String, Object?>> t) =>
    t.map((Map<String, Object?> e) => e.toString()).toList()..sort();

const Map<String, _L> _baselines = <String, _L>{
  _std: _L.standard,
  _sens: _L.sensitive,
};

void main() {
  group('P11-M1: Normal is a no-op (every real user in M1)', () {
    test(
        'N-1. nothing stored: transport is EXACTLY the rules-only transport, '
        'no profile document is written, levels unchanged', () async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_chatCritical]);
      expect((await fx.c.protectionBootstrap.synchronize()).isSuccess, isTrue);
      expect(
        fx.lastSent!.map((Map<String, Object?> e) => e.toString()).toList(),
        SmartRulePolicy.nativeTransport(<SmartRule>[_chatCritical])
            .map((Map<String, Object?> e) => e.toString())
            .toList(),
      );
      final SmartRuleNativeRecord rec =
          fx.c.protectionBootstrap.lastRuleExchange!;
      expect(rec.sentProfileOverlay, isEmpty);
      expect(rec.status, SmartRuleSyncStatus.applied);
      expect(fx.db.profileWrites, 0);
      expect(await fx.db.getSetting(_profileKey), isNull);
      expect(fx.c.protectionBootstrap.extraLevelsCurrent, isTrue);
      expect(await fx.grant(_std), _L.standard);
      expect(await fx.grant(_sens), _L.critical); // the rule, unchanged
      expect(await fx.savedLevels(), _baselines);
    });

    test('N-2. no rules, Normal: empty transport (unchanged from Phase 10)',
        () async {
      final _Fx fx = await _Fx.create();
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.lastSent, isEmpty);
      expect(await fx.grant(_std), _L.standard);
      expect(await fx.grant(_sens), _L.sensitive);
    });
  });

  group('P11-M1: harness-activated presets (raise-only)', () {
    test(
        'G-1. Guest: the combined transport is sent, Dart grants are '
        'Critical, unprotected apps untouched, saved levels unchanged',
        () async {
      final _Fx fx = await _Fx.create(
        rules: <SmartRule>[_chatCritical],
        profiles: _active(_guest),
      );
      // R-A before the first read: both caches unknown → Critical floor.
      expect(fx.c.protectionBootstrap.extraLevelsCurrent, isFalse);
      expect(await fx.grant(_std), _L.critical);

      expect((await fx.c.protectionBootstrap.synchronize()).isSuccess, isTrue);
      expect(fx.c.protectionBootstrap.extraLevelsCurrent, isTrue);
      expect(
        _sorted(fx.lastSent!),
        _sorted(SecurityProfilePolicy.nativeTransport(
            <SmartRule>[_chatCritical], _guest, <String>{_std, _sens})),
      );
      final SmartRuleNativeRecord rec =
          fx.c.protectionBootstrap.lastRuleExchange!;
      expect(_sorted(rec.sentRules!),
          _sorted(SmartRulePolicy.nativeTransport(<SmartRule>[_chatCritical])));
      expect(rec.sentProfileOverlay, hasLength(1));
      expect(rec.status, SmartRuleSyncStatus.applied);

      expect(await fx.grant(_std), _L.critical);
      expect(await fx.grant(_sens), _L.critical);
      // "All protected apps" never reaches an unprotected app.
      expect(await fx.c.accessController.evaluate(_maps), AccessDecision.allow);
      expect(fx.c.protectionBootstrap.extraLevelFor(_maps, DateTime(2026)),
          isNull);
      expect(await fx.grant(_maps), _L.standard);
      expect(fx.watcher.protectedPackages, <String>{_std, _sens});
      expect(fx.watcher.securityLevels, _baselines);
      expect(await fx.savedLevels(), _baselines);
      expect(fx.db.profileWrites, 0);
      // Engine (native stand-in) level matches Dart: Critical for both.
      final DateTime now = DateTime(2026, 11, 2, 12);
      expect(fx.watcher.simulatedRuleLevel(_std, now), _L.critical);
      expect(fx.watcher.simulatedRuleLevel(_sens, now), _L.critical);
      expect(fx.watcher.simulatedRuleLevel(_maps, now), isNull);
    });

    test(
        'K-1. Kids with a per-app Sensitive overlay: raises notes only; an '
        'unprotected app in the profile is never protected', () async {
      final _Fx fx = await _Fx.create(
        profiles: _active(SecurityProfile(
          kind: SecurityProfileKind.kids,
          appLevels: const <String, _L>{
            _std: _L.sensitive,
            _maps: _L.critical,
          },
        )),
      );
      await fx.c.protectionBootstrap.synchronize();
      expect(await fx.grant(_std), _L.sensitive);
      expect(await fx.grant(_sens), _L.sensitive); // already Sensitive
      // Never challenged and never protected. (Its Dart level mirrors the
      // compiled per-app entry, exactly like a Phase 10 rule that targets an
      // unprotected app; native ignores unprotected packages.)
      expect(await fx.c.accessController.evaluate(_maps), AccessDecision.allow);
      expect(fx.c.protectionBootstrap.extraLevelFor(_maps, DateTime(2026)),
          _L.critical);
      expect(fx.watcher.protectedPackages, <String>{_std, _sens});
      expect(fx.watcher.authorizedPackages, isEmpty);
    });

    test(
        'D6-1. leaving Guest WITHOUT authorization is HELD natively (stricter '
        'union) and Dart never lowers native; with the CR-2 flag it applies',
        () async {
      final _Fx fx = await _Fx.create(profiles: _active(_guest));
      await fx.c.protectionBootstrap.synchronize();
      final DateTime now = DateTime(2026, 11, 2, 12);
      expect(fx.watcher.simulatedRuleLevel(_std, now), _L.critical);

      // Harness edits storage to Normal (M2 will route this through PIN).
      expect(
        (await fx.c.securityProfiles.saveProfiles(SecurityProfileSet.defaults(),
                expected: _active(_guest)))
            .isSuccess,
        isTrue,
      );
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.c.protectionBootstrap.lastRuleExchange!.status,
          SmartRuleSyncStatus.held);
      expect(fx.watcher.simulatedRuleLevel(_std, now), _L.critical);
      expect(fx.watcher.authorizedPackages, isEmpty);

      await fx.c.protectionBootstrap
          .synchronize(authorizedRuleRelaxation: true);
      expect(fx.c.protectionBootstrap.lastRuleExchange!.status,
          SmartRuleSyncStatus.applied);
      expect(fx.watcher.simulatedRuleLevel(_std, now), isNull);
      // Relaxation grants nothing.
      expect(fx.watcher.authorizedPackages, isEmpty);
    });
  });

  group('P11-M1: R-A extended to the profile read', () {
    test(
        'RA-P1. profile read failure: NO transport (native keeps its copy), '
        'not current → Dart Critical floor; rules alone stay current',
        () async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_chatCritical]);
      fx.db.failProfileReads = true;
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.lastSent, isNull);
      expect(fx.c.protectionBootstrap.lastRuleExchange!.status,
          SmartRuleSyncStatus.kept);
      expect(fx.c.protectionBootstrap.ruleCache.current, isTrue);
      expect(fx.c.protectionBootstrap.profileCache.current, isFalse);
      expect(fx.c.protectionBootstrap.extraLevelsCurrent, isFalse);
      expect(fx.c.protectionBootstrap.lastProfileReadError, isNotNull);
      expect(await fx.grant(_std), _L.critical);
      expect(await fx.c.accessController.evaluate(_maps), AccessDecision.allow);
      expect(await fx.savedLevels(), _baselines);

      fx.db.failProfileReads = false;
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.c.protectionBootstrap.extraLevelsCurrent, isTrue);
      expect(fx.c.protectionBootstrap.lastProfileReadError, isNull);
      expect(await fx.grant(_std), _L.standard);
    });

    test(
        'RA-P2. corrupt stored profiles: never replaced by defaults, never '
        'overwritten, no transport, Critical floor', () async {
      final _Fx fx = await _Fx.create();
      await fx.db.setSetting(_profileKey, '{"version":1,"oops":1}');
      fx.db.profileWrites = 0;
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.lastSent, isNull);
      expect(fx.c.protectionBootstrap.extraLevelsCurrent, isFalse);
      expect(await fx.grant(_std), _L.critical);
      expect(await fx.db.getSetting(_profileKey), '{"version":1,"oops":1}');
      expect(fx.db.profileWrites, 0);
    });

    test(
        'RA-P3. a failed read after a Guest load keeps Guest (never falls '
        'back to Normal) and stays at the Critical floor', () async {
      final _Fx fx = await _Fx.create(profiles: _active(_guest));
      await fx.c.protectionBootstrap.synchronize();
      fx.db.failProfileReads = true;
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.lastSent, isNull);
      expect(fx.c.protectionBootstrap.profileCache.active.kind,
          SecurityProfileKind.guest);
      expect(await fx.grant(_std), _L.critical);
      expect(await fx.grant(_sens), _L.critical);
    });

    test('RA-P4. rule read failure with a readable profile: no transport',
        () async {
      final _Fx fx = await _Fx.create(profiles: _active(_guest));
      fx.db.failRuleReads = true;
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.lastSent, isNull);
      expect(fx.c.protectionBootstrap.profileCache.current, isTrue);
      expect(fx.c.protectionBootstrap.extraLevelsCurrent, isFalse);
      expect(await fx.grant(_std), _L.critical);
    });
  });

  group('P11-M1: static guarantees', () {
    final List<String> newLib = <String>[
      'lib/profiles/security_profile.dart',
      'lib/profiles/security_profile_document.dart',
      'lib/profiles/security_profile_policy.dart',
      'lib/data/repositories/security_profile_repository.dart',
      'lib/data/repositories/impl/security_profile_repository_impl.dart',
    ];

    test('S-1. new code never touches the legacy LockProfile scaffold', () {
      for (final String f in newLib) {
        // Code only: doc comments may NAME the legacy scaffold.
        final String code = File(f)
            .readAsLinesSync()
            .where((String l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        expect(code, isNot(contains('lock_profile')), reason: f);
        expect(code, isNot(contains('profile_manager')), reason: f);
        expect(code, isNot(contains('LockProfile')), reason: f);
      }
      expect(SecurityProfileRepositoryImpl.storageKey,
          isNot('pref.profile.last_active_id'));
    });

    test('S-2. no timers, polling or background work in profile code', () {
      for (final String f in newLib) {
        final String src = File(f).readAsStringSync();
        for (final String banned in <String>[
          'Timer',
          'Stream.periodic',
          'Future.delayed',
          'Isolate',
          'WorkManager',
        ]) {
          expect(src, isNot(contains(banned)), reason: '$f: $banned');
        }
      }
    });

    test(
        'S-3. no app code can activate a profile in M1 (no saveProfiles '
        'caller outside the repository)', () {
      final List<String> callers = <String>[
        for (final FileSystemEntity e
            in Directory('lib').listSync(recursive: true))
          if (e is File &&
              e.path.endsWith('.dart') &&
              e.readAsStringSync().contains('saveProfiles('))
            e.path.replaceAll(r'\', '/'),
      ]..sort();
      expect(callers, <String>[
        'lib/data/repositories/impl/security_profile_repository_impl.dart',
        'lib/data/repositories/security_profile_repository.dart',
      ]);
    });

    test('S-4. Health and Score code does not read profiles (advisory only)',
        () {
      for (final FileSystemEntity e
          in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final String p = e.path.replaceAll(r'\', '/');
        if (!p.contains('health') && !p.contains('score')) continue;
        expect(e.readAsStringSync(), isNot(contains('security_profile')),
            reason: p);
      }
    });

    test('S-5. no Settings / Play Store package in profile code (D3)', () {
      for (final String f in newLib) {
        final String src = File(f).readAsStringSync();
        expect(src, isNot(contains('com.android.settings')), reason: f);
        expect(src, isNot(contains('com.android.vending')), reason: f);
      }
      expect(SecurityProfileDocument.encode(SecurityProfileSet.defaults()),
          isNot(contains('com.')));
    });
  });
}
