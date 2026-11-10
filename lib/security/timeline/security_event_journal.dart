// Phase 13 / Milestone 1 — Security Event Database.
//
// Local, encrypted, bounded, versioned journal of security ANOMALIES that
// are not already persisted elsewhere (failed unlocks stay in the Phase 12
// failure log — never duplicated here).
//
// Isolation (corrections A/B): nothing in enforcement imports or awaits
// this class. [record] is synchronous, only enqueues, and never throws;
// every storage operation runs one at a time on the journal's own chain and
// any failure is contained (counted as lost / reported as health).
import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'security_event_journal_store.dart';
import 'security_journal_event.dart';

/// Producer-facing interface (M2+ producers depend on this, never on the
/// concrete journal).
abstract interface class SecurityEventSink {
  /// Must be synchronous, non-blocking and must never throw.
  void record(SecurityJournalEventType type);
}

/// The ONLY way producers may call a sink: even a sink that violates its
/// contract and throws synchronously cannot propagate into the caller.
void recordSecurityEventSafely(
  SecurityEventSink? sink,
  SecurityJournalEventType type,
) {
  if (sink == null) {
    return;
  }
  try {
    sink.record(type);
  } catch (_) {
    // Journal failures never affect the producer (correction A).
  }
}

enum SecurityJournalHealth {
  /// Recording normally.
  ok,

  /// The last storage operation failed; the next operation retries.
  storageError,

  /// Newer schema or ciphertext without a cipher: kept untouched, nothing
  /// is written for the process lifetime.
  readOnly,
}

enum SecurityJournalAvailability {
  available,

  /// Written by a newer app version (never overwritten).
  unsupported,

  /// Could not be read now (storage error) or can never be read here.
  unreadable,
}

/// Read result for the timeline. Never contains raw stored data.
final class SecurityJournalView {
  const SecurityJournalView({
    required this.availability,
    required this.events,
    required this.discarded,
    required this.lost,
  });

  final SecurityJournalAvailability availability;

  /// Oldest first (empty unless [availability] is available).
  final List<SecurityJournalEvent> events;

  /// Removed by retention / caps (persisted, cumulative).
  final int discarded;

  /// Never stored: persisted count plus this session's not-yet-persisted
  /// losses.
  final int lost;
}

class SecurityEventJournal implements SecurityEventSink {
  SecurityEventJournal({
    required SecurityEventJournalStore store,
    DateTime Function()? now,
    this.maxEvents = defaultMaxEvents,
    this.retention = defaultRetention,
    this.maxPending = defaultMaxPending,
    this.maxEncodedBytes = defaultMaxEncodedBytes,
  })  : _store = store,
        _now = now ?? DateTime.now;

  static const int defaultMaxEvents = 200;
  static const Duration defaultRetention = Duration(days: 30);
  static const int defaultMaxPending = 64;
  static const int defaultMaxEncodedBytes = 64 * 1024;

  final SecurityEventJournalStore _store;
  final DateTime Function() _now;
  final int maxEvents;
  final Duration retention;
  final int maxPending;
  final int maxEncodedBytes;

  final Queue<Future<void> Function()> _queue =
      Queue<Future<void> Function()>();
  final List<Completer<void>> _idleWaiters = <Completer<void>>[];
  int _pending = 0;
  bool _draining = false;

  SecurityJournalDocument? _cache;
  bool _readOnly = false;
  bool _storageError = false;
  bool _quarantined = false;
  bool _unsupported = false;

  /// Losses not yet added to the persisted `lost` counter.
  int _pendingLost = 0;

  SecurityJournalHealth get health => _readOnly
      ? SecurityJournalHealth.readOnly
      : _storageError
          ? SecurityJournalHealth.storageError
          : SecurityJournalHealth.ok;

  /// Whether this instance quarantined a corrupt journal row.
  bool get quarantinedCorruptJournal => _quarantined;

  /// This session's losses not yet persisted.
  int get pendingLost => _pendingLost;

  // -- public API -----------------------------------------------------------

  @override
  void record(SecurityJournalEventType type) {
    try {
      final DateTime at = _now(); // "detected at" = when it was observed
      if (_pending >= maxPending) {
        _addLost(1);
        return;
      }
      _enqueue(() => _append(type, at));
    } catch (_) {
      _addLost(1);
    }
  }

  /// Startup maintenance: load, quarantine/reinitialize a corrupt row and
  /// apply retention. QUIET by design: a missing journal is NOT created here
  /// (nothing is written at startup unless integrity or retention requires
  /// it); the row and its start marker are created by the first [record] or
  /// [read]. Never throws.
  Future<void> startup() {
    final Completer<void> done = Completer<void>();
    _enqueue(() async {
      try {
        final SecurityJournalDocument? doc =
            await _ensureLoaded(createIfMissing: false);
        if (doc != null) {
          await _persistBounded(doc);
        }
      } finally {
        done.complete();
      }
    });
    return done.future;
  }

  /// Queue-ordered read for the timeline. Never throws.
  Future<SecurityJournalView> read() {
    final Completer<SecurityJournalView> out = Completer<SecurityJournalView>();
    _enqueue(() async {
      try {
        final SecurityJournalDocument? doc = await _ensureLoaded();
        if (doc == null) {
          out.complete(_unavailable());
          return;
        }
        final SecurityJournalDocument shown = await _persistBounded(doc);
        out.complete(SecurityJournalView(
          availability: SecurityJournalAvailability.available,
          events: shown.events,
          discarded: shown.discarded,
          lost: SecurityJournalDocument.saturatingAdd(shown.lost, _pendingLost),
        ));
      } catch (_) {
        out.complete(_unavailable());
        rethrow;
      }
    });
    return out.future;
  }

  /// Completes when the queue is empty.
  Future<void> idle() {
    if (!_draining && _queue.isEmpty) {
      return Future<void>.value();
    }
    final Completer<void> waiter = Completer<void>();
    _idleWaiters.add(waiter);
    return waiter.future;
  }

  // -- queue ----------------------------------------------------------------

  void _enqueue(Future<void> Function() op) {
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

  void _addLost(int n) {
    _pendingLost = SecurityJournalDocument.saturatingAdd(_pendingLost, n);
  }

  SecurityJournalView _unavailable() => SecurityJournalView(
        availability: _unsupported
            ? SecurityJournalAvailability.unsupported
            : SecurityJournalAvailability.unreadable,
        events: const <SecurityJournalEvent>[],
        discarded: 0,
        lost: _pendingLost,
      );

  Future<void> _append(SecurityJournalEventType type, DateTime at) async {
    try {
      final SecurityJournalDocument? doc = await _ensureLoaded();
      if (doc == null) {
        _addLost(1); // read-only: can never be stored by this build
        return;
      }
      await _persistBounded(SecurityJournalDocument(
        nextSeq: doc.nextSeq + 1,
        discarded: doc.discarded,
        lost: doc.lost,
        events: <SecurityJournalEvent>[
          ...doc.events,
          SecurityJournalEvent(seq: doc.nextSeq, at: at, type: type),
        ],
      ));
    } catch (_) {
      _addLost(1);
      rethrow;
    }
  }

  /// Loads the journal once (cached). Returns null when read-only, or when
  /// missing and ![createIfMissing]. Throws on a transient storage failure
  /// (nothing is overwritten).
  Future<SecurityJournalDocument?> _ensureLoaded({
    bool createIfMissing = true,
  }) async {
    if (_readOnly) {
      return null;
    }
    final SecurityJournalDocument? cached = _cache;
    if (cached != null) {
      return cached;
    }
    final SecurityJournalRead r = await _store.read();
    switch (r) {
      case SecurityJournalLoaded(:final SecurityJournalDocument document):
        _cache = document;
        _storageError = false;
        return document;
      case SecurityJournalMissing():
        if (!createIfMissing) {
          return null;
        }
        return _initialize(SecurityJournalEventType.journalStarted);
      case SecurityJournalCorrupt(:final String raw):
        // Quarantine FIRST; if that fails, nothing is overwritten.
        if (await _store.quarantine(raw)) {
          _quarantined = true;
        }
        return _initialize(SecurityJournalEventType.journalRecovered);
      case SecurityJournalUnsupported():
        _readOnly = true;
        _unsupported = true;
        return null;
      case SecurityJournalUnreadable(:final bool permanent):
        if (permanent) {
          _readOnly = true;
          return null;
        }
        throw StateError('security journal unreadable');
    }
  }

  Future<SecurityJournalDocument> _initialize(
    SecurityJournalEventType marker,
  ) async {
    final SecurityJournalDocument doc = SecurityJournalDocument(
      nextSeq: 1,
      discarded: 0,
      lost: 0,
      events: <SecurityJournalEvent>[
        SecurityJournalEvent(seq: 0, at: _now(), type: marker),
      ],
    );
    return _persistBounded(doc, force: true);
  }

  /// Applies retention + caps, folds in pending losses and writes when
  /// anything changed (or [force]). Returns the stored document. Throws on
  /// write failure (cache dropped by the drain).
  Future<SecurityJournalDocument> _persistBounded(
    SecurityJournalDocument doc, {
    bool force = false,
  }) async {
    final int committedLost = _pendingLost;
    final List<SecurityJournalEvent> events =
        List<SecurityJournalEvent>.of(doc.events);
    int dropped = 0;
    // Age retention drops only events OLDER than the cutoff. Events stamped
    // in the future (clock moved backwards) are kept, never purged.
    final DateTime cutoff = _now().subtract(retention);
    final int before = events.length;
    events.removeWhere((SecurityJournalEvent e) => e.at.isBefore(cutoff));
    dropped += before - events.length;
    while (events.length > maxEvents) {
      events.removeAt(0);
      dropped++;
    }
    SecurityJournalDocument next() => SecurityJournalDocument(
          nextSeq: doc.nextSeq,
          discarded:
              SecurityJournalDocument.saturatingAdd(doc.discarded, dropped),
          lost: SecurityJournalDocument.saturatingAdd(doc.lost, committedLost),
          events: List<SecurityJournalEvent>.unmodifiable(events),
        );
    SecurityJournalDocument out = next();
    while (events.isNotEmpty &&
        utf8.encode(SecurityEventJournalStore.encode(out)).length >
            maxEncodedBytes) {
      events.removeAt(0);
      dropped++;
      out = next();
    }
    final bool changed =
        force || dropped > 0 || committedLost > 0 || !identical(doc, _cache);
    if (changed) {
      await _store.write(out);
      _pendingLost -= committedLost;
    }
    _cache = out;
    _storageError = false;
    return out;
  }
}
