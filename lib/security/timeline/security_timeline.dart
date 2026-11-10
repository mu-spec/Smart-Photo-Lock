// Phase 13 / Milestone 1 — chronological read model over the existing
// sources. READ-ONLY (TL-2 / TL-3 / correction E): it never writes the
// failure log, the journal's security state, credential counters, lockout
// state or evidence guards. It only calls read APIs.
//
// Honesty (corrections C / D): an unreadable source is reported as
// unavailable — never as empty — and every known gap (retention / caps,
// unrecorded events, damaged earlier history, unknown integrity) is
// reported per source.
import 'dart:async';

import '../../data/storage/local_database.dart';
import '../credentials/verified_attempt.dart';
import '../intruder/failed_attempt_event.dart';
import '../intruder/intruder_failure_log_store.dart';
import '../intruder/intruder_monitor.dart';
import 'security_event_journal.dart';
import 'security_event_journal_store.dart';
import 'security_journal_event.dart';

/// Source of an entry. The index is the fixed tie-break rank.
enum TimelineSource { failedAttempts, journal }

enum TimelineEntryKind { failedUnlock, journalStarted, journalRecovered }

/// Metadata-only timeline row (no credential material, no pixels).
final class TimelineEntry {
  const TimelineEntry({
    required this.source,
    required this.sourceSeq,
    required this.at,
    required this.kind,
    this.method,
    this.surface,
    this.packageName,
    this.consecutiveFailures,
    this.lockoutTriggered = false,
  });

  final TimelineSource source;
  final int sourceSeq;

  /// When the app observed/recorded the event (wall clock).
  final DateTime at;
  final TimelineEntryKind kind;
  final FailedAttemptMethod? method;
  final AuthAttemptSurface? surface;

  /// Protected app (challenge surface only).
  final String? packageName;
  final int? consecutiveFailures;
  final bool lockoutTriggered;
}

enum TimelineSourceState {
  available,

  /// Written by a newer app version; kept untouched.
  unavailableNewerVersion,

  /// Could not be read.
  unavailableUnreadable,
}

final class TimelineSourceStatus {
  const TimelineSourceStatus({
    required this.source,
    required this.state,
    required this.discarded,
    required this.lost,
    required this.damagedEarlier,
  });

  final TimelineSource source;
  final TimelineSourceState state;

  /// Events no longer kept (retention / count / size caps).
  final int discarded;

  /// Events that were never recorded (overflow / storage failures).
  final int lost;

  /// True: earlier history was damaged and replaced. Null: unknown (the
  /// integrity marker could not be read) — never assumed clean.
  final bool? damagedEarlier;

  bool get available => state == TimelineSourceState.available;
}

final class SecurityTimelineSnapshot {
  const SecurityTimelineSnapshot({
    required this.entries,
    required this.sources,
  });

  /// Newest first; total order (see [SecurityTimelineReader.compare]).
  final List<TimelineEntry> entries;
  final List<TimelineSourceStatus> sources;

  bool get allSourcesAvailable =>
      sources.every((TimelineSourceStatus s) => s.available);

  /// "No events" may only be claimed when every source was read.
  bool get confirmedEmpty => entries.isEmpty && allSourcesAvailable;

  bool get hasGaps => sources.any((TimelineSourceStatus s) =>
      !s.available ||
      s.discarded > 0 ||
      s.lost > 0 ||
      s.damagedEarlier != false);
}

class SecurityTimelineReader {
  SecurityTimelineReader({
    required IntruderMonitor monitor,
    required SecurityEventJournal journal,
    required SecurityEventJournalStore journalStore,
    required LocalDatabase database,
  })  : _monitor = monitor,
        _journal = journal,
        _journalStore = journalStore,
        _database = database;

  static const int pageSize = 50;

  final IntruderMonitor _monitor;
  final SecurityEventJournal _journal;
  final SecurityEventJournalStore _journalStore;
  final LocalDatabase _database;

  /// Newest first: (at desc, source rank desc, sourceSeq desc).
  static int compare(TimelineEntry a, TimelineEntry b) {
    final int byTime = b.at.compareTo(a.at);
    if (byTime != 0) {
      return byTime;
    }
    final int bySource = b.source.index.compareTo(a.source.index);
    if (bySource != 0) {
      return bySource;
    }
    return b.sourceSeq.compareTo(a.sourceSeq);
  }

  // Single-flight (R-P13M1-1): at most ONE timeline load — and therefore at
  // most one forced failure-log snapshot in the monitor queue and one read
  // in the journal queue — is in flight at any time, however often [load]
  // is called (repeated opens, stalled storage). Callers arriving while a
  // load runs join the NEXT load, so every caller receives a snapshot that
  // was started after its own call. Each caller gets its own completer
  // (zone-safe; no future is shared across callers).
  bool _running = false;
  List<Completer<SecurityTimelineSnapshot>> _current =
      <Completer<SecurityTimelineSnapshot>>[];
  List<Completer<SecurityTimelineSnapshot>> _next =
      <Completer<SecurityTimelineSnapshot>>[];

  /// Never throws. Coalesced: see the single-flight note above.
  Future<SecurityTimelineSnapshot> load() {
    final Completer<SecurityTimelineSnapshot> c =
        Completer<SecurityTimelineSnapshot>();
    if (_running) {
      _next.add(c);
    } else {
      _running = true;
      _current = <Completer<SecurityTimelineSnapshot>>[c];
      unawaited(_drive());
    }
    return c.future;
  }

  Future<void> _drive() async {
    while (true) {
      final List<Completer<SecurityTimelineSnapshot>> batch = _current;
      final SecurityTimelineSnapshot snap = await _loadOnce();
      for (final Completer<SecurityTimelineSnapshot> w in batch) {
        w.complete(snap);
      }
      if (_next.isEmpty) {
        _current = <Completer<SecurityTimelineSnapshot>>[];
        _running = false;
        return;
      }
      _current = _next;
      _next = <Completer<SecurityTimelineSnapshot>>[];
    }
  }

  /// One uncoalesced load. Never throws.
  Future<SecurityTimelineSnapshot> _loadOnce() async {
    final List<TimelineEntry> entries = <TimelineEntry>[];
    final TimelineSourceStatus failures = await _loadFailures(entries);
    final TimelineSourceStatus journal = await _loadJournal(entries);
    entries.sort(compare);
    return SecurityTimelineSnapshot(
      entries: List<TimelineEntry>.unmodifiable(entries),
      sources: List<TimelineSourceStatus>.unmodifiable(
          <TimelineSourceStatus>[failures, journal]),
    );
  }

  Future<TimelineSourceStatus> _loadFailures(List<TimelineEntry> out) async {
    IntruderFailureLog? log;
    try {
      log = await _monitor.snapshot();
    } catch (_) {
      log = null;
    }
    final IntruderMonitorStatus status = _monitor.status;
    bool? damaged;
    try {
      damaged = status.quarantinedCorruptLog ||
          await _database.getSetting(IntruderFailureLogStore.quarantineKey) !=
              null;
    } catch (_) {
      damaged = status.quarantinedCorruptLog ? true : null;
    }
    if (log == null) {
      return TimelineSourceStatus(
        source: TimelineSource.failedAttempts,
        state: status.health == IntruderMonitorHealth.readOnly
            ? TimelineSourceState.unavailableNewerVersion
            : TimelineSourceState.unavailableUnreadable,
        discarded: 0,
        lost: status.droppedEvents,
        damagedEarlier: damaged,
      );
    }
    for (final FailedAttemptEvent e in log.events) {
      out.add(TimelineEntry(
        source: TimelineSource.failedAttempts,
        sourceSeq: e.seq,
        at: e.at,
        kind: TimelineEntryKind.failedUnlock,
        method: e.method,
        surface: e.surface,
        packageName: e.surface == AuthAttemptSurface.protectedAppChallenge
            ? e.packageName
            : null,
        consecutiveFailures: e.consecutiveFailures,
        lockoutTriggered: e.lockoutTriggered,
      ));
    }
    final int discarded = log.nextSeq - log.events.length;
    return TimelineSourceStatus(
      source: TimelineSource.failedAttempts,
      state: TimelineSourceState.available,
      discarded: discarded < 0 ? 0 : discarded,
      lost: status.droppedEvents,
      damagedEarlier: damaged,
    );
  }

  Future<TimelineSourceStatus> _loadJournal(List<TimelineEntry> out) async {
    SecurityJournalView view;
    try {
      view = await _journal.read();
    } catch (_) {
      view = const SecurityJournalView(
        availability: SecurityJournalAvailability.unreadable,
        events: <SecurityJournalEvent>[],
        discarded: 0,
        lost: 0,
      );
    }
    bool? damaged;
    try {
      damaged = _journal.quarantinedCorruptJournal ||
          await _journalStore.hasQuarantine();
    } catch (_) {
      damaged = _journal.quarantinedCorruptJournal ? true : null;
    }
    final TimelineSourceState state = switch (view.availability) {
      SecurityJournalAvailability.available => TimelineSourceState.available,
      SecurityJournalAvailability.unsupported =>
        TimelineSourceState.unavailableNewerVersion,
      SecurityJournalAvailability.unreadable =>
        TimelineSourceState.unavailableUnreadable,
    };
    if (state == TimelineSourceState.available) {
      for (final SecurityJournalEvent e in view.events) {
        out.add(TimelineEntry(
          source: TimelineSource.journal,
          sourceSeq: e.seq,
          at: e.at,
          kind: switch (e.type) {
            SecurityJournalEventType.journalStarted =>
              TimelineEntryKind.journalStarted,
            SecurityJournalEventType.journalRecovered =>
              TimelineEntryKind.journalRecovered,
          },
        ));
      }
    }
    return TimelineSourceStatus(
      source: TimelineSource.journal,
      state: state,
      discarded: view.discarded,
      lost: view.lost,
      damagedEarlier: damaged,
    );
  }
}
