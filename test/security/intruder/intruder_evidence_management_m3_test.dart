// Phase 12 / M3 — evidence management (delete / clear-all / retention),
// resurrection guards, crash recovery, settings update() and the owner
// viewing session. SIMULATED: Dart VM, in-memory database, real AES-GCM
// cipher over an in-memory secret store (the Keystore is not exercised).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/security/credentials/verified_attempt.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/encryption/settings_cipher.dart';
import 'package:smart_app_lock/security/encryption/settings_cipher_impl.dart';
import 'package:smart_app_lock/security/intruder/failed_attempt_event.dart';
import 'package:smart_app_lock/security/intruder/intruder_defense_coordinator.dart';
import 'package:smart_app_lock/security/intruder/intruder_defense_settings.dart';
import 'package:smart_app_lock/security/intruder/intruder_evidence_service.dart';
import 'package:smart_app_lock/security/intruder/intruder_evidence_store.dart';
import 'package:smart_app_lock/security/intruder/intruder_owner_session.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';

import '../../support/intruder_fixtures.dart';

/// Fault-injecting database: fail (throw) on chosen keys/ops to model a
/// crash or I/O fault at an exact point of a write sequence.
class _FaultDb extends InMemoryLocalDatabase {
  bool failIndexWrite = false;
  bool failBlobRemove = false;
  bool failReads = false;
  final List<String> ops = <String>[];

  @override
  Future<String?> getSetting(String key) async {
    if (failReads) throw StateError('read fault');
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) async {
    if (failIndexWrite && key == IntruderEvidenceStore.indexKey) {
      throw StateError('disk full');
    }
    ops.add('set:$key');
    return super.setSetting(key, value);
  }

  @override
  Future<void> removeSetting(String key) async {
    if (failBlobRemove && key.startsWith(IntruderEvidenceStore.blobPrefix)) {
      throw StateError('crash during blob removal');
    }
    ops.add('remove:$key');
    return super.removeSetting(key);
  }
}

FailedAttemptEvent ev(int seq, int run) => FailedAttemptEvent(
      seq: seq,
      verificationId: 'p:$seq',
      at: DateTime(2026, 10, 22),
      method: FailedAttemptMethod.pin,
      surface: AuthAttemptSurface.protectedAppChallenge,
      consecutiveFailures: run,
      lockoutTriggered: false,
      lockoutStreak: 0,
      counterPersisted: true,
      packageName: 'com.bank',
    );

void main() {
  late _FaultDb db;
  late SettingsCipher cipher;
  late DateTime now;

  setUp(() {
    db = _FaultDb();
    cipher = AesGcmSettingsCipher(InMemorySecretStore());
    now = DateTime(2026, 10, 22, 12);
  });

  IntruderEvidenceStore store() =>
      IntruderEvidenceStore(db, cipher, now: () => now);

  Future<void> seed(IntruderEvidenceStore s, List<int> seqs) async {
    for (final int q in seqs) {
      expect(await s.save(seq: q, jpeg: jpegWithMetadata()),
          EvidenceSaveResult.saved);
    }
  }

  Future<Set<String>> blobs() async => (await db.getAllSettings())
      .keys
      .where((String k) => k.startsWith(IntruderEvidenceStore.blobPrefix))
      .toSet();

  Future<Map<String, Object?>> rawIndex() async {
    final String raw = (await db.getSetting(IntruderEvidenceStore.indexKey))!;
    return jsonDecode(
            await cipher.decryptString(raw.substring('enc:v1:'.length)))
        as Map<String, Object?>;
  }

  group('delete one', () {
    test('removes the item and its blob, keeps the others, is idempotent',
        () async {
      final IntruderEvidenceStore s = store();
      await seed(s, <int>[1, 2, 3]);
      expect(await s.delete(2), EvidenceDeleteResult.deleted);
      expect((await s.list()).map((EvidenceItem e) => e.seq), <int>[1, 3]);
      expect(await blobs(), <String>{
        IntruderEvidenceStore.blobKey(1),
        IntruderEvidenceStore.blobKey(3),
      });
      expect(await s.readImage(2), isNull);
      expect(await s.readImage(1), isNotNull);
      expect(await s.delete(2), EvidenceDeleteResult.notFound,
          reason: 'duplicate delete is a no-op');
      expect((await s.list()).length, 2);
    });

    test('index rewrite (with tombstone) commits BEFORE the blob removal',
        () async {
      final IntruderEvidenceStore s = store();
      await seed(s, <int>[7]);
      db.ops.clear();
      await s.delete(7);
      expect(db.ops, <String>[
        'set:${IntruderEvidenceStore.indexKey}',
        'remove:${IntruderEvidenceStore.blobKey(7)}',
      ]);
      expect((await rawIndex())['tomb'], <int>[7]);
    });

    test('a late save for a deleted seq is refused (no resurrection)',
        () async {
      final IntruderEvidenceStore s = store();
      await seed(s, <int>[5]);
      await s.delete(5);
      expect(await s.save(seq: 5, jpeg: jpegWithMetadata()),
          EvidenceSaveResult.superseded);
      expect(await s.list(), isEmpty);
      expect(await blobs(), isEmpty);
      // A NEW event's evidence is still accepted.
      expect(await s.save(seq: 6, jpeg: jpegWithMetadata()),
          EvidenceSaveResult.saved);
    });

    test('stillValid=false at the commit point changes nothing', () async {
      final IntruderEvidenceStore s = store();
      await seed(s, <int>[1]);
      expect(await s.delete(1, stillValid: () => false),
          EvidenceDeleteResult.cancelled);
      expect((await s.list()).single.seq, 1);
      expect(await s.readImage(1), isNotNull);
    });

    test('index write failure: nothing deleted, failure reported', () async {
      final IntruderEvidenceStore s = store();
      await seed(s, <int>[1]);
      db.failIndexWrite = true;
      expect(await s.delete(1), EvidenceDeleteResult.storageFailed);
      db.failIndexWrite = false;
      expect((await s.list()).single.seq, 1);
      expect(await s.readImage(1), isNotNull);
    });

    test(
        'crash after the index commit (blob removal fails): the item is gone, '
        'never readable, and a fresh store sweeps the orphan', () async {
      final IntruderEvidenceStore s = store();
      await seed(s, <int>[1, 2]);
      db.failBlobRemove = true;
      expect(await s.delete(1), EvidenceDeleteResult.deleted);
      expect(await blobs(), contains(IntruderEvidenceStore.blobKey(1)),
          reason: 'orphan ciphertext row left by the simulated crash');
      expect(await s.readImage(1), isNull,
          reason: 'unlisted rows are never readable');
      db.failBlobRemove = false;
      final IntruderEvidenceStore restarted = store(); // process restart
      expect(await restarted.sweepOrphans(), 1);
      expect(await blobs(), <String>{IntruderEvidenceStore.blobKey(2)});
      expect(await restarted.save(seq: 1, jpeg: jpegWithMetadata()),
          EvidenceSaveResult.superseded,
          reason: 'tombstone survives the restart');
    });

    test('tombstones are bounded; overflow folds them into the high-water mark',
        () async {
      final IntruderEvidenceStore s = IntruderEvidenceStore(db, cipher,
          now: () => now, maxItems: 100, maxTotalBytes: 1 << 30);
      final int n = IntruderEvidenceStore.maxTombstones + 5;
      for (int q = 0; q < n; q++) {
        await seed(s, <int>[q]);
        await s.delete(q);
      }
      final Map<String, Object?> idx = await rawIndex();
      // 65th delete folds all 65 tombstones into hw = 64; 4 more follow.
      expect(idx['hw'], IntruderEvidenceStore.maxTombstones);
      expect(idx['tomb'], <int>[65, 66, 67, 68]);
      expect(idx.containsKey('floor'), isFalse,
          reason: 'compaction no longer raises the clear-all floor');
      for (int q = 0; q < n; q++) {
        expect(await s.save(seq: q, jpeg: jpegWithMetadata()),
            EvidenceSaveResult.superseded,
            reason: 'seq $q must stay retired');
      }
    });
  });

  group('clear all', () {
    test('empties the index and blobs and records the floor', () async {
      final IntruderEvidenceStore s = store();
      await seed(s, <int>[3, 4, 9]);
      expect(await s.clearAll(floorSeq: 12), EvidenceClearResult.cleared);
      expect(await s.list(), isEmpty);
      expect(await blobs(), isEmpty);
      expect((await rawIndex())['floor'], 12);
      for (final int q in <int>[3, 9, 10, 12]) {
        expect(await s.save(seq: q, jpeg: jpegWithMetadata()),
            EvidenceSaveResult.superseded);
      }
      expect(await s.save(seq: 13, jpeg: jpegWithMetadata()),
          EvidenceSaveResult.saved);
    });

    test('floor is never lowered and covers listed seqs above floorSeq',
        () async {
      final IntruderEvidenceStore s = store();
      await seed(s, <int>[20]);
      await s.clearAll(floorSeq: 5);
      expect((await rawIndex())['floor'], 20);
      await s.clearAll(floorSeq: 1);
      expect((await rawIndex())['floor'], 20);
    });

    test('index write failure: everything kept and reported', () async {
      final IntruderEvidenceStore s = store();
      await seed(s, <int>[1, 2]);
      db.failIndexWrite = true;
      expect(await s.clearAll(), EvidenceClearResult.storageFailed);
      db.failIndexWrite = false;
      expect((await s.list()).length, 2);
    });

    test('crash during blob removal: nothing listed; restart sweeps', () async {
      final IntruderEvidenceStore s = store();
      await seed(s, <int>[1, 2]);
      db.failBlobRemove = true;
      expect(await s.clearAll(), EvidenceClearResult.cleared);
      expect(await s.list(), isEmpty);
      expect(await s.readImage(1), isNull);
      db.failBlobRemove = false;
      expect(await store().sweepOrphans(), 2);
      expect(await blobs(), isEmpty);
    });

    test('stillValid=false: nothing cleared', () async {
      final IntruderEvidenceStore s = store();
      await seed(s, <int>[1]);
      expect(await s.clearAll(stillValid: () => false),
          EvidenceClearResult.cancelled);
      expect((await s.list()).length, 1);
    });
  });

  group('schema / corruption safety', () {
    Future<void> writeRawIndex(Map<String, Object?> m) async => db.setSetting(
        IntruderEvidenceStore.indexKey,
        'enc:v1:${await cipher.encryptString(jsonEncode(m))}');

    test('newer-schema index: delete and clear are refused, never overwritten',
        () async {
      await writeRawIndex(<String, Object?>{'v': 2, 'items': <Object?>[]});
      final String before =
          (await db.getSetting(IntruderEvidenceStore.indexKey))!;
      final IntruderEvidenceStore s = store();
      expect(await s.delete(1), EvidenceDeleteResult.unsupportedSchema);
      expect(await s.clearAll(), EvidenceClearResult.unsupportedSchema);
      expect(await s.enforceRetention(), 0);
      expect(await db.getSetting(IntruderEvidenceStore.indexKey), before);
      expect((await s.summary()).health, EvidenceIndexHealth.unsupported);
    });

    test('unreadable database: delete/clear report storageFailed', () async {
      final IntruderEvidenceStore s = store();
      await seed(s, <int>[1]);
      db.failReads = true;
      expect(await s.delete(1), EvidenceDeleteResult.storageFailed);
      expect(await s.clearAll(), EvidenceClearResult.storageFailed);
      db.failReads = false;
      expect((await s.list()).length, 1);
    });

    for (final (String name, Map<String, Object?> idx)
        in <(String, Map<String, Object?>)>[
      (
        'bad floor type',
        <String, Object?>{'v': 1, 'items': <Object?>[], 'floor': 'x'}
      ),
      (
        'negative tomb',
        <String, Object?>{
          'v': 1,
          'items': <Object?>[],
          'tomb': <int>[-3]
        }
      ),
      (
        'listed item at/below floor',
        <String, Object?>{
          'v': 1,
          'floor': 9,
          'items': <Object?>[
            <String, Object?>{'seq': 4, 'at': 0, 'bytes': 10, 'pkg': null}
          ],
        }
      ),
    ]) {
      test('corrupt guard fields ($name) are quarantined, not trusted',
          () async {
        await writeRawIndex(idx);
        final IntruderEvidenceStore s = store();
        expect(await s.list(), isEmpty);
        expect(await db.getSetting(IntruderEvidenceStore.quarantineKey),
            isNotNull);
      });
    }

    test('an M2-written index (no guard fields) still reads and saves',
        () async {
      await writeRawIndex(<String, Object?>{
        'v': 1,
        'items': <Object?>[
          <String, Object?>{
            'seq': 2,
            'at': now.millisecondsSinceEpoch,
            'bytes': 10,
            'pkg': 'a'
          }
        ],
      });
      final IntruderEvidenceStore s = store();
      expect((await s.list()).single.seq, 2);
      expect(await s.save(seq: 3, jpeg: jpegWithMetadata()),
          EvidenceSaveResult.saved);
    });
  });

  group('retention', () {
    test('enforceRetention removes expired items (index then blobs) only',
        () async {
      final IntruderEvidenceStore s = store();
      await seed(s, <int>[1]);
      now = now.add(const Duration(days: 20));
      await seed(s, <int>[2]);
      now = now.add(const Duration(days: 11)); // item 1 is 31 days old
      db.ops.clear();
      expect(await s.enforceRetention(), 1);
      expect(db.ops.first, 'set:${IntruderEvidenceStore.indexKey}');
      expect((await s.list()).single.seq, 2);
      expect(await blobs(), <String>{IntruderEvidenceStore.blobKey(2)});
      expect(await s.readImage(1), isNull);
      expect(await s.enforceRetention(), 0);
    });

    test('summary reports count/bytes without reading any image', () async {
      final IntruderEvidenceStore s = store();
      await seed(s, <int>[1, 2]);
      db.ops.clear();
      final EvidenceSummary sum = await s.summary();
      expect(sum.count, 2);
      expect(sum.totalBytes, greaterThan(0));
      expect(sum.health, EvidenceIndexHealth.ok);
      expect(db.ops, isEmpty);
    });
  });

  group('concurrency (serialized store)', () {
    test('delete racing a save of the same seq never leaves it stored',
        () async {
      final IntruderEvidenceStore s = store();
      await seed(s, <int>[1]);
      // Owner deletes 1 and, concurrently, a duplicate late save arrives.
      final Future<EvidenceDeleteResult> d = s.delete(1);
      final Future<EvidenceSaveResult> sv =
          s.save(seq: 1, jpeg: jpegWithMetadata());
      expect(await d, EvidenceDeleteResult.deleted);
      expect(await sv, EvidenceSaveResult.superseded);
      expect(await s.list(), isEmpty);
      expect(await blobs(), isEmpty);
    });

    test('duplicate concurrent deletes: one deletes, one notFound', () async {
      final IntruderEvidenceStore s = store();
      await seed(s, <int>[1]);
      final List<EvidenceDeleteResult> r = await Future.wait(
          <Future<EvidenceDeleteResult>>[s.delete(1), s.delete(1)]);
      expect(r, <EvidenceDeleteResult>[
        EvidenceDeleteResult.deleted,
        EvidenceDeleteResult.notFound,
      ]);
    });

    test('retention sweep racing a read: the read sees null, never stale bytes',
        () async {
      final IntruderEvidenceStore s = store();
      await seed(s, <int>[1]);
      now = now.add(const Duration(days: 31));
      final Future<int> sweep = s.enforceRetention();
      final Future<Uint8List?> read = s.readImage(1);
      expect(await sweep, 1);
      expect(await read, isNull);
    });
  });

  group('coordinator: clear-all vs in-flight capture', () {
    late IntruderDefenseSettingsStore settings;
    late IntruderEvidenceStore evidence;
    late GatedEvidenceService platform;
    late IntruderDefenseCoordinator coordinator;

    setUp(() async {
      settings = IntruderDefenseSettingsStore(db, cipher);
      evidence = store();
      platform = GatedEvidenceService()
        ..permission = CameraPermissionState.granted;
      coordinator = IntruderDefenseCoordinator(
          settings: settings, evidence: evidence, service: platform);
      await settings.write(
          const IntruderDefenseSettings(evidenceEnabled: true, threshold: 1));
    });

    test(
        'a capture that completes AFTER clear-all is never saved (epoch + '
        'floor), and the platform was told to abort', () async {
      platform.gate = Completer<CaptureResult>();
      coordinator.onFailedAttemptRecorded(ev(41, 1));
      await pumpEventQueue();
      expect(platform.captures, 1);
      expect(coordinator.highestHandledSeq, 41);

      coordinator.onEvidenceCleared();
      expect(platform.ops, contains('abort'));
      expect(await evidence.clearAll(floorSeq: coordinator.highestHandledSeq),
          EvidenceClearResult.cleared);

      platform.gate!.complete(CaptureSucceeded(jpegWithMetadata()));
      await coordinator.idle();
      expect(await evidence.list(), isEmpty);
      expect(await blobs(), isEmpty);
      expect(coordinator.status.captureCancelled, 1);
      expect(coordinator.status.captured, 0);
    });

    test('floor alone blocks a save of an earlier event (defence in depth)',
        () async {
      await evidence.clearAll(floorSeq: 50);
      coordinator.onFailedAttemptRecorded(ev(50, 1));
      await coordinator.idle();
      expect(await evidence.list(), isEmpty);
      expect(coordinator.status.captureCancelled, 1,
          reason: 'superseded is counted as cancelled, not a save failure');
      expect(coordinator.status.saveFailed, 0);
    });

    test('evidence for a NEW failure after the clear is captured normally',
        () async {
      coordinator.onFailedAttemptRecorded(ev(1, 1));
      await coordinator.idle();
      coordinator.onEvidenceCleared();
      await evidence.clearAll(floorSeq: coordinator.highestHandledSeq);
      coordinator.onFailedAttemptRecorded(ev(2, 1));
      await coordinator.idle();
      expect((await evidence.list()).single.seq, 2);
    });

    test('onEvidenceCleared never touches the alarm', () async {
      coordinator.onEvidenceCleared();
      await coordinator.idle();
      expect(platform.ops.where((String o) => o.startsWith('alarm')), isEmpty);
    });

    test(
        'threshold change mid-run applies to the next event; lowering below '
        'the run never fires an extra capture', () async {
      await settings
          .update((IntruderDefenseSettings s) => s.copyWith(threshold: 3));
      coordinator.onFailedAttemptRecorded(ev(1, 1));
      coordinator.onFailedAttemptRecorded(ev(2, 2));
      await coordinator.idle();
      await settings
          .update((IntruderDefenseSettings s) => s.copyWith(threshold: 2));
      coordinator.onFailedAttemptRecorded(ev(3, 3));
      await coordinator.idle();
      expect(platform.captures, 0, reason: '3 != 2: lowered below the run');
      coordinator.onFailedAttemptRecorded(ev(4, 1));
      coordinator.onFailedAttemptRecorded(ev(5, 2));
      await coordinator.idle();
      expect(platform.captures, 1);
      expect((await evidence.list()).single.seq, 5);
    });
  });

  group('settings update()', () {
    test('serialized: concurrent updates never lose a change', () async {
      final IntruderDefenseSettingsStore s =
          IntruderDefenseSettingsStore(db, cipher);
      await Future.wait(<Future<Object?>>[
        s.update(
            (IntruderDefenseSettings c) => c.copyWith(evidenceEnabled: true)),
        s.update((IntruderDefenseSettings c) => c.copyWith(alarmEnabled: true)),
        s.update((IntruderDefenseSettings c) => c.copyWith(threshold: 7)),
      ]);
      expect(
          (await s.read()).settings,
          const IntruderDefenseSettings(
              evidenceEnabled: true, alarmEnabled: true, threshold: 7));
    });

    test('out-of-range threshold is refused (update and write)', () async {
      final IntruderDefenseSettingsStore s =
          IntruderDefenseSettingsStore(db, cipher);
      expect(
          await s
              .update((IntruderDefenseSettings c) => c.copyWith(threshold: 11)),
          isNull);
      expect(
          await s
              .update((IntruderDefenseSettings c) => c.copyWith(threshold: 0)),
          isNull);
      expect(
          await s.write(const IntruderDefenseSettings(threshold: 0)), isFalse);
      expect((await s.read()).health, IntruderSettingsHealth.missing);
    });

    test('corrupt / newer record is never overwritten by update()', () async {
      final IntruderDefenseSettingsStore s =
          IntruderDefenseSettingsStore(db, cipher);
      await db.setSetting(
          IntruderDefenseSettingsStore.storageKey,
          'enc:v1:${await cipher.encryptString(jsonEncode(<String, Object?>{
                'v': 2
              }))}');
      final String? before =
          await db.getSetting(IntruderDefenseSettingsStore.storageKey);
      expect(
          await s
              .update((IntruderDefenseSettings c) => c.copyWith(threshold: 5)),
          isNull);
      expect(
          await db.getSetting(IntruderDefenseSettingsStore.storageKey), before);
    });
  });

  group('owner session', () {
    late DateTime t;
    late IntruderOwnerSessionGate gate;

    setUp(() {
      t = DateTime(2026, 10, 22, 12);
      gate = IntruderOwnerSessionGate(now: () => t);
    });

    test('valid until maxAge (absolute, never extended)', () {
      final IntruderOwnerSession s = gate.begin(AuthType.pin);
      expect(s.isValid, isTrue);
      t = t.add(IntruderOwnerSessionGate.defaultMaxAge -
          const Duration(milliseconds: 1));
      expect(s.isValid, isTrue);
      t = t.add(const Duration(milliseconds: 1));
      expect(s.isValid, isFalse);
      expect(s.invalidationReason, 'expired');
      t = t.subtract(const Duration(minutes: 1));
      expect(s.isValid, isFalse, reason: 'never revived');
    });

    test('a backwards clock invalidates (fail closed)', () {
      final IntruderOwnerSession s = gate.begin(AuthType.pin);
      t = t.subtract(const Duration(seconds: 1));
      expect(s.isValid, isFalse);
    });

    test('begin() replaces and invalidates the previous session', () {
      final IntruderOwnerSession a = gate.begin(AuthType.pin);
      final IntruderOwnerSession b = gate.begin(AuthType.pattern);
      expect(a.isValid, isFalse);
      expect(a.invalidationReason, 'replaced');
      expect(b.isValid, isTrue);
      expect(b.id, greaterThan(a.id));
      expect(gate.current, same(b));
    });

    test('invalidateAll + listeners run once; listener errors are contained',
        () {
      final IntruderOwnerSession s = gate.begin(AuthType.pin);
      final List<String> seen = <String>[];
      s.addListener((String r) => throw StateError('bad listener'));
      s.addListener(seen.add);
      gate.invalidateAll('screenOff');
      s.invalidate('again');
      expect(seen, <String>['screenOff']);
      expect(s.isValid, isFalse);
      expect(gate.current, isNull);
    });
  });
}
