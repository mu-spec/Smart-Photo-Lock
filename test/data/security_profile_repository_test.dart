// Phase 11 / M1: Security Profile persistence safety. SIMULATED storage
// (in-memory LocalDatabase with injected faults); no device.

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/repositories/impl/security_profile_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/security_profile_repository.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/profiles/security_profile.dart';
import 'package:smart_app_lock/profiles/security_profile_document.dart';
import 'package:smart_app_lock/utilities/result.dart';

const String _key = SecurityProfileRepositoryImpl.storageKey;

class _Db extends InMemoryLocalDatabase {
  final List<String> calls = <String>[];
  Object? readError;
  int failNextWrites = 0;
  bool dropWrites = false;
  bool failRemove = false;

  @override
  Future<String?> getSetting(String key) async {
    calls.add('get:$key');
    if (readError != null) throw readError!;
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) async {
    calls.add('set:$key');
    if (failNextWrites > 0) {
      failNextWrites--;
      throw StateError('disk full');
    }
    if (dropWrites) return;
    return super.setSetting(key, value);
  }

  @override
  Future<void> removeSetting(String key) async {
    calls.add('remove:$key');
    if (failRemove) throw StateError('remove failed');
    return super.removeSetting(key);
  }

  Future<String?> raw() => super.getSetting(_key);
  List<String> get writes =>
      calls.where((String c) => !c.startsWith('get:')).toList();
}

SecurityProfileSet _kidsActive() => SecurityProfileSet(
      profiles: <SecurityProfile>[
        for (final SecurityProfileKind k in SecurityProfileKind.values)
          k == SecurityProfileKind.kids
              ? SecurityProfile(
                  kind: k,
                  appLevels: const <String, AppSecurityLevel>{
                    'com.example.notes': AppSecurityLevel.critical,
                  },
                )
              : SecurityProfile.preset(k),
      ],
      activeProfileId: 'kids',
    );

SecurityProfileStoreErrorKind? _kind(Result<Object?> r) =>
    (r.errorOrNull as SecurityProfileStoreException?)?.kind;

void main() {
  late _Db db;
  late SecurityProfileRepositoryImpl repo;

  setUp(() {
    db = _Db();
    repo = SecurityProfileRepositoryImpl(db);
  });

  test('nothing saved → defaults (Normal active); reading never writes',
      () async {
    final Result<SecurityProfileSet> r = await repo.getProfiles();
    expect(r.valueOrNull, SecurityProfileSet.defaults());
    expect(r.valueOrNull!.active.kind, SecurityProfileKind.normal);
    expect(db.writes, isEmpty);
    expect(await db.raw(), isNull);
  });

  test('save is confirmed by reading back, then read returns it', () async {
    final Result<void> saved = await repo.saveProfiles(
      _kidsActive(),
      expected: SecurityProfileSet.defaults(),
    );
    expect(saved.isSuccess, isTrue);
    expect(await db.raw(), SecurityProfileDocument.encode(_kidsActive()));
    expect((await repo.getProfiles()).valueOrNull, _kidsActive());
    expect(db.calls.where((String c) => c == 'get:$_key').length,
        greaterThanOrEqualTo(2)); // load + read-back
  });

  test('compare-and-swap: a stale expected value writes nothing', () async {
    await repo.saveProfiles(_kidsActive(),
        expected: SecurityProfileSet.defaults());
    db.calls.clear();
    final Result<void> r = await repo.saveProfiles(
      SecurityProfileSet.defaults(),
      expected: SecurityProfileSet.defaults(), // stale: stored is Kids
    );
    expect(_kind(r), SecurityProfileStoreErrorKind.conflict);
    expect(db.writes, isEmpty);
    expect((await repo.getProfiles()).valueOrNull, _kidsActive());
  });

  test('saving an identical stored value writes nothing', () async {
    await repo.saveProfiles(_kidsActive(),
        expected: SecurityProfileSet.defaults());
    db.calls.clear();
    final Result<void> r =
        await repo.saveProfiles(_kidsActive(), expected: _kidsActive());
    expect(r.isSuccess, isTrue);
    expect(db.writes, isEmpty);
  });

  test('corrupt stored value: read fails, write refused, value untouched',
      () async {
    await db.setSetting(_key, '{"version":1,"broken":true}');
    db.calls.clear();
    expect(
        _kind(await repo.getProfiles()), SecurityProfileStoreErrorKind.corrupt);
    final Result<void> r = await repo.saveProfiles(
      SecurityProfileSet.defaults(),
      expected: SecurityProfileSet.defaults(),
    );
    expect(_kind(r), SecurityProfileStoreErrorKind.corrupt);
    expect(db.writes, isEmpty);
    expect(await db.raw(), '{"version":1,"broken":true}');
  });

  test('newer version: unsupported, write refused, value untouched', () async {
    const String newer =
        '{"version":2,"activeProfileId":"normal","profiles":[]}';
    await db.setSetting(_key, newer);
    db.calls.clear();
    expect(_kind(await repo.getProfiles()),
        SecurityProfileStoreErrorKind.unsupportedVersion);
    expect(
      _kind(await repo.saveProfiles(SecurityProfileSet.defaults(),
          expected: SecurityProfileSet.defaults())),
      SecurityProfileStoreErrorKind.unsupportedVersion,
    );
    expect(db.writes, isEmpty);
    expect(await db.raw(), newer);
  });

  test('storage read error → storageUnavailable (never defaults)', () async {
    db.readError = StateError('locked');
    expect(_kind(await repo.getProfiles()),
        SecurityProfileStoreErrorKind.storageUnavailable);
  });

  test('failed write → writeFailed; key removed when nothing was saved',
      () async {
    db.failNextWrites = 1;
    final Result<void> r = await repo.saveProfiles(_kidsActive(),
        expected: SecurityProfileSet.defaults());
    expect(_kind(r), SecurityProfileStoreErrorKind.writeFailed);
    expect(await db.raw(), isNull);
    expect(db.writes, contains('remove:$_key'));
    expect(
        (await repo.getProfiles()).valueOrNull, SecurityProfileSet.defaults());
  });

  test('failed write → previous value restored', () async {
    await repo.saveProfiles(_kidsActive(),
        expected: SecurityProfileSet.defaults());
    final String? before = await db.raw();
    db.failNextWrites = 1;
    final Result<void> r = await repo.saveProfiles(
      SecurityProfileSet.defaults(),
      expected: _kidsActive(),
    );
    expect(_kind(r), SecurityProfileStoreErrorKind.writeFailed);
    expect(await db.raw(), before);
  });

  test('unconfirmed write (store keeps nothing) is never reported as saved',
      () async {
    db.dropWrites = true;
    final Result<void> r = await repo.saveProfiles(_kidsActive(),
        expected: SecurityProfileSet.defaults());
    expect(r.isFailure, isTrue);
    expect(_kind(r), SecurityProfileStoreErrorKind.writeFailed);
  });

  test('a failing restore still reports the original write failure', () async {
    db
      ..failNextWrites = 1
      ..failRemove = true;
    final Result<void> r = await repo.saveProfiles(_kidsActive(),
        expected: SecurityProfileSet.defaults());
    expect(_kind(r), SecurityProfileStoreErrorKind.writeFailed);
    expect((r.errorOrNull! as SecurityProfileStoreException).cause,
        isA<StateError>());
  });

  test('operations are serialized: the second concurrent save conflicts',
      () async {
    final Future<Result<void>> a = repo.saveProfiles(_kidsActive(),
        expected: SecurityProfileSet.defaults());
    final Future<Result<void>> b = repo.saveProfiles(
      SecurityProfileSet(
        profiles: SecurityProfileSet.defaults().profiles,
        activeProfileId: 'guest',
      ),
      expected: SecurityProfileSet.defaults(),
    );
    expect((await a).isSuccess, isTrue);
    expect(_kind(await b), SecurityProfileStoreErrorKind.conflict);
    expect((await repo.getProfiles()).valueOrNull, _kidsActive());
  });

  test('only its own key is touched; the legacy profiles table is not',
      () async {
    await repo.getProfiles();
    await repo.saveProfiles(_kidsActive(),
        expected: SecurityProfileSet.defaults());
    expect(
      db.calls,
      everyElement(anyOf('get:$_key', 'set:$_key', 'remove:$_key')),
    );
    expect(await db.getProfiles(), isEmpty); // legacy LockProfile table
    expect(_key, isNot('profiles'));
  });
}
