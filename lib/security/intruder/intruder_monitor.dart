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
    required this.droppedEvents,
    required this.quarantinedCorruptLog,
  });

  final IntruderMonitorHealth health;

  /// Failed attempts that could not be recorded (queue overflow, storage
  /// failure, read-only log).
  final int droppedEvents;

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
  })  : _store = store,
        _now = now ?? DateTime.now;

  static const int defaultMaxEvents = 100;
  static const Duration defaultRetention = Duration(days: 30);
  static const int defaultMaxPending = 64;
  static const int defaultMaxEncodedBytes = 64 * 1024;
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

  // Zone-safe serial queue (see [_drain]): no future is shared between
  // callers, so a caller in one zone can never stall on another's.
  final Queue<Future<void> Function()> _queue =
      Queue<Future<void> Function()>();
  final List<Completer<void>> _idleWaiters = <Completer<void>>[];
  bool _draining = false;
  int _pending = 0;
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
        droppedEvents: _dropped,
        quarantinedCorruptLog: _quarantined,
      );

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
  Future<IntruderFailureLog?> snapshot() {
    final Completer<IntruderFailureLog?> out = Completer<IntruderFailureLog?>();
    _enqueue(
      () async {
        try {
          out.complete(await _ensureLoaded());
        } catch (_) {
          out.complete(null);
          rethrow;
        }
      },
      force: true,
    );
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
        _enqueue(_resetRun);
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
    _enqueue(() => _record(attempt, method, result, ownerEpoch));
  }

  // -- queue ----------------------------------------------------------------

  void _enqueue(Future<void> Function() op, {bool force = false}) {
    if (!force && _pending >= maxPending) {
      _dropped++;
      return;
    }
    _pending++;
    _queue.add(op);
    if (!_draining) {
      unawaited(_drain());
    }
  }

  /// Runs queued operations one at a time, in order. Never throws.
  Future<void> _drain() async {
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final Future<void> Function() op = _queue.removeFirst();
        try {
          await op();
        } catch (_) {
          // Never escapes: a monitor failure must not surface anywhere.
          _cache = null;
          _storageError = true;
        } finally {
          _pending--;
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

  Future<void> _resetRun() async {
    final IntruderFailureLog? log = await _ensureLoaded();
    if (log == null || log.consecutiveFailures == 0) {
      return;
    }
    await _save(
      IntruderFailureLog(
        nextSeq: log.nextSeq,
        consecutiveFailures: 0,
        events: log.events,
      ),
    );
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
    final int run = log.consecutiveFailures >= IntruderFailureLog.maxRun
        ? IntruderFailureLog.maxRun
        : log.consecutiveFailures + 1;
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
