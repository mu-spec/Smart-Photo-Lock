// Phase 8 / M1 — Security level model & per-app persistence (PRD 8A / 8B).
//
// Production model, repository and in-memory store (same contract as the
// SQLite store), plus the SQLite store's pure parts: schema/migration SQL
// constants, the PRAGMA-based migration guard and the row mapper. The SQL
// itself is additionally executed against host SQLite outside the repository
// (Phase8_M1/sql_migration_check.py); no device database was used.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/impl/protected_apps_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/protected_apps_repository.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/data/storage/impl/sqflite_local_database.dart';
import 'package:smart_app_lock/utilities/result.dart';

const String _wa = 'com.whatsapp';
const String _bank = 'com.example.bank';
const String _notes = 'com.example.notes';

ProtectedApp _app(String pkg, {AppSecurityLevel? level, String? label}) =>
    ProtectedApp(
      packageName: pkg,
      label: label ?? pkg,
      addedAt: DateTime(2026, 11, 2, 9),
      securityLevel: level ?? AppSecurityLevel.defaultLevel,
    );

Future<AppSecurityLevel?> _levelOf(
    ProtectedAppsRepository r, String pkg) async {
  final List<ProtectedApp> apps = (await r.getProtectedApps()).valueOrNull!;
  for (final ProtectedApp a in apps) {
    if (a.packageName == pkg) return a.securityLevel;
  }
  return null;
}

/// Store whose level writes fail (simulated database error).
class _FailingLevelWrites extends InMemoryLocalDatabase {
  int levelWrites = 0;

  @override
  Future<bool> updateProtectedAppSecurityLevel(
    String packageName,
    AppSecurityLevel level,
  ) async {
    levelWrites++;
    throw StateError('simulated level write failure');
  }
}

/// Store whose level writes wait for [gate] (overlap / ordering tests).
class _GatedLevelWrites extends InMemoryLocalDatabase {
  final List<Completer<void>> gates = <Completer<void>>[];

  @override
  Future<bool> updateProtectedAppSecurityLevel(
    String packageName,
    AppSecurityLevel level,
  ) async {
    final Completer<void> gate = Completer<void>();
    gates.add(gate);
    await gate.future;
    return super.updateProtectedAppSecurityLevel(packageName, level);
  }
}

void main() {
  group('8A: security level model', () {
    test('exactly three levels with stable explicit ids, ordered', () {
      expect(AppSecurityLevel.values, hasLength(3));
      expect(
        AppSecurityLevel.values.map((AppSecurityLevel l) => l.storageId),
        <String>['standard', 'sensitive', 'critical'],
      );
      expect(
        AppSecurityLevel.values.map((AppSecurityLevel l) => l.label),
        <String>['Standard', 'Sensitive', 'Critical'],
      );
      expect(
        AppSecurityLevel.values.map((AppSecurityLevel l) => l.rank),
        <int>[0, 1, 2],
      );
      expect(
        AppSecurityLevel.critical.isStricterThan(AppSecurityLevel.sensitive),
        isTrue,
      );
      expect(
        AppSecurityLevel.sensitive.isStricterThan(AppSecurityLevel.standard),
        isTrue,
      );
      expect(
        AppSecurityLevel.standard.isStricterThan(AppSecurityLevel.standard),
        isFalse,
      );
      expect(AppSecurityLevel.defaultLevel, AppSecurityLevel.standard);
      expect(AppSecurityLevel.strictest, AppSecurityLevel.critical);
      for (final AppSecurityLevel l in AppSecurityLevel.values) {
        expect(AppSecurityLevel.fromStorage(l.storageId), l);
        expect(l.description, isNotEmpty);
      }
    });

    test('descriptions never overclaim (M2: they describe real behaviour)', () {
      final String all = AppSecurityLevel.values
          .map((AppSecurityLevel l) => l.description.toLowerCase())
          .join(' ');
      for (final String claim in <String>[
        'always asks',
        'forces',
        'is enforced',
        'unhackable',
        '100%',
        'guarantee',
      ]) {
        expect(all, isNot(contains(claim)));
      }
    });

    test('missing value → Standard; unreadable value → Critical, never weaker',
        () {
      expect(AppSecurityLevel.fromStorage(null), AppSecurityLevel.standard);
      for (final Object raw in <Object>[
        'bogus',
        'CRITICAL',
        'Standard',
        ' standard',
        '',
        'unlocked',
        'none',
        7,
        true,
        const <String>['standard'],
      ]) {
        expect(
          AppSecurityLevel.fromStorage(raw),
          AppSecurityLevel.critical,
          reason: 'raw=$raw',
        );
        expect(AppSecurityLevel.isKnownStorageId(raw), isFalse);
      }
    });

    test('ProtectedApp defaults to Standard; JSON round-trip and legacy JSON',
        () {
      expect(_app(_wa).securityLevel, AppSecurityLevel.standard);
      final ProtectedApp critical =
          _app(_bank, level: AppSecurityLevel.critical);
      expect(
        ProtectedApp.fromJson(critical.toJson()).securityLevel,
        AppSecurityLevel.critical,
      );
      expect(critical.toJson()['securityLevel'], 'critical');

      final Map<String, dynamic> legacy = <String, dynamic>{
        'packageName': _wa,
        'label': 'WhatsApp',
        'addedAt': DateTime(2026, 1, 1).toIso8601String(),
        'sortOrder': 0,
      };
      expect(
        ProtectedApp.fromJson(legacy).securityLevel,
        AppSecurityLevel.standard,
      );
      expect(
        ProtectedApp.fromJson(<String, dynamic>{...legacy, 'securityLevel': 3})
            .securityLevel,
        AppSecurityLevel.critical,
      );
    });
  });

  group('8B: per-app level persistence (repository over the store)', () {
    late InMemoryLocalDatabase store;
    late ProtectedAppsRepository repo;

    setUp(() {
      store = InMemoryLocalDatabase();
      repo = ProtectedAppsRepositoryImpl(store);
    });

    test('a newly protected app is Standard', () async {
      await repo.add(_app(_wa));
      expect(await _levelOf(repo, _wa), AppSecurityLevel.standard);
    });

    test('Standard → Sensitive → Critical → Standard, each persisted',
        () async {
      await repo.add(_app(_wa));
      for (final AppSecurityLevel level in <AppSecurityLevel>[
        AppSecurityLevel.sensitive,
        AppSecurityLevel.critical,
        AppSecurityLevel.standard,
      ]) {
        expect((await repo.setSecurityLevel(_wa, level)).isSuccess, isTrue);
        // Reload through a brand-new repository over the same store
        // ("app restart" stand-in for the SQLite file).
        expect(
          await _levelOf(ProtectedAppsRepositoryImpl(store), _wa),
          level,
        );
      }
    });

    test(
        'levels are independent per app; other fields and the protected set '
        'are unchanged by a level change', () async {
      await repo.add(_app(_wa, label: 'WhatsApp'));
      await repo.add(_app(_bank, label: 'Bank'));
      await repo.add(_app(_notes, label: 'Notes'));
      await repo.setSecurityLevel(_bank, AppSecurityLevel.critical);
      await repo.setSecurityLevel(_notes, AppSecurityLevel.sensitive);

      final List<ProtectedApp> apps =
          (await repo.getProtectedApps()).valueOrNull!;
      expect(
        <String, AppSecurityLevel>{
          for (final ProtectedApp a in apps) a.packageName: a.securityLevel,
        },
        <String, AppSecurityLevel>{
          _wa: AppSecurityLevel.standard,
          _bank: AppSecurityLevel.critical,
          _notes: AppSecurityLevel.sensitive,
        },
      );
      final ProtectedApp bank =
          apps.firstWhere((ProtectedApp a) => a.packageName == _bank);
      expect(bank.label, 'Bank');
      expect(bank.addedAt, DateTime(2026, 11, 2, 9));
      expect((await repo.count()).valueOrNull, 3);
    });

    test(
        'removing protection retires the level; re-protecting starts from '
        'Standard (documented default)', () async {
      await repo.add(_app(_bank));
      await repo.setSecurityLevel(_bank, AppSecurityLevel.critical);
      await repo.remove(_bank);
      expect(await _levelOf(repo, _bank), isNull);
      await repo.add(_app(_bank));
      expect(await _levelOf(repo, _bank), AppSecurityLevel.standard);
    });

    test(
        'a level change never protects an app: unknown / removed / blank '
        'package fails and stores nothing', () async {
      final Result<void> missing =
          await repo.setSecurityLevel(_bank, AppSecurityLevel.critical);
      expect(missing.isFailure, isTrue);
      expect((await repo.isProtected(_bank)).valueOrNull, isFalse);
      expect((await repo.count()).valueOrNull, 0);

      expect(
        (await repo.setSecurityLevel('  ', AppSecurityLevel.critical))
            .isFailure,
        isTrue,
      );
      expect((await repo.count()).valueOrNull, 0);
    });

    test(
        'duplicate protect of the same package: one record, level kept '
        '(a repeated protect never downgrades)', () async {
      await repo.add(_app(_bank));
      await repo.setSecurityLevel(_bank, AppSecurityLevel.critical);
      await repo.add(_app(_bank, label: 'Bank v2')); // default level Standard
      await repo.add(_app(_bank, level: AppSecurityLevel.standard));
      final List<ProtectedApp> apps =
          (await repo.getProtectedApps()).valueOrNull!;
      expect(apps, hasLength(1));
      expect(apps.single.securityLevel, AppSecurityLevel.critical);
      expect(apps.single.label, _bank, reason: 'display fields still upsert');
    });

    test('a new record may be created with an explicit level', () async {
      await repo.add(_app(_bank, level: AppSecurityLevel.sensitive));
      expect(await _levelOf(repo, _bank), AppSecurityLevel.sensitive);
    });

    test('rapid / concurrent level writes: deterministic, last request wins',
        () async {
      await repo.add(_app(_wa));
      await Future.wait(<Future<Result<void>>>[
        repo.setSecurityLevel(_wa, AppSecurityLevel.critical),
        repo.setSecurityLevel(_wa, AppSecurityLevel.standard),
        repo.setSecurityLevel(_wa, AppSecurityLevel.sensitive),
      ]);
      expect(await _levelOf(repo, _wa), AppSecurityLevel.sensitive);
    });

    test('a protect racing a level change cannot downgrade the level',
        () async {
      final _GatedLevelWrites gated = _GatedLevelWrites();
      final ProtectedAppsRepository r = ProtectedAppsRepositoryImpl(gated);
      await r.add(_app(_bank));
      final Future<Result<void>> set =
          r.setSecurityLevel(_bank, AppSecurityLevel.critical);
      await r.add(_app(_bank)); // a stale "protect" (default Standard)
      gated.gates.single.complete();
      expect((await set).isSuccess, isTrue);
      await r.add(_app(_bank)); // and again after the write
      expect(await _levelOf(r, _bank), AppSecurityLevel.critical);
    });

    test(
        'a level change racing removal: the removal wins, nothing is '
        're-created, the write reports failure', () async {
      final _GatedLevelWrites gated = _GatedLevelWrites();
      final ProtectedAppsRepository r = ProtectedAppsRepositoryImpl(gated);
      await r.add(_app(_bank));
      final Future<Result<void>> set =
          r.setSecurityLevel(_bank, AppSecurityLevel.critical);
      await r.remove(_bank);
      gated.gates.single.complete();
      expect((await set).isFailure, isTrue);
      expect((await r.isProtected(_bank)).valueOrNull, isFalse);
    });

    test('write failure is reported and the stored level is unchanged',
        () async {
      final _FailingLevelWrites failing = _FailingLevelWrites();
      final ProtectedAppsRepository r = ProtectedAppsRepositoryImpl(failing);
      await r.add(_app(_bank, level: AppSecurityLevel.sensitive));
      final Result<void> result =
          await r.setSecurityLevel(_bank, AppSecurityLevel.standard);
      expect(result.isFailure, isTrue);
      expect(failing.levelWrites, 1);
      expect(await _levelOf(r, _bank), AppSecurityLevel.sensitive);
      expect((await r.isProtected(_bank)).valueOrNull, isTrue);
    });
  });

  group('SQLite store: schema v2 and migration (pure parts)', () {
    test('schema version 2 in both stores', () {
      expect(SqfliteLocalDatabase().schemaVersion, 2);
      expect(InMemoryLocalDatabase().schemaVersion, 2);
    });

    test('fresh install creates the level column NOT NULL DEFAULT standard',
        () {
      final String sql = SqfliteLocalDatabase.createProtectedAppsSql;
      expect(sql, contains('package_name TEXT PRIMARY KEY'));
      expect(sql, contains("security_level TEXT NOT NULL DEFAULT 'standard'"));
    });

    test(
        'v1 → v2 adds the column with a constant Standard default and no '
        'row rewrite; SQL stays within SQLite 3.22 (Android 9)', () {
      final String m = SqfliteLocalDatabase.migrateV1ToV2Sql;
      expect(
        m,
        "ALTER TABLE protected_apps ADD COLUMN security_level TEXT NOT NULL "
        "DEFAULT 'standard'",
      );
      for (final String sql in <String>[
        m,
        SqfliteLocalDatabase.insertProtectedAppSql,
        SqfliteLocalDatabase.refreshProtectedAppSql,
        SqfliteLocalDatabase.updateSecurityLevelSql,
      ]) {
        final String u = sql.toUpperCase();
        expect(u, isNot(contains('ON CONFLICT')), reason: 'UPSERT is 3.24+');
        expect(u, isNot(contains('RETURNING')), reason: 'RETURNING is 3.35+');
        expect(u, isNot(contains('DROP')));
        expect(u, isNot(contains('DELETE')));
      }
      expect(
        SqfliteLocalDatabase.insertProtectedAppSql,
        startsWith('INSERT OR IGNORE INTO protected_apps'),
      );
      expect(
        SqfliteLocalDatabase.refreshProtectedAppSql,
        isNot(contains('security_level')),
        reason: 'protecting again never rewrites the level',
      );
      expect(
        SqfliteLocalDatabase.updateSecurityLevelSql,
        'UPDATE protected_apps SET security_level = ? WHERE package_name = ?',
      );
    });

    test(
        'migration guard: only a table without the column is altered '
        '(idempotent after a downgrade/upgrade cycle)', () {
      final List<Map<String, Object?>> v1 = <Map<String, Object?>>[
        <String, Object?>{'name': 'package_name'},
        <String, Object?>{'name': 'label'},
        <String, Object?>{'name': 'added_at'},
        <String, Object?>{'name': 'sort_order'},
      ];
      expect(SqfliteLocalDatabase.needsSecurityLevelColumn(v1), isTrue);
      expect(
        SqfliteLocalDatabase.needsSecurityLevelColumn(<Map<String, Object?>>[
          ...v1,
          <String, Object?>{'name': 'security_level'},
        ]),
        isFalse,
      );
    });

    test(
        'row mapper: legacy row → Standard, malformed level → Critical, the '
        'app is never dropped', () {
      final Map<String, Object?> base = <String, Object?>{
        'package_name': _bank,
        'label': 'Bank',
        'added_at': DateTime(2026, 1, 1).millisecondsSinceEpoch,
        'sort_order': 0,
      };
      expect(
        SqfliteLocalDatabase.protectedAppFromRow(base).securityLevel,
        AppSecurityLevel.standard,
      );
      for (final Object? raw in <Object?>['sensitive', 'critical']) {
        expect(
          SqfliteLocalDatabase.protectedAppFromRow(
            <String, Object?>{...base, 'security_level': raw},
          ).securityLevel.storageId,
          raw,
        );
      }
      final ProtectedApp bad = SqfliteLocalDatabase.protectedAppFromRow(
        <String, Object?>{...base, 'security_level': 'r0gue'},
      );
      expect(bad.packageName, _bank);
      expect(bad.securityLevel, AppSecurityLevel.critical);
    });
  });
}
