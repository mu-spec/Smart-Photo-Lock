// Phase 12 / M3 commit-readiness gate: R-M3-6 tombstone compaction.
//
// Abstract index state S = (L listed seqs, F floor, T tombstones, H hw).
//   Retired(S)   R = {s <= F} ∪ T ∪ ({s <= H} \ L)
//   I1 validity  ∀ l ∈ L: l > F ∧ l ∉ T          (H unconstrained)
//   I2 safety    D ⊆ R and D ∩ L = ∅  (D = every seq the owner deleted or
//                cleared, committed)
//   I3 bound     |T| <= maxTombstones
// Compaction (|T| > max): H' = max(H, max T), T' = ∅, L and F unchanged.
//   Every t ∈ T is not listed (I1), so t <= H' and t ∉ L, i.e. t ∈ R':
//   R' ⊇ R. L untouched, F unchanged, so I1 holds; T' = ∅ gives I3.
// The pre-fix compaction dropped the oldest tombstone d and raised F only
// when no listed item was <= d: with a listed l < d, d left R (violating
// I2). The first test below is that counterexample (it FAILED before the
// fix: the deleted seq was saved again and listed).
//
// SIMULATED: Dart VM, in-memory database, real AES-GCM cipher. Each index
// commit is one setSetting (a single-row INSERT OR REPLACE in production).

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/security/encryption/settings_cipher.dart';
import 'package:smart_app_lock/security/encryption/settings_cipher_impl.dart';
import 'package:smart_app_lock/security/intruder/intruder_evidence_store.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';

import '../../support/intruder_fixtures.dart';

class _FaultDb extends InMemoryLocalDatabase {
  bool failIndexWrite = false;
  bool failBlobRemove = false;

  @override
  Future<void> setSetting(String key, String value) async {
    if (failIndexWrite && key == IntruderEvidenceStore.indexKey) {
      throw StateError('crash before the index commit');
    }
    return super.setSetting(key, value);
  }

  @override
  Future<void> removeSetting(String key) async {
    if (failBlobRemove && key.startsWith(IntruderEvidenceStore.blobPrefix)) {
      throw StateError('crash after the index commit');
    }
    return super.removeSetting(key);
  }
}

/// Per-seq distinct, byte-checkable image (scan data survives stripping).
Uint8List jpegFor(int seq) =>
    jpegWithMetadata(padding: 8 + seq % 97, fill: 1 + seq % 250);
Uint8List cleanFor(int seq) => JpegSanitizer.strip(jpegFor(seq))!;

void main() {
  late _FaultDb db;
  late SettingsCipher cipher;
  late DateTime now;

  setUp(() {
    db = _FaultDb();
    cipher = AesGcmSettingsCipher(InMemorySecretStore());
    now = DateTime(2026, 10, 22, 12);
  });

  /// A new instance over the same database and key = process restart.
  IntruderEvidenceStore open({int maxItems = 100}) =>
      IntruderEvidenceStore(db, cipher,
          now: () => now, maxItems: maxItems, maxTotalBytes: 1 << 30);

  Future<Map<String, Object?>> rawIndex() async {
    final String? raw = await db.getSetting(IntruderEvidenceStore.indexKey);
    if (raw == null) return <String, Object?>{};
    return jsonDecode(
            await cipher.decryptString(raw.substring('enc:v1:'.length)))
        as Map<String, Object?>;
  }

  Future<void> save(IntruderEvidenceStore s, int seq) async => expect(
      await s.save(seq: seq, jpeg: jpegFor(seq)), EvidenceSaveResult.saved,
      reason: 'save $seq');

  Future<void> saveDelete(IntruderEvidenceStore s, int seq) async {
    await save(s, seq);
    expect(await s.delete(seq), EvidenceDeleteResult.deleted,
        reason: 'delete $seq');
  }

  /// I1/I3 + liveness of every listed item (byte-exact) + I2 probes.
  Future<void> checkAll(IntruderEvidenceStore s,
      {required Iterable<int> live, required Iterable<int> deleted}) async {
    expect(await s.health(), EvidenceIndexHealth.ok);
    expect(await db.getSetting(IntruderEvidenceStore.quarantineKey), isNull,
        reason: 'compaction must never make the index look corrupt');
    final List<int> listed =
        (await s.list()).map((EvidenceItem e) => e.seq).toList();
    expect(listed, (live.toList()..sort()));
    for (final int l in live) {
      expect(await s.readImage(l), cleanFor(l),
          reason: 'listed $l must stay readable with its own bytes');
    }
    final Map<String, Object?> idx = await rawIndex();
    final List<int> tombs =
        ((idx['tomb'] as List?) ?? const <Object?>[]).cast<int>().toList();
    expect(
        tombs.length, lessThanOrEqualTo(IntruderEvidenceStore.maxTombstones));
    final int floor = (idx['floor'] as int?) ?? -1;
    for (final int l in live) {
      expect(l > floor && !tombs.contains(l), isTrue, reason: 'I1 for $l');
    }
    for (final int d in deleted) {
      expect(await s.readImage(d), isNull, reason: 'deleted $d readable');
      expect(
          await s.save(seq: d, jpeg: jpegFor(d)), EvidenceSaveResult.superseded,
          reason: 'deleted seq $d was resurrected');
    }
  }

  group('R-M3-6 counterexample (failed before the fix)', () {
    test(
        'old live item + 65 deletions: no deleted seq can be saved again; '
        'the old item stays listed and byte-exact', () async {
      final IntruderEvidenceStore s =
          IntruderEvidenceStore(db, cipher, now: () => now); // defaults
      await save(s, 1);
      final List<int> deleted = <int>[];
      for (int q = 2; q <= 66; q++) {
        await saveDelete(s, q);
        deleted.add(q);
      }
      expect((await rawIndex())['hw'], 66, reason: 'compaction happened');
      await checkAll(s, live: <int>[1], deleted: deleted);
    });
  });

  group('adversarial sequences (> 64 deletions, non-consecutive)', () {
    test(
        '200 non-consecutive deletions interleaved around 4 old live items '
        '(3 compactions); then delete a live item below hw; then clear-all',
        () async {
      IntruderEvidenceStore s = open();
      final List<int> live = <int>[3, 50, 51, 400];
      for (final int l in live) {
        await save(s, l);
      }
      // Irregular gaps, below/between/above the (older-saved) live items;
      // saved after 400, so seqs 52..399 are out of order w.r.t. a live item.
      final List<int> order = <int>[];
      for (int q = 4, i = 0; order.length < 200; q += 1 + (i * 7) % 5, i++) {
        if (!live.contains(q)) order.add(q);
      }
      expect(order.where((int q) => q < 50).isNotEmpty, isTrue);
      expect(order.where((int q) => q > 51 && q < 400).isNotEmpty, isTrue);
      expect(order.last, greaterThan(400));
      expect(
          order.length, greaterThan(3 * IntruderEvidenceStore.maxTombstones));
      final List<int> deleted = <int>[];
      int compactions = 0;
      for (final int q in order) {
        final int before = ((await rawIndex())['hw'] as int?) ?? -1;
        await saveDelete(s, q);
        deleted.add(q);
        final int after = ((await rawIndex())['hw'] as int?) ?? -1;
        if (after != before) compactions++;
        if (deleted.length % 64 == 1) {
          s = open(); // restart right after each compaction boundary
          await s.startupMaintenance();
          await checkAll(s, live: live, deleted: deleted);
        }
      }
      expect(compactions, greaterThanOrEqualTo(3));
      await checkAll(s, live: live, deleted: deleted);
      // A live item below hw deleted later stays retired.
      final int hw = (await rawIndex())['hw']! as int;
      expect(50 < hw, isTrue);
      expect(await s.delete(50), EvidenceDeleteResult.deleted);
      live.remove(50);
      deleted.add(50);
      await checkAll(s, live: live, deleted: deleted);
      // Clear-all subsumes hw: floor >= every retired seq; fresh seqs work.
      expect(await s.clearAll(), EvidenceClearResult.cleared);
      final Map<String, Object?> idx = await rawIndex();
      expect(idx.containsKey('hw'), isFalse);
      expect(idx.containsKey('tomb'), isFalse);
      expect(idx['floor']! as int, greaterThanOrEqualTo(hw));
      deleted.addAll(live);
      await checkAll(s, live: const <int>[], deleted: deleted);
      await save(s, (idx['floor']! as int) + 1);
    });

    test(
        'clear-all after a compaction with every live item BELOW hw still '
        'covers hw (no window between the highest live seq and hw)', () async {
      final IntruderEvidenceStore s = open();
      await save(s, 3);
      for (int q = 4; q <= 68; q++) {
        await saveDelete(s, q);
      }
      final Map<String, Object?> before = await rawIndex();
      expect(before['hw'], 68);
      expect(before.containsKey('tomb'), isFalse);
      expect(await s.clearAll(), EvidenceClearResult.cleared);
      expect((await rawIndex())['floor'], 68);
      for (final int q in <int>[3, 4, 40, 67, 68]) {
        expect(await s.save(seq: q, jpeg: jpegFor(q)),
            EvidenceSaveResult.superseded);
      }
      await save(s, 69);
    });

    test(
        'never over-retires: a seq above every seq ever deleted/cleared/'
        'listed is always accepted, even right after a compaction', () async {
      final IntruderEvidenceStore s = open();
      await save(s, 1000); // high old live item
      for (int q = 1; q <= 65; q++) {
        await saveDelete(s, q * 3);
      }
      expect((await rawIndex())['hw'], 195);
      await save(s, 1001);
      await save(s, 196); // between hw and live items: never retired
      await checkAll(s,
          live: <int>[196, 1000, 1001],
          deleted: <int>[for (int q = 1; q <= 65; q++) q * 3]);
    });
  });

  test(
      'documented trade-off: a NEVER-saved seq below hw is refused '
      '(superseded = counted as a cancelled capture), like the clear-all floor',
      () async {
    final IntruderEvidenceStore s = open();
    await save(s, 1);
    for (int q = 2; q <= 130; q += 2) {
      await saveDelete(s, q); // 65 even seqs -> compaction, hw = 130
    }
    expect((await rawIndex())['hw'], 130);
    expect(
        await s.save(seq: 3, jpeg: jpegFor(3)), EvidenceSaveResult.superseded,
        reason: 'gap seq below hw: evidence loss only, never a privacy leak');
    await save(s, 131);
    await checkAll(s, live: <int>[
      1,
      131
    ], deleted: <int>[
      for (int q = 2; q <= 130; q += 2) q,
    ]);
  });

  group('crash / restart at the compaction commit', () {
    test(
        'crash BEFORE the compacting index write: nothing changes, the item '
        'stays listed, earlier deletions stay retired; retry succeeds',
        () async {
      IntruderEvidenceStore s = open();
      await save(s, 1);
      final List<int> deleted = <int>[];
      for (int q = 2; q <= 65; q++) {
        await saveDelete(s, q); // exactly 64 tombstones, no compaction yet
        deleted.add(q);
      }
      await save(s, 66);
      db.failIndexWrite = true;
      expect(await s.delete(66), EvidenceDeleteResult.storageFailed);
      db.failIndexWrite = false;
      s = open();
      await s.startupMaintenance();
      expect(((await rawIndex())['tomb']! as List).length, 64);
      await checkAll(s, live: <int>[1, 66], deleted: deleted);
      expect(await s.delete(66), EvidenceDeleteResult.deleted);
      deleted.add(66);
      await checkAll(s, live: <int>[1], deleted: deleted);
    });

    test(
        'crash AFTER the compacting index write (blob removal fails): the '
        'restart sweeps the orphan and the seq stays retired', () async {
      IntruderEvidenceStore s = open();
      await save(s, 1);
      final List<int> deleted = <int>[];
      for (int q = 2; q <= 65; q++) {
        await saveDelete(s, q);
        deleted.add(q);
      }
      await save(s, 66);
      db.failBlobRemove = true;
      expect(await s.delete(66), EvidenceDeleteResult.deleted);
      db.failBlobRemove = false;
      deleted.add(66);
      expect(await db.getSetting(IntruderEvidenceStore.blobKey(66)), isNotNull,
          reason: 'orphan ciphertext left by the simulated crash');
      s = open();
      await s.startupMaintenance();
      expect(await db.getSetting(IntruderEvidenceStore.blobKey(66)), isNull);
      expect((await rawIndex())['hw'], 66);
      await checkAll(s, live: <int>[1], deleted: deleted);
    });
  });

  group('retention and bounded eviction across compaction', () {
    test(
        'old live item expires after compaction: removed, unreadable; deleted '
        'seqs stay retired; fresh seqs accepted', () async {
      IntruderEvidenceStore s = open();
      await save(s, 1);
      now = now.add(const Duration(days: 20));
      final List<int> deleted = <int>[];
      for (int q = 2; q <= 70; q++) {
        await saveDelete(s, q);
        deleted.add(q);
      }
      await save(s, 71);
      now = now.add(const Duration(days: 11)); // item 1 is 31 days old
      s = open();
      await s.startupMaintenance();
      await checkAll(s, live: <int>[71], deleted: deleted);
      expect(await s.readImage(1), isNull);
      await save(s, 72);
    });

    test('count eviction (maxItems 10) never re-opens a deleted seq', () async {
      final IntruderEvidenceStore s = open(maxItems: 10);
      final List<int> deleted = <int>[];
      for (int q = 1; q <= 80; q++) {
        await saveDelete(s, q * 2);
        deleted.add(q * 2);
      }
      for (int q = 0; q < 12; q++) {
        await save(s, 500 + q); // evicts 500, 501
      }
      await checkAll(s,
          live: <int>[for (int q = 2; q < 12; q++) 500 + q], deleted: deleted);
    });
  });

  group('index parsing with hw', () {
    Future<void> writeRaw(Map<String, Object?> m) async => db.setSetting(
        IntruderEvidenceStore.indexKey,
        'enc:v1:${await cipher.encryptString(jsonEncode(m))}');

    test('listed items BELOW hw are valid (not quarantined)', () async {
      final IntruderEvidenceStore s = open();
      await save(s, 5);
      final Map<String, Object?> idx = await rawIndex();
      await writeRaw(<String, Object?>{...idx, 'hw': 40});
      expect(await s.health(), EvidenceIndexHealth.ok);
      expect((await s.list()).single.seq, 5);
      expect(await s.readImage(5), cleanFor(5));
      expect(await s.save(seq: 20, jpeg: jpegFor(20)),
          EvidenceSaveResult.superseded);
      expect(
          await s.save(seq: 5, jpeg: jpegFor(5)), EvidenceSaveResult.duplicate);
    });

    for (final Object bad in <Object>[-2, 'x', 1.5]) {
      test('invalid hw ($bad) is quarantined, never trusted', () async {
        final IntruderEvidenceStore s = open();
        await writeRaw(<String, Object?>{
          'v': 1,
          'items': const <Object?>[],
          'hw': bad,
        });
        expect(await s.list(), isEmpty);
        expect(await db.getSetting(IntruderEvidenceStore.quarantineKey),
            isNotNull);
      });
    }
  });

  group('deterministic model-based adversarial sequences', () {
    for (final (int seed, int maxItems) in <(int, int)>[
      (1, 100),
      (7, 100),
      (42, 10),
      (2026, 100),
    ]) {
      test('seed $seed, maxItems $maxItems: 700 ops with restarts and crashes',
          () async {
        final Random r = Random(seed);
        IntruderEvidenceStore s = open(maxItems: maxItems);
        final Map<int, DateTime> live = <int, DateTime>{};
        final Set<int> deleted = <int>{};
        int maxSeen = 0, deletes = 0, compactions = 0, lastHw = -1;
        int resurrectionProbes = 0, outOfOrderSaved = 0;

        void evict() {
          final DateTime cutoff =
              now.subtract(IntruderEvidenceStore.defaultRetention);
          live.removeWhere((int _, DateTime at) => at.isBefore(cutoff));
          while (live.length > maxItems) {
            live.remove(live.keys.reduce(min));
          }
        }

        // An old live item that persists across compactions (maxItems 100).
        await save(s, 0);
        live[0] = now;
        for (int step = 0; step < 700; step++) {
          final int op = r.nextInt(100);
          if (step == 350 || step == 690) {
            // clear-all at fixed points so >64-deletion runs build up
            final int f = r.nextInt(maxSeen + 3);
            expect(await s.clearAll(floorSeq: f), EvidenceClearResult.cleared);
            deleted.addAll(live.keys);
            live.clear();
            if (f > maxSeen) maxSeen = f;
          } else if (op < 38) {
            final int q = maxSeen + 1 + r.nextInt(6); // gaps: non-consecutive
            maxSeen = q;
            expect(await s.save(seq: q, jpeg: jpegFor(q)),
                EvidenceSaveResult.saved,
                reason: 'fresh seq $q must be accepted (no over-retirement)');
            live[q] = now;
            evict();
          } else if (op < 48) {
            final int q = r.nextInt(maxSeen + 1); // out-of-order / old
            final EvidenceSaveResult res =
                await s.save(seq: q, jpeg: jpegFor(q));
            if (deleted.contains(q)) {
              resurrectionProbes++;
              expect(res, EvidenceSaveResult.superseded,
                  reason: 'deleted $q resurrected at step $step');
            } else if (live.containsKey(q)) {
              expect(res, EvidenceSaveResult.duplicate);
            } else {
              expect(
                  res,
                  anyOf(
                      EvidenceSaveResult.saved, EvidenceSaveResult.superseded));
              if (res == EvidenceSaveResult.saved) {
                outOfOrderSaved++;
                live[q] = now;
                evict();
              }
            }
          } else if (op < 88) {
            if (live.isEmpty) continue;
            final List<int> keys = live.keys.toList()..sort();
            // Prefer non-oldest so old items survive many compactions.
            final int q = keys.length > 1
                ? keys[1 + r.nextInt(keys.length - 1)]
                : keys.single;
            final int crash = r.nextInt(20);
            if (crash == 0) {
              db.failIndexWrite = true;
              expect(await s.delete(q), EvidenceDeleteResult.storageFailed);
              db.failIndexWrite = false;
            } else {
              db.failBlobRemove = crash == 1;
              expect(await s.delete(q), EvidenceDeleteResult.deleted);
              db.failBlobRemove = false;
              live.remove(q);
              deleted.add(q);
              deletes++;
            }
          } else if (op < 93) {
            now = now.add(Duration(days: r.nextInt(9)));
            await s.enforceRetention();
            evict();
          } else {
            s = open(maxItems: maxItems); // process death + restart
            await s.startupMaintenance();
            evict();
          }
          final Map<String, Object?> idx = await rawIndex();
          final int hw = (idx['hw'] as int?) ?? -1;
          if (hw > lastHw) compactions++;
          lastHw = hw;
          expect(((idx['tomb'] as List?) ?? const <Object?>[]).length,
              lessThanOrEqualTo(IntruderEvidenceStore.maxTombstones));
          expect((await s.list()).map((EvidenceItem e) => e.seq).toList(),
              live.keys.toList()..sort(),
              reason: 'listed set diverged at step $step');
          if (step % 100 == 99) {
            await checkAll(s, live: live.keys, deleted: deleted);
          }
        }
        await checkAll(s, live: live.keys, deleted: deleted);
        expect(deletes, greaterThan(IntruderEvidenceStore.maxTombstones * 2));
        expect(compactions, greaterThanOrEqualTo(1));
        expect(resurrectionProbes, greaterThan(0));
        // ignore: avoid_print
        print('seed=$seed deletes=$deletes compactions=$compactions '
            'probes=$resurrectionProbes outOfOrderSaved=$outOfOrderSaved');
      });
    }
  });
}
