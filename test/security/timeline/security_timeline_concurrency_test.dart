// Phase 13 / M1 final gate — R-P13M1-1: timeline snapshot reads versus
// failed-unlock queue saturation.
//
// Deterministic scheduling: storage reads/writes are held on explicit
// gates, so the exact queue state at every enqueue is known. Compared with
// the Phase 12 baseline (no timeline reads):
//  * timeline reads add AT MOST ONE occupied monitor slot at any time,
//    however many loads are requested (single-flight reader);
//  * every attempt is either recorded or counted as dropped;
//  * the timeline reports the drops and never claims complete history;
//  * forced reads cannot grow the monitor queue without bound under
//    stalled storage;
//  * unlock / lockout decisions are identical with and without concurrent
//    timeline reads (the monitor and the timeline are observe-only).
//
// SIMULATED: pure Dart VM, in-memory storage.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/credentials/credential_state.dart';
import 'package:smart_app_lock/security/credentials/verified_attempt.dart';
import 'package:smart_app_lock/security/encryption/settings_cipher.dart';
import 'package:smart_app_lock/security/encryption/settings_cipher_impl.dart';
import 'package:smart_app_lock/security/intruder/failed_attempt_event.dart';
import 'package:smart_app_lock/security/intruder/intruder_failure_log_store.dart';
import 'package:smart_app_lock/security/intruder/intruder_monitor.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/security/timeline/security_event_journal.dart';
import 'package:smart_app_lock/security/timeline/security_event_journal_store.dart';
import 'package:smart_app_lock/security/timeline/security_journal_event.dart';
import 'package:smart_app_lock/security/timeline/security_timeline.dart';
import 'package:smart_app_lock/services/impl/static_intruder_evidence_service.dart';

const String _pin = '482916';
const String _logKey = IntruderFailureLogStore.storageKey;
const String _jKey = SecurityEventJournalStore.storageKey;
final DateTime _t0 = DateTime(2026, 10, 22, 12);

/// Holds reads and/or writes of selected keys until [release].
class _GateDb extends InMemoryLocalDatabase {
  final Set<String> gatedReads = <String>{};
  final Set<String> gatedWrites = <String>{};
  Completer<void> _gate = Completer<void>();

  void release() {
    gatedReads.clear();
    gatedWrites.clear();
    if (!_gate.isCompleted) _gate.complete();
  }

  void arm() {
    if (_gate.isCompleted) _gate = Completer<void>();
  }

  @override
  Future<String?> getSetting(String key) async {
    if (gatedReads.contains(key)) await _gate.future;
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) async {
    if (gatedWrites.contains(key)) await _gate.future;
    return super.setSetting(key, value);
  }
}

/// Counts snapshot calls and the maximum number simultaneously in flight.
class _CountingMonitor extends IntruderMonitor {
  _CountingMonitor({required super.store, super.now, super.maxPending});

  int calls = 0;
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<IntruderFailureLog?> snapshot() {
    calls++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    return super.snapshot().whenComplete(() => inFlight--);
  }
}

class _CountingJournal extends SecurityEventJournal {
  _CountingJournal({required super.store, super.now, super.maxPending});

  int calls = 0;
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<SecurityJournalView> read() {
    calls++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    return super.read().whenComplete(() => inFlight--);
  }
}

int _vid = 0;

VerifiedAttempt _wrong() => VerifiedAttempt(
      verificationId: 'cc:${++_vid}',
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

class _Rig {
  _Rig({int maxPending = 8, int journalMaxPending = 64}) {
    db = _GateDb();
    final SettingsCipher cipher = AesGcmSettingsCipher(InMemorySecretStore());
    monitor = _CountingMonitor(
      store: IntruderFailureLogStore(db, cipher: cipher),
      now: () => _t0,
      maxPending: maxPending,
    );
    final SecurityEventJournalStore js =
        SecurityEventJournalStore(db, cipher: cipher);
    journal = _CountingJournal(
        store: js, now: () => _t0, maxPending: journalMaxPending);
    reader = SecurityTimelineReader(
      monitor: monitor,
      journal: journal,
      journalStore: js,
      database: db,
    );
  }

  late final _GateDb db;
  late final _CountingMonitor monitor;
  late final _CountingJournal journal;
  late final SecurityTimelineReader reader;

  int failures(SecurityTimelineSnapshot s) => s.entries
      .where((TimelineEntry e) => e.kind == TimelineEntryKind.failedUnlock)
      .length;
}

void main() {
  group('R-P13M1-1 deterministic saturation (maxPending 8)', () {
    /// 4 failures queued behind a held write, then [loads] timeline loads,
    /// then 16 more failures; then storage is released.
    Future<(int, int, List<SecurityTimelineSnapshot>, _Rig)> scenario(
        int loads) async {
      final _Rig r = _Rig();
      r.db.arm();
      r.db.gatedWrites.add(_logKey);
      for (int i = 0; i < 4; i++) {
        r.monitor.onVerifiedAttempt(_wrong());
      }
      final List<Future<SecurityTimelineSnapshot>> pending =
          <Future<SecurityTimelineSnapshot>>[
        for (int i = 0; i < loads; i++) r.reader.load(),
      ];
      for (int i = 0; i < 16; i++) {
        r.monitor.onVerifiedAttempt(_wrong());
      }
      r.db.release();
      final List<SecurityTimelineSnapshot> snaps = await Future.wait(pending);
      await r.monitor.idle();
      final IntruderFailureLog log = (await r.monitor.snapshot())!;
      return (log.nextSeq, r.monitor.status.droppedEvents, snaps, r);
    }

    test('Phase 12 baseline (no timeline reads): 8 recorded, 12 dropped',
        () async {
      final (int recorded, int dropped, _, _) = await scenario(0);
      expect(recorded, 8);
      expect(dropped, 12);
      expect(recorded + dropped, 20);
    });

    test(
        'one concurrent timeline read costs AT MOST one slot (7 / 13); '
        'accounting exact; timeline discloses the loss', () async {
      final (int recorded, int dropped, List<SecurityTimelineSnapshot> s, _) =
          await scenario(1);
      expect(recorded, 7);
      expect(dropped, 13);
      expect(recorded + dropped, 20, reason: 'every attempt accounted for');
      final SecurityTimelineSnapshot snap = s.single;
      // The snapshot ran in queue order, after the 4 earlier records.
      expect(
          snap.entries
              .where(
                  (TimelineEntry e) => e.kind == TimelineEntryKind.failedUnlock)
              .length,
          4);
      final TimelineSourceStatus f = snap.sources[0];
      expect(f.available, isTrue);
      expect(f.lost, 13, reason: 'drops reported, not hidden');
      expect(snap.hasGaps, isTrue);
      expect(snap.confirmedEmpty, isFalse);
    });

    test(
        'TEN concurrent timeline reads still cost at most ONE slot '
        '(single-flight); at most one snapshot in flight', () async {
      final (
        int recorded,
        int dropped,
        List<SecurityTimelineSnapshot> snaps,
        _Rig r
      ) = await scenario(10);
      expect(recorded, 7);
      expect(dropped, 13);
      expect(r.monitor.maxInFlight, 1);
      expect(r.journal.maxInFlight, 1);
      expect(r.monitor.calls, lessThanOrEqualTo(3),
          reason: '10 requests coalesce into <= 2 loads (+1 test read)');
      for (final SecurityTimelineSnapshot s in snaps) {
        expect(s.sources[0].lost, 13);
        expect(s.hasGaps, isTrue);
        expect(s.confirmedEmpty, isFalse);
      }
    });

    test(
        'late callers join the NEXT load: their snapshot starts after their '
        'call (never stale)', () async {
      final _Rig r = _Rig();
      r.db.arm();
      r.db.gatedWrites.add(_logKey);
      r.monitor.onVerifiedAttempt(_wrong());
      final Future<SecurityTimelineSnapshot> first = r.reader.load();
      r.monitor.onVerifiedAttempt(_wrong()); // after first's snapshot
      final Future<SecurityTimelineSnapshot> late = r.reader.load();
      r.db.release();
      expect(r.failuresOf(await first), 1);
      expect(r.failuresOf(await late), 2,
          reason: 'the late caller sees the record made before its call');
    });
  });

  group('R-P13M1-1 stalled storage: no unbounded growth', () {
    test(
        '1,000 loads with storage stalled leave exactly ONE forced snapshot '
        'queued; capacity for failure records is preserved (7 of 8)', () async {
      final _Rig r = _Rig();
      r.db.arm();
      r.db.gatedReads.addAll(<String>{_logKey, _jKey});
      r.db.gatedWrites.addAll(<String>{_logKey, _jKey});
      final List<Future<SecurityTimelineSnapshot>> loads =
          <Future<SecurityTimelineSnapshot>>[
        for (int i = 0; i < 1000; i++) r.reader.load(),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(r.monitor.inFlight, 1);
      expect(r.monitor.calls, 1);
      for (int i = 0; i < 20; i++) {
        r.monitor.onVerifiedAttempt(_wrong());
      }
      expect(r.monitor.status.droppedEvents, 13,
          reason: 'one slot held by the single snapshot; 7 records accepted');
      r.db.release();
      final List<SecurityTimelineSnapshot> snaps = await Future.wait(loads);
      await r.monitor.idle();
      await r.journal.idle();
      expect(snaps, hasLength(1000));
      expect(r.monitor.maxInFlight, 1);
      expect(r.journal.maxInFlight, 1);
      expect(r.monitor.calls, 2, reason: '1,000 requests -> 2 loads');
      final IntruderFailureLog log = (await r.monitor.snapshot())!;
      expect(log.nextSeq + r.monitor.status.droppedEvents, 20);
      for (final SecurityTimelineSnapshot s in snaps) {
        expect(s.confirmedEmpty, isFalse);
        expect(s.hasGaps, isTrue);
      }
    });

    test(
        'journal side: 500 loads with journal storage stalled hold exactly '
        'ONE journal slot (3 of 4 records accepted)', () async {
      final _Rig r = _Rig(journalMaxPending: 4);
      r.db.arm();
      r.db.gatedReads.add(_jKey); // fresh journal: its first read stalls
      r.db.gatedWrites.add(_jKey);
      final List<Future<SecurityTimelineSnapshot>> loads =
          <Future<SecurityTimelineSnapshot>>[
        for (int i = 0; i < 500; i++) r.reader.load(),
      ];
      await r.monitor.idle();
      await pumpEventQueue();
      expect(r.journal.inFlight, 1);
      expect(r.journal.calls, 1);
      for (int i = 0; i < 10; i++) {
        r.journal.record(SecurityJournalEventType.journalRecovered);
      }
      expect(r.journal.pendingLost, 7,
          reason: 'one slot held by the single timeline read');
      r.db.release();
      await Future.wait(loads);
      await r.journal.idle();
      expect(r.journal.maxInFlight, 1);
      expect(r.journal.calls, 2, reason: '500 requests -> 2 loads');
    });
  });

  group('R-P13M1-1 decisions unaffected (real container)', () {
    String describe(AuthAttemptResult? r) => switch (r) {
          AuthSuccess() => 'success',
          AuthFailure(
            :final AuthFailureReason reason,
            :final int? remainingAttempts
          ) =>
            'failure:${reason.name}:$remainingAttempts',
          AuthLockedOut(:final int? attemptsMade) => 'locked:$attemptsMade',
          _ => 'other:${r.runtimeType}',
        };

    Future<List<String>> run({
      required bool stallMonitor,
      required bool timelineReads,
    }) async {
      final _GateDb db = _GateDb();
      final AppContainer c = AppContainer.inMemory(
        intruderEvidence: StaticIntruderEvidenceService(),
        database: db,
      );
      await c.intruderStartup;
      await c.securityJournalStartup;
      await c.auth.enrollPin(_pin);
      if (stallMonitor) {
        db.arm();
        db.gatedWrites.add(_logKey);
      }
      final List<String> out = <String>[];
      final List<Future<SecurityTimelineSnapshot>> loads =
          <Future<SecurityTimelineSnapshot>>[];
      for (final String attempt in <String>[
        '000000',
        '000000',
        _pin,
        '000000',
        '000000',
        '000000',
        _pin,
      ]) {
        if (timelineReads) {
          for (int i = 0; i < 5; i++) {
            loads.add(c.securityTimeline.load());
          }
        }
        out.add(describe((await c.auth.authenticatePin(attempt)).valueOrNull));
      }
      final CredentialState s = (await c.auth.status()).valueOrNull!;
      out.add('failed=${s.failedAttempts} streak=${s.lockoutStreak} '
          'locked=${s.lockedOutUntil != null}');
      db.release();
      await Future.wait(loads);
      await c.intruderMonitor.idle();
      final IntruderFailureLog log = (await c.intruderMonitor.snapshot())!;
      out.add('recorded+dropped='
          '${log.nextSeq + c.intruderMonitor.status.droppedEvents}');
      return out;
    }

    test(
        'unlock and lockout outcomes are identical with and without '
        'concurrent timeline reads and a stalled failure log', () async {
      final List<String> baseline =
          await run(stallMonitor: false, timelineReads: false);
      expect(baseline.first, startsWith('failure:'));
      expect(baseline[2], 'success');
      expect(baseline[5], startsWith('locked:'));
      expect(baseline.last, 'recorded+dropped=5');
      expect(await run(stallMonitor: true, timelineReads: false), baseline);
      expect(await run(stallMonitor: false, timelineReads: true), baseline);
      expect(await run(stallMonitor: true, timelineReads: true), baseline);
    });
  });
}

extension on _Rig {
  int failuresOf(SecurityTimelineSnapshot s) => failures(s);
}
