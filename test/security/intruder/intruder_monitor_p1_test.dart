// Phase 13 / P-1 — IntruderMonitor queue accounting, snapshot isolation and
// reliable owner-success reset intent.
//
// P1-T01..T07 and T09..T17 from Phase13/P1_SECURITY_DESIGN_GATE.md §5, the
// epoch-ordering tests O1..O5 (design correction 2), the pending-read bound
// tests (design correction 3) and the restart residual characterization
// (design correction 4 / Q-P1-1). P1-T08, T18 and T19 (real coordinator,
// container and host) live in test/regression/p13_p1_monitor_reliability_test
// .dart.
//
// Deterministic scheduling: storage writes are held on an explicit gate, so
// the exact queue contents at every call are known.
//
// SIMULATED: pure Dart VM with in-memory storage. No platform channel, APK,
// device or biometric hardware involved.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/credentials/verified_attempt.dart';
import 'package:smart_app_lock/security/intruder/failed_attempt_event.dart';
import 'package:smart_app_lock/security/intruder/intruder_failure_log_store.dart';
import 'package:smart_app_lock/security/intruder/intruder_monitor.dart';

const String _key = IntruderFailureLogStore.storageKey;
const String _qKey = IntruderFailureLogStore.quarantineKey;

/// Database with switchable faults on the intruder-log row only.
class _P1Db extends InMemoryLocalDatabase {
  bool failReads = false;

  /// Fails exactly this many upcoming log writes, then succeeds.
  int failNextWrites = 0;
  Completer<void>? writeGate;

  /// Log-row write attempts (successful or not) and successful writes.
  int logWriteAttempts = 0;
  int logWrites = 0;

  @override
  Future<String?> getSetting(String key) async {
    if (failReads && key == _key) {
      throw StateError('read fault');
    }
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) async {
    if (key == _key) {
      final Completer<void>? gate = writeGate;
      if (gate != null) {
        await gate.future;
      }
      logWriteAttempts++;
      if (failNextWrites > 0) {
        failNextWrites--;
        throw StateError('write fault (one-shot)');
      }
      logWrites++;
    }
    return super.setSetting(key, value);
  }
}

class _Recorder implements IntruderEventListener {
  _Recorder({this.throwing = false, this.hanging = false});

  final bool throwing;
  final bool hanging;
  final List<int> runs = <int>[];
  int ownerVerified = 0;
  final Completer<void> _never = Completer<void>();

  @override
  void onFailedAttemptRecorded(FailedAttemptEvent event) {
    runs.add(event.consecutiveFailures);
    if (hanging) {
      // A capture that never finishes (unawaited, as the coordinator does).
      unawaited(_never.future.then((_) {}));
    }
    if (throwing) throw StateError('listener fault');
  }

  @override
  void onOwnerVerified() {
    ownerVerified++;
    if (throwing) throw StateError('listener fault');
  }
}

int _vid = 0;
final DateTime _t0 = DateTime(2026, 10, 22, 12);

VerifiedAttempt _fail() => VerifiedAttempt(
      verificationId: 'p1:${++_vid}',
      type: AuthType.pin,
      matched: false,
      result: const AuthFailure(
        reason: AuthFailureReason.wrongCredential,
        remainingAttempts: 2,
      ),
      counterPersisted: true,
      lockoutStreak: 0,
      context: AuthAttemptContext.smartAppLock,
      at: _t0,
    );

VerifiedAttempt _ok({bool persisted = true}) => VerifiedAttempt(
      verificationId: 'p1:${++_vid}',
      type: AuthType.pin,
      matched: true,
      result: const AuthSuccess(type: AuthType.pin),
      counterPersisted: persisted,
      lockoutStreak: 0,
      context: AuthAttemptContext.smartAppLock,
      at: _t0,
    );

void main() {
  late _P1Db db;

  IntruderMonitor build({
    int maxPending = IntruderMonitor.defaultMaxPending,
    int maxSnapshotWaiters = IntruderMonitor.defaultMaxSnapshotWaiters,
  }) =>
      IntruderMonitor(
        store: IntruderFailureLogStore(db),
        now: () => _t0,
        maxPending: maxPending,
        maxSnapshotWaiters: maxSnapshotWaiters,
      );

  /// The run counter as persisted (a fresh reader, no cache).
  Future<int> persistedRun() async =>
      (await build().snapshot())!.consecutiveFailures;

  /// Event runs in the persisted log, oldest first.
  Future<List<int>> eventRuns(IntruderMonitor m) async => (await m.snapshot())!
      .events
      .map((FailedAttemptEvent e) => e.consecutiveFailures)
      .toList();

  /// Persists [n] failures one at a time (run = n afterwards).
  Future<void> failures(IntruderMonitor m, int n) async {
    for (int i = 0; i < n; i++) {
      m.onVerifiedAttempt(_fail());
      await m.idle();
    }
  }

  /// Holds every log write until [release].
  void stall() => db.writeGate = Completer<void>();
  void release() {
    final Completer<void>? g = db.writeGate;
    db.writeGate = null;
    g?.complete();
  }

  setUp(() {
    db = _P1Db();
  });

  group('P-1 snapshot isolation (reads never consume record capacity)', () {
    test(
        'P1-T01 64 records + 1,000 snapshots under stall: 64/64 recorded, 0 '
        'dropped; ONE read op; waiters hard-capped at 64, excess = null',
        () async {
      final IntruderMonitor m = build();
      stall();
      for (int i = 0; i < 64; i++) {
        m.onVerifiedAttempt(_fail());
      }
      final List<Future<IntruderFailureLog?>> reads =
          <Future<IntruderFailureLog?>>[
        for (int i = 0; i < 1000; i++) m.snapshot(),
      ];
      expect(m.pendingRecords, 64);
      expect(m.liveReadOps, 1, reason: 'tail-coalesced');
      expect(m.snapshotWaiters, 64, reason: 'hard cap');
      expect(m.status.snapshotsRejected, 936);
      expect(m.status.droppedFailureRecords, 0);
      release();
      final List<IntruderFailureLog?> got = await Future.wait(reads);
      await m.idle();
      final List<IntruderFailureLog> accepted =
          got.whereType<IntruderFailureLog>().toList();
      expect(accepted, hasLength(64));
      expect(got.sublist(64), everyElement(isNull),
          reason: 'rejected callers get null (unavailable), never "empty"');
      for (final IntruderFailureLog l in accepted) {
        expect(l.events, hasLength(64), reason: 'sees every earlier record');
      }
      expect(m.status.droppedFailureRecords, 0);
      expect(m.status.droppedEvents, 0, reason: 'alias');
      expect(m.snapshotWaiters, 0);
      expect(m.liveReadOps, 0);
      expect(m.peakReadOps, 1);
      expect(m.peakSnapshotWaiters, 64);
    });

    test(
        'P1-T01b interleaved records and snapshots: each snapshot sees '
        'exactly the records queued before it; read ops <= non-read ops + 1',
        () async {
      final IntruderMonitor m = build(maxSnapshotWaiters: 10000);
      stall();
      for (int i = 0; i < 32; i++) {
        m.onVerifiedAttempt(_fail());
      }
      final List<Future<IntruderFailureLog?>> first =
          <Future<IntruderFailureLog?>>[
        for (int i = 0; i < 500; i++) m.snapshot(),
      ];
      for (int i = 0; i < 32; i++) {
        m.onVerifiedAttempt(_fail());
      }
      final List<Future<IntruderFailureLog?>> second =
          <Future<IntruderFailureLog?>>[
        for (int i = 0; i < 500; i++) m.snapshot(),
      ];
      expect(m.liveReadOps, 2);
      expect(m.pendingRecords, 64);
      release();
      for (final IntruderFailureLog? l in await Future.wait(first)) {
        expect(l!.events, hasLength(32));
      }
      for (final IntruderFailureLog? l in await Future.wait(second)) {
        expect(l!.events, hasLength(64));
      }
      expect(m.status.droppedFailureRecords, 0);
      expect(m.status.snapshotsRejected, 0);
    });

    test(
        'P1-T02 ordering: S1, S2 (adjacent) share state without R; S3 queued '
        'after R sees R', () async {
      final IntruderMonitor m = build();
      stall();
      m.onVerifiedAttempt(_fail()); // F0, running, held on the gate
      final Future<IntruderFailureLog?> s1 = m.snapshot();
      final Future<IntruderFailureLog?> s2 = m.snapshot();
      m.onVerifiedAttempt(_fail()); // R
      final Future<IntruderFailureLog?> s3 = m.snapshot();
      expect(m.liveReadOps, 2, reason: 'S3 must not join the op before R');
      release();
      final IntruderFailureLog l1 = (await s1)!;
      final IntruderFailureLog l2 = (await s2)!;
      final IntruderFailureLog l3 = (await s3)!;
      expect(l1.events, hasLength(1));
      expect(identical(l1, l2), isTrue);
      expect(l3.events, hasLength(2));
    });

    for (final bool withReads in <bool>[false, true]) {
      test(
          'P1-T03 100 failures under stall ${withReads ? 'WITH' : 'without'} '
          'concurrent reads: 64 recorded / 36 dropped (Phase 12 baseline)',
          () async {
        final IntruderMonitor m = build();
        stall();
        final List<Future<IntruderFailureLog?>> reads =
            <Future<IntruderFailureLog?>>[];
        for (int i = 0; i < 100; i++) {
          m.onVerifiedAttempt(_fail());
          if (withReads && i % 10 == 0) reads.add(m.snapshot());
        }
        expect(m.status.droppedFailureRecords, 36);
        release();
        await Future.wait(reads);
        await m.idle();
        expect((await m.snapshot())!.events, hasLength(64));
        expect(m.status.droppedFailureRecords, 36);
      });
    }
  });

  group('P-1 owner-success reset is never dropped', () {
    test(
        'P1-T04 record cap full + owner success: reset still queued; the '
        'success is not counted as a dropped record; final run 0', () async {
      final IntruderMonitor m = build();
      stall();
      for (int i = 0; i < 64; i++) {
        m.onVerifiedAttempt(_fail());
      }
      m.onVerifiedAttempt(_ok());
      expect(m.status.droppedFailureRecords, 0);
      expect(m.status.resetPending, isTrue);
      expect(m.liveResetOps, 1);
      m.onVerifiedAttempt(_fail()); // record cap still full: this one drops
      expect(m.status.droppedFailureRecords, 1);
      release();
      await m.idle();
      expect(await persistedRun(), 0);
      expect(m.status.resetPending, isFalse);
      expect(m.status.resetFailures, 0);
      expect(m.status.droppedFailureRecords, 1);
    });

    test(
        'P1-T05 F1..F3, then S and F4 queued under stall: F4 restarts at 1; '
        'F1..F3 count 1, 2, 3', () async {
      final IntruderMonitor m = build();
      await failures(m, 3);
      stall();
      m.onVerifiedAttempt(_ok());
      m.onVerifiedAttempt(_fail());
      release();
      await m.idle();
      expect(await eventRuns(m), <int>[1, 2, 3, 1]);
      expect(await persistedRun(), 1);
    });

    test(
        'P1-T06 / O1 S1, F2, S2 with the S1 reset still queued: two reset '
        'ops in order (never coalesced across F2); F2 run 1; final run 0',
        () async {
      final IntruderMonitor m = build();
      await failures(m, 2);
      stall();
      m.onVerifiedAttempt(_fail()); // F0: running, run 3
      m.onVerifiedAttempt(_ok()); // S1: reset op queued (tail)
      m.onVerifiedAttempt(_fail()); // F2
      m.onVerifiedAttempt(_ok()); // S2: S1's op is no longer the tail
      expect(m.liveResetOps, 1, reason: 'S2 deferred, not merged into S1');
      expect(m.status.resetPending, isTrue);
      release();
      await m.idle();
      expect(await eventRuns(m), <int>[1, 2, 3, 1]);
      expect(await persistedRun(), 0, reason: 'S2 came after F2');
      expect(m.peakResetOps, lessThanOrEqualTo(2));
      expect(m.status.resetPending, isFalse);
    });

    test(
        'P1-T07 1,000 successes under stall: <= 1 reset op queued; one reset '
        'write after release', () async {
      final IntruderMonitor m = build();
      await failures(m, 2);
      stall();
      m.onVerifiedAttempt(_fail()); // running, held
      for (int i = 0; i < 1000; i++) {
        m.onVerifiedAttempt(_ok());
      }
      expect(m.liveResetOps, 1);
      final int before = db.logWrites;
      release();
      await m.idle();
      expect(db.logWrites - before, 2, reason: 'held record + ONE reset');
      expect(m.peakResetOps, 1);
      expect(await persistedRun(), 0);
    });

    test(
        'P1-T07b successes while a reset is RUNNING: at most 1 running + 1 '
        'queued reset op', () async {
      final IntruderMonitor m = build();
      await failures(m, 2);
      stall();
      m.onVerifiedAttempt(_ok()); // reset starts, write held
      for (int i = 0; i < 1000; i++) {
        m.onVerifiedAttempt(_ok());
      }
      expect(m.liveResetOps, 2);
      release();
      await m.idle();
      expect(m.peakResetOps, 2);
      expect(await persistedRun(), 0);
      expect(m.status.resetPending, isFalse);
    });

    test(
        'P1-T09 stale run >= threshold (reset write lost), then S, then 3 '
        'failures: runs 1, 2, 3 (threshold 3 is reached, not skipped)',
        () async {
      final IntruderMonitor m = build();
      final _Recorder rec = _Recorder();
      m.listener = rec;
      await failures(m, 3);
      db.failNextWrites = 1; // one-shot: a retry loop would show
      m.onVerifiedAttempt(_ok());
      await m.idle();
      rec.runs.clear();
      await failures(m, 3);
      expect(rec.runs, <int>[1, 2, 3]);
    });
  });

  group('P-1 epoch ordering (design correction 2)', () {
    test('O2 S1, F2, S2, F3 (queued together): F2 run 1, F3 run 1, final 1',
        () async {
      final IntruderMonitor m = build();
      await failures(m, 2);
      stall();
      m.onVerifiedAttempt(_fail()); // F0, run 3
      m.onVerifiedAttempt(_ok()); // S1
      m.onVerifiedAttempt(_fail()); // F2
      m.onVerifiedAttempt(_ok()); // S2
      m.onVerifiedAttempt(_fail()); // F3
      release();
      await m.idle();
      expect(await eventRuns(m), <int>[1, 2, 3, 1, 1]);
      expect(await persistedRun(), 1, reason: 'F3 came after S2');
    });

    test(
        'O3 a reset write failure, then a later success and a failure: '
        'resetFailures 1; F3 run 1; no record counted as dropped', () async {
      final IntruderMonitor m = build();
      await failures(m, 2);
      db.failNextWrites = 1;
      m.onVerifiedAttempt(_ok()); // S1: reset write fails
      await m.idle();
      expect(m.status.resetFailures, 1);
      expect(m.status.resetPending, isTrue);
      expect(await persistedRun(), 2, reason: 'nothing claimed as persisted');
      m.onVerifiedAttempt(_ok()); // S2
      m.onVerifiedAttempt(_fail()); // F3
      await m.idle();
      expect(await eventRuns(m), <int>[1, 2, 1]);
      expect(m.status.resetFailures, 1);
      expect(m.status.droppedFailureRecords, 0);
      expect(m.status.resetPending, isFalse);
    });

    test(
        'O4 many successes separated by failures, all queued behind a stall: '
        'every failure after a success restarts at 1', () async {
      final IntruderMonitor m = build();
      await failures(m, 2);
      stall();
      m.onVerifiedAttempt(_fail()); // run 3
      for (int i = 0; i < 4; i++) {
        m.onVerifiedAttempt(_ok());
        m.onVerifiedAttempt(_fail());
      }
      expect(m.liveResetOps, 1);
      release();
      await m.idle();
      expect(await eventRuns(m), <int>[1, 2, 3, 1, 1, 1, 1]);
      expect(await persistedRun(), 1);
      expect(m.peakResetOps, lessThanOrEqualTo(2));
      expect(m.status.resetPending, isFalse);
    });

    test(
        'O5 a later reset is never treated as persisted because an earlier '
        'one succeeded: S1 ok, F2, S2 write fails, F3 restarts at 1', () async {
      final IntruderMonitor m = build();
      await failures(m, 2);
      m.onVerifiedAttempt(_ok()); // S1 persisted
      await m.idle();
      await failures(m, 1); // F2 run 1
      db.failNextWrites = 1;
      m.onVerifiedAttempt(_ok()); // S2: reset write fails
      await m.idle();
      expect(m.status.resetPending, isTrue,
          reason: 'S1 being applied says nothing about S2');
      expect(await persistedRun(), 1);
      await failures(m, 1); // F3
      expect(await eventRuns(m), <int>[1, 2, 1, 1]);
      expect(m.status.resetPending, isFalse);
    });

    test(
        'gate B unchanged: a failure verified before a later owner success '
        'is logged but never notified, even though its record runs first',
        () async {
      final IntruderMonitor m = build();
      final _Recorder rec = _Recorder();
      m.listener = rec;
      stall();
      m.onVerifiedAttempt(_fail()); // F1: verified, write held
      m.onVerifiedAttempt(_ok()); // owner success supersedes F1
      release();
      await m.idle();
      expect(await eventRuns(m), <int>[1], reason: 'still logged (M1)');
      expect(rec.runs, isEmpty, reason: 'superseded: never notified');
      await failures(m, 1);
      expect(rec.runs, <int>[1], reason: 'later failures notify normally');
    });

    test('an unpersisted success never schedules a reset or bumps the epoch',
        () async {
      final IntruderMonitor m = build();
      final _Recorder rec = _Recorder();
      m.listener = rec;
      await failures(m, 2);
      m.onVerifiedAttempt(_ok(persisted: false));
      await m.idle();
      expect(m.liveResetOps, 0);
      expect(m.peakResetOps, 0);
      expect(m.status.resetPending, isFalse);
      expect(rec.ownerVerified, 0);
      await failures(m, 1);
      expect(await persistedRun(), 3);
    });
  });

  group('P-1 storage faults during a reset', () {
    test(
        'P1-T10 write fault during the reset only, then a failure with '
        'storage OK: run 1; resetFailures 1; nothing dropped', () async {
      final IntruderMonitor m = build();
      await failures(m, 3);
      db.failNextWrites = 1; // one-shot: a retry loop would show
      m.onVerifiedAttempt(_ok());
      await m.idle();
      expect(m.status.resetFailures, 1);
      expect(m.status.resetPending, isTrue);
      expect(m.status.droppedFailureRecords, 0);
      expect(m.status.health, IntruderMonitorHealth.storageError);
      await failures(m, 1);
      expect(await eventRuns(m), <int>[1, 2, 3, 1]);
      expect(m.status.resetPending, isFalse);
      expect(m.status.resetFailures, 1);
      expect(m.status.droppedFailureRecords, 0);
      expect(m.status.health, IntruderMonitorHealth.ok);
    });

    test(
        'P1-T11 write fault during the reset, no failure, next success with '
        'storage OK: run 0; exactly 2 reset write attempts (no retry loop)',
        () async {
      final IntruderMonitor m = build();
      await failures(m, 2);
      final int base = db.logWriteAttempts;
      db.failNextWrites = 1;
      m.onVerifiedAttempt(_ok());
      await m.idle();
      expect(db.logWriteAttempts - base, 1, reason: 'never re-enqueued');
      expect(await persistedRun(), 2);
      m.onVerifiedAttempt(_ok());
      await m.idle();
      expect(db.logWriteAttempts - base, 2);
      expect(await persistedRun(), 0);
      expect(m.status.resetPending, isFalse);
    });

    test('P1-T11b permanently failing storage + 50 successes: bounded writes',
        () async {
      final IntruderMonitor m = build();
      await failures(m, 2);
      final int base = db.logWriteAttempts;
      // Finite but larger than any honest attempt count, so a retry loop
      // fails this assertion instead of spinning forever.
      db.failNextWrites = 1000;
      for (int i = 0; i < 50; i++) {
        m.onVerifiedAttempt(_ok());
        await m.idle();
      }
      expect(db.logWriteAttempts - base, lessThanOrEqualTo(50));
      expect(m.status.resetFailures, db.logWriteAttempts - base);
      expect(m.status.droppedFailureRecords, 0);
      expect(m.status.resetPending, isTrue);
    });

    test(
        'P1-T12 transient read fault during the reset: storageError, intent '
        'kept; recovery as T10', () async {
      await failures(build(), 2);
      final IntruderMonitor m = build(); // fresh: no cache
      db.failReads = true;
      m.onVerifiedAttempt(_ok());
      await m.idle();
      expect(m.status.health, IntruderMonitorHealth.storageError);
      expect(m.status.resetPending, isTrue);
      expect(m.status.droppedFailureRecords, 0);
      db.failReads = false;
      await failures(m, 1);
      expect(await eventRuns(m), <int>[1, 2, 1]);
      expect(m.status.resetPending, isFalse);
    });

    test(
        'P1-T13 newer schema: failure + success leave the row byte-identical; '
        'read-only; 1 dropped record; reset stays pending (documented)',
        () async {
      final String newer = jsonEncode(<String, Object?>{
        'schema': 'sal.intruder_log',
        'v': 2,
        'future': true,
      });
      await db.setSetting(_key, newer);
      final int writes = db.logWrites;
      final IntruderMonitor m = build();
      m.onVerifiedAttempt(_fail());
      m.onVerifiedAttempt(_ok());
      await m.idle();
      expect(await db.getSetting(_key), newer);
      expect(await db.getSetting(_qKey), isNull);
      expect(db.logWrites, writes);
      expect(m.status.health, IntruderMonitorHealth.readOnly);
      expect(m.status.droppedFailureRecords, 1);
      expect(m.status.resetFailures, 0);
      expect(m.status.resetPending, isTrue);
      expect(await m.snapshot(), isNull);
    });

    test(
        'P1-T14 corrupt log at reset: quarantined once; run 0; no log write '
        'needed', () async {
      await db.setSetting(_key, '{not json');
      final int writes = db.logWrites;
      final IntruderMonitor m = build();
      m.onVerifiedAttempt(_ok());
      await m.idle();
      expect(await db.getSetting(_qKey), '{not json');
      expect(m.status.quarantinedCorruptLog, isTrue);
      expect(db.logWrites, writes);
      expect((await m.snapshot())!.consecutiveFailures, 0);
      expect(m.status.resetPending, isFalse);
    });

    test(
        'P1-T16 throwing and hanging listeners during a reset storm: '
        'identical log and status to no listener', () async {
      Future<String> run(_Recorder? rec) async {
        db = _P1Db();
        final IntruderMonitor m = build();
        m.listener = rec;
        await failures(m, 2);
        stall();
        for (int i = 0; i < 20; i++) {
          m.onVerifiedAttempt(_fail());
          m.onVerifiedAttempt(_ok());
          m.onVerifiedAttempt(_ok());
        }
        m.onVerifiedAttempt(_fail());
        release();
        await m.idle();
        final IntruderMonitorStatus s = m.status;
        return '${await eventRuns(m)} dropped=${s.droppedFailureRecords} '
            'resetFailures=${s.resetFailures} pending=${s.resetPending} '
            'health=${s.health.name}';
      }

      final String plain = await run(null);
      final String throwing = await run(_Recorder(throwing: true));
      final String hanging = await run(_Recorder(hanging: true));
      expect(throwing, plain);
      expect(hanging, plain);
      expect(
          plain,
          endsWith(', 1] dropped=0 resetFailures=0 pending=false '
              'health=ok'));
    });
  });

  group('P-1 listener isolation (P12/M2 N08 property)', () {
    test(
        'listener exceptions never escape onVerifiedAttempt and never mark '
        'the log unhealthy (P-1 would otherwise mask a lost reset inline)',
        () async {
      final IntruderMonitor m = build();
      final _Recorder rec = _Recorder(throwing: true);
      m.listener = rec;
      expect(() => m.onVerifiedAttempt(_fail()), returnsNormally);
      await m.idle();
      expect(() => m.onVerifiedAttempt(_ok()), returnsNormally);
      await m.idle();
      expect(() => m.onVerifiedAttempt(_fail()), returnsNormally);
      await m.idle();
      expect(rec.ownerVerified, 1);
      expect(rec.runs, <int>[1, 1]);
      expect(m.status.health, IntruderMonitorHealth.ok);
      expect(m.peakResetOps, 1, reason: 'the reset op was scheduled');
      expect(await eventRuns(m), <int>[1, 1]);
    });
  });

  group('P-1 pending reads stay bounded (design correction 3)', () {
    test(
        'stalled storage, 10,000 interleaved failures / successes / '
        'snapshots: every live count stays within its proven bound', () async {
      const int cap = IntruderMonitor.defaultMaxPending;
      const int waiters = IntruderMonitor.defaultMaxSnapshotWaiters;
      final IntruderMonitor m = build();
      stall();
      final List<Future<IntruderFailureLog?>> reads =
          <Future<IntruderFailureLog?>>[];
      for (int i = 0; i < 10000; i++) {
        switch (i % 3) {
          case 0:
            m.onVerifiedAttempt(_fail());
          case 1:
            m.onVerifiedAttempt(_ok());
          case 2:
            reads.add(m.snapshot());
        }
        expect(m.pendingRecords, lessThanOrEqualTo(cap));
        expect(m.liveResetOps, lessThanOrEqualTo(2));
        expect(m.snapshotWaiters, lessThanOrEqualTo(waiters));
        expect(m.liveReadOps,
            lessThanOrEqualTo(m.pendingRecords + m.liveResetOps + 1));
        expect(m.liveReadOps, lessThanOrEqualTo(m.snapshotWaiters));
      }
      expect(m.peakSnapshotWaiters, waiters);
      expect(m.peakResetOps, lessThanOrEqualTo(2));
      expect(m.peakReadOps, lessThanOrEqualTo(cap + 2 + 1));
      expect(m.status.snapshotsRejected, reads.length - waiters);
      release();
      await Future.wait(reads);
      await m.idle();
      expect(m.snapshotWaiters, 0);
      expect(m.liveReadOps, 0);
      expect(m.liveResetOps, 0);
      expect(m.pendingRecords, 0);
    });

    test('rejected callers are counted and never wait', () async {
      final IntruderMonitor m = build(maxSnapshotWaiters: 1);
      stall();
      m.onVerifiedAttempt(_fail());
      final Future<IntruderFailureLog?> a = m.snapshot();
      expect(await m.snapshot(), isNull, reason: 'completes immediately');
      expect(m.status.snapshotsRejected, 1);
      release();
      expect((await a)!.events, hasLength(1));
    });

    test('an unreadable log completes every joined waiter with null', () async {
      await failures(build(), 1);
      final IntruderMonitor m = build();
      db.failReads = true;
      final List<IntruderFailureLog?> got =
          await Future.wait(<Future<IntruderFailureLog?>>[
        m.snapshot(),
        m.snapshot(),
        m.snapshot(),
      ]);
      expect(got, everyElement(isNull));
      expect(m.snapshotWaiters, 0);
    });
  });

  group('P-1 zone safety', () {
    testWidgets(
        'P1-T17 snapshot waiters in different zones share one read op; a '
        'zone that never runs its microtasks does not stall the others',
        (WidgetTester tester) async {
      final IntruderMonitor m = build();
      await tester.runAsync(() async {
        stall();
        m.onVerifiedAttempt(_fail()); // drain runs in the real zone
      });
      bool fakeDone = false;
      unawaited(m.snapshot().then((_) => fakeDone = true)); // fake zone
      await tester.runAsync(() async {
        final Future<IntruderFailureLog?> real = m.snapshot(); // same op
        expect(m.liveReadOps, 1);
        release();
        final IntruderFailureLog? l =
            await real.timeout(const Duration(seconds: 5));
        expect(l!.events, hasLength(1));
      });
      await tester.pump();
      expect(fakeDone, isTrue);
    });
  });

  group('P-1 restart residual Q-P1-1 (characterization, NOT a fix)', () {
    test('a persisted reset survives restart: next failure is run 1', () async {
      final IntruderMonitor m = build();
      await failures(m, 3);
      m.onVerifiedAttempt(_ok());
      await m.idle();
      final IntruderMonitor restarted = build();
      await failures(restarted, 1);
      expect((await restarted.snapshot())!.consecutiveFailures, 1);
    });

    test(
        'P1-T15b RESIDUAL: reset write failed, then process restart: the '
        'stale run (3) is reloaded and the next failure is run 4', () async {
      final IntruderMonitor m = build();
      await failures(m, 3);
      db.failNextWrites = 1; // one-shot: a retry loop would show
      m.onVerifiedAttempt(_ok());
      await m.idle();
      final IntruderMonitor restarted = build();
      expect((await restarted.snapshot())!.consecutiveFailures, 3,
          reason: 'RESIDUAL Q-P1-1: no durable success signal (by design)');
      await failures(restarted, 1);
      expect((await restarted.snapshot())!.consecutiveFailures, 4);
      expect(restarted.status.resetPending, isFalse,
          reason: 'the in-memory intent did not survive the restart');
    });

    test(
        'P1-T15c RESIDUAL: reset still pending (write never completed) at '
        'process death: restart reloads run 3', () async {
      final IntruderMonitor m = build();
      await failures(m, 3);
      stall();
      m.onVerifiedAttempt(_ok()); // reset write held forever
      await pumpEventQueue();
      expect(m.status.resetPending, isTrue);
      db.writeGate = null; // the "new process" has working storage
      final IntruderMonitor restarted = build();
      expect((await restarted.snapshot())!.consecutiveFailures, 3,
          reason: 'RESIDUAL Q-P1-1');
    });
  });
}
