// Phase 12 / Milestone 1 — Intruder Defense foundation.
//
// Observe-only consumer of the credential manager's verified attempts:
// records failed PIN / pattern verifications and tracks the consecutive
// failure run. It has NO path back into enforcement — nothing in the
// protection engine, the access controller, the lock host or native reads
// it, and it imports none of them.
//
// Concurrency: [onVerifiedAttempt] is synchronous and only enqueues; all
// storage work runs one operation at a time on the monitor's own chain, in
// verdict order. The credential manager never waits for it.
//
// P-1 (Phase 13): three kinds of queued operation with separate budgets —
//  * failure records: the ONLY operations counted against [maxPending];
//    overflow is counted in [IntruderMonitorStatus.droppedFailureRecords];
//  * owner-success resets: never dropped. A verified success is an
//    in-memory INTENT (`_ownerEpoch`). At most one reset operation is
//    waiting in the queue at any time; its target epoch is fixed when it is
//    queued and may only be raised while it is still the queue tail, so a
//    reset can never be applied ahead of a failure verified before that
//    success. Every later persisted failure also applies a pending intent
//    inline (run restarts at 1), so a reset lost to a storage fault is
//    repaired by the next record. A reset that was never persisted does NOT
//    survive process death (accepted residual Q-P1-1);
//  * read-only snapshots: never counted against [maxPending]; a snapshot
//    joins the queue tail when the tail is a not-yet-started snapshot
//    (order-preserving), and outstanding snapshot callers are capped at
//    [maxSnapshotWaiters] (excess callers get `null` = unavailable).
import 'dart:async';
import 'dart:collection';

import '../credentials/auth_result.dart';
import '../credentials/auth_type.dart';
import '../credentials/verified_attempt.dart';
import 'failed_attempt_event.dart';
import 'intruder_failure_log_store.dart';

enum IntruderMonitorHealth {
  /// Recording normally.
  ok,

  /// The last storage operation failed; the next operation retries.
  storageError,

  /// Stored log is from a newer schema or cannot be decrypted without a
  /// cipher: kept untouched, nothing is recorded (read-only).
  readOnly,
}

/// Phase 12 / M2: observe-only listener for evidence and the alarm.
///
/// [onFailedAttemptRecorded] is called ONLY after an event was persisted
/// (never for dropped, duplicate or blocked attempts) and only if no owner
/// success was verified after that failure. [onOwnerVerified] is
/// called synchronously for a verified, persisted success. Listener
/// exceptions are swallowed; the listener can never affect the monitor or
/// authentication.
abstract interface class IntruderEventListener {
  void onFailedAttemptRecorded(FailedAttemptEvent event);

  void onOwnerVerified();
}

/// Redacted diagnostics: counts and health only — no packages, no times.
final class IntruderMonitorStatus {
  const IntruderMonitorStatus({
    required this.health,
    required this.droppedFailureRecords,
    required this.quarantinedCorruptLog,
    this.resetFailures = 0,
    this.resetPending = false,
    this.snapshotsRejected = 0,
  });

  final IntruderMonitorHealth health;

  /// Failed attempts that could not be recorded (record queue overflow,
  /// storage failure, read-only / unreadable log). Owner-success resets are
  /// NEVER counted here (P-1).
  final int droppedFailureRecords;

  /// Alias of [droppedFailureRecords] (Phase 12 / M1 name; the timeline's
  /// "could not be recorded" notice reads it).
  int get droppedEvents => droppedFailureRecords;

  /// Storage failures while persisting an owner-success reset. The reset
  /// intent is kept and applied by the next persisted record or reset.
  final int resetFailures;

  /// A verified owner success is not yet reflected in the persisted run
  /// counter (reset queued, failed, or the log is unreadable / read-only).
  final bool resetPending;

  /// Snapshot calls refused because [IntruderMonitor.maxSnapshotWaiters]
  /// callers were already waiting (they received `null` = unavailable).
  final int snapshotsRejected;

  /// Whether a corrupt stored log was quarantined by this instance.
  final bool quarantinedCorruptLog;
}

class IntruderMonitor implements VerifiedAttemptObserver {
  IntruderMonitor({
    required IntruderFailureLogStore store,
    DateTime Function()? now,
    this.maxEvents = defaultMaxEvents,
    this.retention = defaultRetention,
    this.maxPending = defaultMaxPending,
    this.maxEncodedBytes = defaultMaxEncodedBytes,
    this.maxSnapshotWaiters = defaultMaxSnapshotWaiters,
  })  : _store = store,
        _now = now ?? DateTime.now;

  static const int defaultMaxEvents = 100;
  static const Duration defaultRetention = Duration(days: 30);
  static const int defaultMaxPending = 64;
  static const int defaultMaxEncodedBytes = 64 * 1024;
  static const int defaultMaxSnapshotWaiters = 64;
  static const int _seenIdsCapacity = 256;

  final IntruderFailureLogStore _store;

  /// Phase 12 / M2 evidence + alarm listener (observe-only; may be null).
  IntruderEventListener? listener;

  /// Phase 12 / M2 gate B: bumped SYNCHRONOUSLY by every verified owner
  /// success. A failure verified before a later owner success is still
  /// logged (M1 unchanged) but is not reported to [listener]: it is
  /// superseded, so it can never start evidence or an alarm against the
  /// owner who has since unlocked.
  int _ownerEpoch = 0;

  void _notify(void Function(IntruderEventListener l) call) {
    final IntruderEventListener? l = listener;
    if (l == null) return;
    try {
      call(l);
    } catch (_) {
      // A failing listener never affects the log or authentication.
    }
  }

  final DateTime Function() _now;
  final int maxEvents;
  final Duration retention;
  final int maxPending;
  final int maxEncodedBytes;

  /// Upper bound on snapshot callers waiting at the same time (P-1).
  final int maxSnapshotWaiters;

  // Zone-safe serial queue (see [_drain]): no future is shared between
  // callers, so a caller in one zone can never stall on another's. The
  // queue's LAST element has never started (started ops are removed).
  final Queue<_Op> _queue = Queue<_Op>();
  final List<Completer<void>> _idleWaiters = <Completer<void>>[];
  bool _draining = false;

  /// Failure records queued or running — the only count checked against
  /// [maxPending].
  int _pendingRecords = 0;

  // P-1 reset intent.
  int _appliedResetEpoch = 0; // highest owner epoch reflected in the run
  _ResetOp? _queuedReset; // the (at most one) reset op not yet started
  bool _resetDeferred = false; // success seen while _queuedReset not tail
  int _resetFailures = 0;

  // P-1 snapshot accounting.
  int _snapshotWaiters = 0;
  int _snapshotsRejected = 0;

  // P-1 diagnostics (counts only): live ops of each kind (queued or
  // running) and their high-water marks.
  int _liveReadOps = 0;
  int _liveResetOps = 0;
  int _peakReadOps = 0;
  int _peakResetOps = 0;
  int _peakSnapshotWaiters = 0;
  IntruderFailureLog? _cache;
  bool _readOnly = false;
  bool _storageError = false;
  bool _quarantined = false;
  int _dropped = 0;
  final LinkedHashSet<String> _seenIds = LinkedHashSet<String>();

  IntruderMonitorStatus get status => IntruderMonitorStatus(
        health: _readOnly
            ? IntruderMonitorHealth.readOnly
            : _storageError
                ? IntruderMonitorHealth.storageError
                : IntruderMonitorHealth.ok,
        droppedFailureRecords: _dropped,
        quarantinedCorruptLog: _quarantined,
        resetFailures: _resetFailures,
        resetPending: _appliedResetEpoch < _ownerEpoch,
        snapshotsRejected: _snapshotsRejected,
      );

  /// Diagnostics (P-1 bounds): snapshot ops queued or running.
  int get liveReadOps => _liveReadOps;

  /// Diagnostics (P-1 bounds): reset ops queued or running (always <= 2:
  /// at most one waiting + one running).
  int get liveResetOps => _liveResetOps;

  /// Diagnostics: failure records queued or running (<= [maxPending]).
  int get pendingRecords => _pendingRecords;

  /// Diagnostics: snapshot callers currently waiting
  /// (<= [maxSnapshotWaiters]).
  int get snapshotWaiters => _snapshotWaiters;

  int get peakReadOps => _peakReadOps;
  int get peakResetOps => _peakResetOps;
  int get peakSnapshotWaiters => _peakSnapshotWaiters;

  /// Completes when the queue is empty (every enqueued operation finished).
  Future<void> idle() {
    if (!_draining && _queue.isEmpty) {
      return Future<void>.value();
    }
    final Completer<void> waiter = Completer<void>();
    _idleWaiters.add(waiter);
    return waiter.future;
  }

  /// The current log, read in queue order (null when unreadable/read-only
  /// and nothing valid is known). For M2 / M3 / Phase 13 readers and tests.
  ///
  /// P-1: never consumes failure-record capacity. Joins the queue tail when
  /// the tail is a snapshot that has not started (no operation was queued
  /// after it, so the result is the same). At most [maxSnapshotWaiters]
  /// callers wait at once; beyond that the caller gets `null` immediately
  /// (unavailable — never "empty") and [IntruderMonitorStatus
  /// .snapshotsRejected] counts it.
  Future<IntruderFailureLog?> snapshot() {
    final Completer<IntruderFailureLog?> out = Completer<IntruderFailureLog?>();
    if (_snapshotWaiters >= maxSnapshotWaiters) {
      _snapshotsRejected++;
      out.complete(null);
      return out.future;
    }
    _snapshotWaiters++;
    if (_snapshotWaiters > _peakSnapshotWaiters) {
      _peakSnapshotWaiters = _snapshotWaiters;
    }
    final _Op? tail = _queue.isEmpty ? null : _queue.last;
    if (tail is _ReadOp) {
      tail.waiters.add(out);
    } else {
      _liveReadOps++;
      if (_liveReadOps > _peakReadOps) _peakReadOps = _liveReadOps;
      _queue.add(_ReadOp()..waiters.add(out));
      _kick();
    }
    return out.future;
  }

  @override
  void onVerifiedAttempt(VerifiedAttempt attempt) {
    final AuthAttemptResult result = attempt.result;
    if (result is AuthSuccess) {
      // A verified, persisted success proves the owner: the run resets.
      // (An unpersisted success is returned as a failure — no access.)
      if (attempt.counterPersisted) {
        _ownerEpoch++;
        _notify((IntruderEventListener l) => l.onOwnerVerified());
        _scheduleReset();
      }
      return;
    }
    final FailedAttemptMethod? method = switch (attempt.type) {
      AuthType.pin => FailedAttemptMethod.pin,
      AuthType.pattern => FailedAttemptMethod.pattern,
      AuthType.biometric => null,
    };
    final bool countedFailure = !attempt.matched &&
        ((result is AuthFailure &&
                result.reason == AuthFailureReason.wrongCredential) ||
            (result is AuthLockedOut && result.attemptsMade != null));
    if (method == null || !countedFailure) {
      return; // biometric, lockout-blocked, or not a counted failure
    }
    final int ownerEpoch = _ownerEpoch;
    _enqueueRecord(() => _record(attempt, method, result, ownerEpoch));
  }

  // -- queue ----------------------------------------------------------------

  void _enqueueRecord(Future<void> Function() run) {
    if (_pendingRecords >= maxPending) {
      _dropped++;
      return;
    }
    _pendingRecords++;
    _queue.add(_RecordOp(run));
    _kick();
  }

  /// P-1: never drops. Raises the waiting reset's target only while it is
  /// the queue tail; otherwise defers to a fresh reset appended when the
  /// waiting one runs (after every operation queued before this success).
  void _scheduleReset() {
    final _ResetOp? waiting = _queuedReset;
    if (waiting == null) {
      _appendReset();
    } else if (identical(_queue.last, waiting)) {
      waiting.target = _ownerEpoch;
    } else {
      _resetDeferred = true;
    }
  }

  void _appendReset() {
    final _ResetOp op = _ResetOp(_ownerEpoch);
    _queuedReset = op;
    _liveResetOps++;
    if (_liveResetOps > _peakResetOps) _peakResetOps = _liveResetOps;
    _queue.add(op);
    _kick();
  }

  void _kick() {
    if (!_draining) {
      unawaited(_drain());
    }
  }

  /// Runs queued operations one at a time, in order. Never throws.
  Future<void> _drain() async {
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final _Op op = _queue.removeFirst();
        try {
          switch (op) {
            case _RecordOp(:final Future<void> Function() run):
              await run();
            case _ResetOp():
              await _runReset(op);
            case _ReadOp():
              await _runRead(op);
          }
        } catch (_) {
          // Never escapes: a monitor failure must not surface anywhere.
          _cache = null;
          _storageError = true;
        } finally {
          switch (op) {
            case _RecordOp():
              _pendingRecords--;
            case _ResetOp():
              _liveResetOps--;
            case _ReadOp():
              _liveReadOps--;
          }
        }
      }
    } finally {
      _draining = false;
      final List<Completer<void>> waiters =
          List<Completer<void>>.of(_idleWaiters);
      _idleWaiters.clear();
      for (final Completer<void> w in waiters) {
        w.complete();
      }
    }
  }

  // -- operations -----------------------------------------------------------

  Future<IntruderFailureLog?> _ensureLoaded() async {
    final IntruderFailureLog? cached = _cache;
    if (cached != null) {
      return cached;
    }
    if (_readOnly) {
      return null;
    }
    final IntruderLogRead read = await _store.read();
    switch (read) {
      case IntruderLogLoaded(:final IntruderFailureLog log):
        _cache = log;
        return log;
      case IntruderLogMissing():
        _cache = IntruderFailureLog.empty;
        return _cache;
      case IntruderLogCorrupt(:final String raw):
        // Preserve the damaged value once, then start a fresh v1 log.
        try {
          await _store.quarantine(raw);
          _quarantined = true;
        } catch (_) {
          // Quarantine is best effort; reinitialization still proceeds.
        }
        _cache = IntruderFailureLog.empty;
        return _cache;
      case IntruderLogUnsupported():
        _readOnly = true;
        return null;
      case IntruderLogUnreadable(:final bool permanent):
        if (permanent) {
          _readOnly = true;
        } else {
          _storageError = true;
        }
        return null;
    }
  }

  Future<void> _runRead(_ReadOp op) async {
    final IntruderFailureLog? log;
    try {
      log = await _ensureLoaded();
    } catch (_) {
      _completeReaders(op, null);
      rethrow;
    }
    _completeReaders(op, log);
  }

  void _completeReaders(_ReadOp op, IntruderFailureLog? log) {
    for (final Completer<IntruderFailureLog?> w in op.waiters) {
      _snapshotWaiters--;
      w.complete(log);
    }
    op.waiters.clear();
  }

  /// Applies the owner-success intent up to [op]'s target. A failed or
  /// impossible reset keeps the intent (never silently dropped) and is NOT
  /// retried in a loop: the next persisted record applies it inline, and
  /// the next owner success queues a fresh reset.
  Future<void> _runReset(_ResetOp op) async {
    if (identical(_queuedReset, op)) _queuedReset = null;
    final int target = op.target;
    try {
      if (_appliedResetEpoch >= target) {
        return; // already applied inline by a later record
      }
      final IntruderFailureLog? log = await _ensureLoaded();
      if (log == null) {
        return; // unreadable / read-only: intent kept (resetPending)
      }
      if (log.consecutiveFailures == 0) {
        _appliedResetEpoch = target; // nothing to write
        return;
      }
      final bool saved = await _save(
        IntruderFailureLog(
          nextSeq: log.nextSeq,
          consecutiveFailures: 0,
          events: log.events,
        ),
      );
      if (saved) {
        _appliedResetEpoch = target;
      } else {
        _resetFailures++;
      }
    } finally {
      if (_resetDeferred) {
        _resetDeferred = false;
        // A reset appended after [op] started already sits after every
        // operation queued before the deferred success and targets a newer
        // epoch; otherwise append one now.
        if (_queuedReset == null) _appendReset();
      }
    }
  }

  Future<void> _record(
    VerifiedAttempt attempt,
    FailedAttemptMethod method,
    AuthAttemptResult result,
    int ownerEpoch,
  ) async {
    final IntruderFailureLog? log = await _ensureLoaded();
    if (log == null) {
      _dropped++;
      return;
    }
    final String vid = attempt.verificationId;
    if (_seenIds.contains(vid) ||
        log.events.any((FailedAttemptEvent e) => e.verificationId == vid)) {
      return; // duplicate delivery: already recorded
    }
    // P-1: an owner success verified before this failure but not yet
    // reflected in the persisted run restarts the run here.
    final bool resetFirst = ownerEpoch > _appliedResetEpoch;
    final int base = resetFirst ? 0 : log.consecutiveFailures;
    final int run = base >= IntruderFailureLog.maxRun
        ? IntruderFailureLog.maxRun
        : base + 1;
    final AuthAttemptContext context = attempt.context;
    final bool challenge =
        context.surface == AuthAttemptSurface.protectedAppChallenge;
    final FailedAttemptEvent event = FailedAttemptEvent(
      seq: log.nextSeq,
      verificationId: vid,
      at: attempt.at,
      method: method,
      surface: context.surface,
      packageName: challenge ? context.packageName : null,
      generation: challenge ? context.generation : null,
      challengeSerial: challenge ? context.challengeSerial : null,
      consecutiveFailures: run,
      lockoutTriggered: result is AuthLockedOut,
      lockoutStreak: attempt.lockoutStreak,
      counterPersisted: attempt.counterPersisted,
    );
    final bool saved = await _save(
      IntruderFailureLog(
        nextSeq: log.nextSeq + 1,
        consecutiveFailures: run,
        events: _bounded(<FailedAttemptEvent>[...log.events, event]),
      ),
    );
    if (saved) {
      if (resetFirst) _appliedResetEpoch = ownerEpoch;
      if (ownerEpoch == _ownerEpoch) {
        _notify((IntruderEventListener l) => l.onFailedAttemptRecorded(event));
      }
      _seenIds.add(vid);
      while (_seenIds.length > _seenIdsCapacity) {
        _seenIds.remove(_seenIds.first);
      }
    } else {
      _dropped++;
    }
  }

  /// Retention (age, future-dated kept), capacity, then encoded-size bound.
  List<FailedAttemptEvent> _bounded(List<FailedAttemptEvent> events) {
    final DateTime cutoff = _now().subtract(retention);
    List<FailedAttemptEvent> kept =
        events.where((FailedAttemptEvent e) => !e.at.isBefore(cutoff)).toList();
    if (kept.length > maxEvents) {
      kept = kept.sublist(kept.length - maxEvents);
    }
    while (kept.isNotEmpty &&
        IntruderFailureLogStore.encode(
              IntruderFailureLog(
                nextSeq: 0,
                consecutiveFailures: 0,
                events: kept,
              ),
            ).length >
            maxEncodedBytes) {
      kept = kept.sublist(1);
    }
    return List<FailedAttemptEvent>.unmodifiable(kept);
  }

  Future<bool> _save(IntruderFailureLog next) async {
    try {
      await _store.write(next);
      _cache = next;
      _storageError = false;
      return true;
    } catch (_) {
      // The previous row is intact; reload from storage next time.
      _cache = null;
      _storageError = true;
      return false;
    }
  }
}

// -- queued operations (P-1) --------------------------------------------------

sealed class _Op {}

final class _RecordOp extends _Op {
  _RecordOp(this.run);

  final Future<void> Function() run;
}

final class _ResetOp extends _Op {
  _ResetOp(this.target);

  /// Owner epoch this reset brings the persisted run up to. Fixed when
  /// queued; raised only while this op is the queue tail.
  int target;
}

final class _ReadOp extends _Op {
  final List<Completer<IntruderFailureLog?>> waiters =
      <Completer<IntruderFailureLog?>>[];
}
