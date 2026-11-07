// Phase 10 / M1: Smart Rule configuration storage.
//
// SIMULATED storage boundary: the production SmartRuleRepositoryImpl over a
// test LocalDatabase whose settings table is a real file on disk, so a
// "restart" is a NEW database instance and a NEW repository reading the same
// file (nothing shared in memory). Faults are injected at that boundary. The
// SQLite implementation itself is not exercised (no sqflite in unit tests).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/impl/smart_rule_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/smart_rule_repository.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/utilities/result.dart';

typedef _K = SmartRuleStoreErrorKind;

const String _key = SmartRuleRepositoryImpl.storageKey;

/// Settings persisted to [file] on every call; other tables in memory.
class _FileDb extends InMemoryLocalDatabase {
  _FileDb(this.file);

  final File file;

  /// Every getSetting throws this.
  Object? readError;

  /// The next N setSetting calls fail.
  int failWrites = 0;

  /// A failing write still lands first (like a store that keeps the value
  /// in memory or on disk and then reports an error).
  bool storeBeforeFailing = false;

  /// setSetting reports success but stores nothing.
  bool silentNoOp = false;

  /// removeSetting throws.
  bool failRemove = false;

  final List<String> setKeys = <String>[];
  final List<String> removedKeys = <String>[];

  Map<String, String> _all() => file.existsSync()
      ? (jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)
          .cast<String, String>()
      : <String, String>{};

  void _save(Map<String, String> m) =>
      file.writeAsStringSync(jsonEncode(m), flush: true);

  String? rawValue() => _all()[_key];

  void putRaw(String value) => _save(<String, String>{..._all(), _key: value});

  @override
  Future<String?> getSetting(String key) async {
    final Object? e = readError;
    if (e != null) throw e;
    return _all()[key];
  }

  @override
  Future<void> setSetting(String key, String value) async {
    setKeys.add(key);
    if (silentNoOp) return;
    final bool fail = failWrites > 0;
    if (fail) failWrites--;
    if (fail && !storeBeforeFailing) {
      throw const FileSystemException('simulated write failure');
    }
    _save(<String, String>{..._all(), key: value});
    if (fail) throw const FileSystemException('simulated late failure');
  }

  @override
  Future<void> removeSetting(String key) async {
    removedKeys.add(key);
    if (failRemove) throw const FileSystemException('simulated remove');
    _save(<String, String>{..._all()}..remove(key));
  }
}

SmartRule _rule(
  String id, {
  String name = 'Rule',
  List<String> targets = const <String>['com.example.mail'],
  bool enabled = true,
}) =>
    SmartRule(
      id: id,
      name: name,
      targetPackages: targets,
      days: SmartRuleDays.weekdays,
      time: SmartRuleTime.window(startMinute: 540, endMinute: 1020),
      enabled: enabled,
    );

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('smart_rules_test');
    file = File('${dir.path}/settings.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// A fresh database and repository over the same file (SIMULATED restart).
  (SmartRuleRepositoryImpl, _FileDb) open() {
    final _FileDb db = _FileDb(file);
    return (SmartRuleRepositoryImpl(db), db);
  }

  Future<List<SmartRule>> readFresh() async {
    final Result<List<SmartRule>> r = await open().$1.getRules();
    expect(r.isSuccess, isTrue, reason: '${r.errorOrNull}');
    return r.valueOrNull!;
  }

  void expectFailure(Result<Object?> r, _K kind) {
    expect(r.isFailure, isTrue);
    final Object? e = r.errorOrNull;
    expect(e, isA<SmartRuleStoreException>());
    expect((e! as SmartRuleStoreException).kind, kind, reason: '$e');
  }

  test('nothing saved → empty list (the only case that is empty)', () async {
    final (SmartRuleRepositoryImpl repo, _FileDb db) = open();
    final Result<List<SmartRule>> r = await repo.getRules();
    expect(r.valueOrNull, isEmpty);
    expect(db.setKeys, isEmpty);
  });

  group('26. save and read', () {
    test('saved rules read back in order, from the same and a fresh instance',
        () async {
      final (SmartRuleRepositoryImpl repo, _) = open();
      expect((await repo.saveRule(_rule('b'))).isSuccess, isTrue);
      expect((await repo.saveRule(_rule('a'))).isSuccess, isTrue);
      expect((await repo.getRules()).valueOrNull, <SmartRule>[
        _rule('b'),
        _rule('a'),
      ]);
      expect(await readFresh(), <SmartRule>[_rule('b'), _rule('a')]);
    });

    test('the stored value is the versioned v2 document under one key',
        () async {
      final (SmartRuleRepositoryImpl repo, _FileDb db) = open();
      await repo.saveRule(_rule('a'));
      final Map<String, dynamic> doc =
          jsonDecode(db.rawValue()!) as Map<String, dynamic>;
      expect(doc['schema'], 'smart_rules');
      expect(doc['version'], 2);
      expect((doc['rules'] as List<dynamic>).length, 1);
      expect(db.setKeys.toSet(), <String>{_key});
    });
  });

  group('27. update without a duplicate record', () {
    test('same id replaces in place; order kept; identical save writes nothing',
        () async {
      final (SmartRuleRepositoryImpl repo, _FileDb db) = open();
      await repo.saveRule(_rule('a'));
      await repo.saveRule(_rule('b'));
      await repo.saveRule(_rule('a', name: 'Renamed'));
      expect(await readFresh(), <SmartRule>[
        _rule('a', name: 'Renamed'),
        _rule('b'),
      ]);
      final int writes = db.setKeys.length;
      expect((await repo.saveRule(_rule('b'))).isSuccess, isTrue);
      expect(db.setKeys.length, writes);
    });

    test('concurrent saves on one instance are serialized (no lost update)',
        () async {
      final (SmartRuleRepositoryImpl repo, _) = open();
      final List<Result<void>> results =
          await Future.wait(<Future<Result<void>>>[
        repo.saveRule(_rule('a')),
        repo.saveRule(_rule('b')),
        repo.saveRule(_rule('c')),
        repo.setRuleEnabled('a', enabled: false),
      ]);
      expect(results.every((Result<void> r) => r.isSuccess), isTrue);
      expect(await readFresh(), <SmartRule>[
        _rule('a', enabled: false),
        _rule('b'),
        _rule('c'),
      ]);
    });
  });

  group('28. delete', () {
    test('removes only that rule; persisted', () async {
      final (SmartRuleRepositoryImpl repo, _) = open();
      await repo.saveRule(_rule('a'));
      await repo.saveRule(_rule('b'));
      expect((await repo.deleteRule('a')).isSuccess, isTrue);
      expect(await readFresh(), <SmartRule>[_rule('b')]);
      expect((await repo.deleteRule('b')).isSuccess, isTrue);
      expect(await readFresh(), isEmpty);
    });

    test('an unknown id is notFound and writes nothing', () async {
      final (SmartRuleRepositoryImpl repo, _FileDb db) = open();
      await repo.saveRule(_rule('a'));
      final int writes = db.setKeys.length;
      expectFailure(await repo.deleteRule('zz'), _K.notFound);
      expect(db.setKeys.length, writes);
      expect(await readFresh(), <SmartRule>[_rule('a')]);
    });
  });

  group('29. enabled-state persistence', () {
    test('disable keeps the rule; survives restart; re-enable', () async {
      final (SmartRuleRepositoryImpl repo, _) = open();
      await repo.saveRule(_rule('a'));
      await repo.saveRule(_rule('b'));
      expect(
          (await repo.setRuleEnabled('a', enabled: false)).isSuccess, isTrue);
      expect(await readFresh(), <SmartRule>[
        _rule('a', enabled: false),
        _rule('b'),
      ]);
      final (SmartRuleRepositoryImpl again, _) = open();
      expect(
          (await again.setRuleEnabled('a', enabled: true)).isSuccess, isTrue);
      expect(await readFresh(), <SmartRule>[_rule('a'), _rule('b')]);
    });

    test('unknown id → notFound; unchanged state writes nothing', () async {
      final (SmartRuleRepositoryImpl repo, _FileDb db) = open();
      await repo.saveRule(_rule('a'));
      final int writes = db.setKeys.length;
      expectFailure(
        await repo.setRuleEnabled('zz', enabled: false),
        _K.notFound,
      );
      expect((await repo.setRuleEnabled('a', enabled: true)).isSuccess, isTrue);
      expect(db.setKeys.length, writes);
    });
  });

  group('30. failed write rollback', () {
    test('a write that fails before storing: failure, previous rules kept',
        () async {
      final (SmartRuleRepositoryImpl repo, _FileDb db) = open();
      await repo.saveRule(_rule('a'));
      final String before = db.rawValue()!;
      db.failWrites = 1;
      expectFailure(await repo.saveRule(_rule('b')), _K.writeFailed);
      expect(db.rawValue(), before);
      expect((await repo.getRules()).valueOrNull, <SmartRule>[_rule('a')]);
      expect(await readFresh(), <SmartRule>[_rule('a')]);
    });

    test(
        'a write that lands and THEN fails is rolled back to the previous '
        'document (no false success in storage or memory)', () async {
      final (SmartRuleRepositoryImpl repo, _FileDb db) = open();
      await repo.saveRule(_rule('a'));
      final String before = db.rawValue()!;
      db
        ..failWrites = 1
        ..storeBeforeFailing = true;
      expectFailure(
        await repo.setRuleEnabled('a', enabled: false),
        _K.writeFailed,
      );
      expect(db.rawValue(), before);
      expect((await repo.getRules()).valueOrNull, <SmartRule>[_rule('a')]);
      expect(await readFresh(), <SmartRule>[_rule('a')]);
    });

    test('first-ever write lands then fails → the key is removed again',
        () async {
      final (SmartRuleRepositoryImpl repo, _FileDb db) = open();
      db
        ..failWrites = 1
        ..storeBeforeFailing = true;
      expectFailure(await repo.saveRule(_rule('a')), _K.writeFailed);
      expect(db.removedKeys, <String>[_key]);
      expect(db.rawValue(), isNull);
      expect(await readFresh(), isEmpty);
    });

    test('a write reported as successful but not stored is not confirmed',
        () async {
      final (SmartRuleRepositoryImpl repo, _FileDb db) = open();
      await repo.saveRule(_rule('a'));
      db.silentNoOp = true;
      expectFailure(await repo.deleteRule('a'), _K.writeFailed);
      db.silentNoOp = false;
      expect(await readFresh(), <SmartRule>[_rule('a')]);
    });

    test('a failing rollback still reports the original failure', () async {
      final (SmartRuleRepositoryImpl repo, _FileDb db) = open();
      db
        ..failWrites = 1
        ..storeBeforeFailing = true
        ..failRemove = true;
      final Result<void> r = await repo.saveRule(_rule('a'));
      expectFailure(r, _K.writeFailed);
      expect(
        (r.errorOrNull! as SmartRuleStoreException).cause,
        isA<FileSystemException>().having(
          (FileSystemException e) => e.message,
          'message',
          'simulated late failure',
        ),
      );
    });

    test('after a failure the next write works normally', () async {
      final (SmartRuleRepositoryImpl repo, _FileDb db) = open();
      db.failWrites = 1;
      expectFailure(await repo.saveRule(_rule('a')), _K.writeFailed);
      expect((await repo.saveRule(_rule('a'))).isSuccess, isTrue);
      expect(await readFresh(), <SmartRule>[_rule('a')]);
    });
  });

  group('31. storage unavailable', () {
    test('reads fail explicitly; writes are refused without writing', () async {
      final (SmartRuleRepositoryImpl repo, _FileDb db) = open();
      await repo.saveRule(_rule('a'));
      final int writes = db.setKeys.length;
      db.readError = const FileSystemException('simulated read failure');
      expectFailure(await repo.getRules(), _K.storageUnavailable);
      expectFailure(await repo.saveRule(_rule('b')), _K.storageUnavailable);
      expectFailure(await repo.deleteRule('a'), _K.storageUnavailable);
      expectFailure(
        await repo.setRuleEnabled('a', enabled: false),
        _K.storageUnavailable,
      );
      expect(db.setKeys.length, writes);
      expect(db.removedKeys, isEmpty);
      db.readError = null;
      expect(await readFresh(), <SmartRule>[_rule('a')]);
    });
  });

  group('32. corrupt saved data fails safely', () {
    for (final (String label, String raw, _K kind) in <(String, String, _K)>[
      ('broken JSON', '{"schema":"smart_rules","vers', _K.corrupt),
      (
        'one invalid rule among valid ones',
        '{"schema":"smart_rules","version":1,"rules":['
            '{"id":"a","name":"A","enabled":true,"targets":["com.a.b"],'
            '"days":[1],"time":{"type":"allDay"}},'
            '{"id":"b","name":"B","enabled":true,"targets":[],'
            '"days":[1],"time":{"type":"allDay"}}]}',
        _K.corrupt,
      ),
      (
        'a newer schema version',
        '{"schema":"smart_rules","version":3,"rules":[],"actions":{}}',
        _K.unsupportedVersion,
      ),
    ]) {
      test(
          '$label: read fails (no empty list); every write refused; data '
          'kept byte-for-byte', () async {
        final (SmartRuleRepositoryImpl repo, _FileDb db) = open();
        db.putRaw(raw);
        final Result<List<SmartRule>> read = await repo.getRules();
        expectFailure(read, kind);
        expect(read.valueOrNull, isNull);
        expectFailure(await repo.saveRule(_rule('n')), kind);
        expectFailure(await repo.deleteRule('a'), kind);
        expectFailure(await repo.setRuleEnabled('a', enabled: false), kind);
        expect(db.setKeys, isEmpty);
        expect(db.removedKeys, isEmpty);
        expect(db.rawValue(), raw);
        expectFailure(await open().$1.getRules(), kind);
      });
    }
  });

  group('33. a fresh repository instance reads saved data', () {
    test('every operation is visible after a simulated restart', () async {
      var (SmartRuleRepositoryImpl repo, _) = open();
      await repo.saveRule(_rule('a', targets: <String>['com.x.y', 'com.a.b']));
      (repo, _) = open();
      await repo.saveRule(_rule('b'));
      (repo, _) = open();
      await repo.setRuleEnabled('a', enabled: false);
      (repo, _) = open();
      await repo.deleteRule('b');
      expect(await readFresh(), <SmartRule>[
        _rule('a', targets: <String>['com.a.b', 'com.x.y'], enabled: false),
      ]);
    });
  });

  group('34. no native enforcement writes', () {
    test(
        'rule storage through the app container touches only its own key: '
        'no watcher, level, protected-set, grace or legacy-rule change',
        () async {
      final _SpyDb db = _SpyDb();
      final AppContainer c = AppContainer.inMemory(database: db);
      await c.protectedApps.add(
        ProtectedApp(
          packageName: 'com.example.bank',
          label: 'bank',
          addedAt: DateTime(2026, 11, 1),
          securityLevel: AppSecurityLevel.critical,
        ),
      );
      await c.lockSettings.setGracePeriod(const Duration(seconds: 30));
      final StaticWatcherService w = c.watcher as StaticWatcherService;
      final List<int> watcherBefore = _watcherCounters(w);
      final int policiesBefore = w.receivedPolicies.length;
      db.calls.clear();

      expect(
        (await c.smartRules.saveRule(
          _rule('a', targets: <String>['com.example.bank']),
        ))
            .isSuccess,
        isTrue,
      );
      await c.smartRules.setRuleEnabled('a', enabled: false);
      await c.smartRules.getRules();
      await c.smartRules.deleteRule('a');

      expect(
        db.calls.where((String call) => !call.startsWith('getSetting')),
        everyElement(anyOf('setSetting:$_key', 'removeSetting:$_key')),
      );
      expect(
          db.calls.where((String call) => call.startsWith('set')), isNotEmpty);
      expect(_watcherCounters(w), watcherBefore);
      expect(w.receivedPolicies.length, policiesBefore);
      expect(w.authorizedPackages, isEmpty);
      final List<ProtectedApp> apps =
          (await c.protectedApps.getProtectedApps()).valueOrNull!;
      expect(apps.single.securityLevel, AppSecurityLevel.critical);
      expect(
        (await c.lockSettings.getGracePeriod()).valueOrNull,
        const Duration(seconds: 30),
      );
      expect((await c.lockSettings.getRules()).valueOrNull, isEmpty);
    });
  });
}

List<int> _watcherCounters(StaticWatcherService w) => <int>[
      w.startCalls,
      w.stopCalls,
      w.configureCalls,
      w.setGracePeriodCalls,
      w.authorizePackageCalls,
      w.revokeAllAuthorizationsCalls,
    ];

/// Records every database call (name:key where relevant).
class _SpyDb extends InMemoryLocalDatabase {
  final List<String> calls = <String>[];

  @override
  Future<String?> getSetting(String key) {
    calls.add('getSetting:$key');
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) {
    calls.add('setSetting:$key');
    return super.setSetting(key, value);
  }

  @override
  Future<void> removeSetting(String key) {
    calls.add('removeSetting:$key');
    return super.removeSetting(key);
  }

  @override
  Future<void> saveProtectedApp(ProtectedApp app) {
    calls.add('saveProtectedApp');
    return super.saveProtectedApp(app);
  }

  @override
  Future<bool> updateProtectedAppSecurityLevel(
    String packageName,
    AppSecurityLevel level,
  ) {
    calls.add('updateLevel');
    return super.updateProtectedAppSecurityLevel(packageName, level);
  }

  @override
  Future<void> removeProtectedApp(String packageName) {
    calls.add('removeProtectedApp');
    return super.removeProtectedApp(packageName);
  }
}
