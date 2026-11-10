// Phase 13 / Milestone 1 — Security Event Database: record + document.
//
// Pure data and a STRICT v1 codec. Any new event type or field requires a
// new document version (v2+): an older build then reads the newer journal
// as "unsupported" (read-only, never overwritten) instead of "corrupt".
//
// Privacy (TL-4 / correction F): anomalies only. There is deliberately no
// type for successful unlocks or routine usage, and no field may carry
// credential material, pixels or free-form text.

/// Journal event types. Wire names are the enum names.
enum SecurityJournalEventType {
  /// The journal row was created by its FIRST USE (lazy creation): no
  /// journal event was recorded before this time. This is never an install,
  /// upgrade or app-start time and must not be presented as one.
  journalStarted,

  /// A damaged journal row was quarantined and replaced: earlier journal
  /// history may be missing.
  journalRecovered,
}

final class SecurityJournalEvent {
  const SecurityJournalEvent({
    required this.seq,
    required this.at,
    required this.type,
  });

  /// Strictly increasing per journal (tie-break for equal wall times).
  final int seq;

  /// Wall-clock time the app OBSERVED the event ("detected at").
  final DateTime at;

  final SecurityJournalEventType type;

  Map<String, Object?> toJson() => <String, Object?>{
        'seq': seq,
        'at': at.millisecondsSinceEpoch,
        'type': type.name,
      };

  static const Set<String> _keys = <String>{'seq', 'at', 'type'};

  /// Strict decoder: throws [FormatException] on anything unexpected.
  static SecurityJournalEvent fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('event is not an object');
    }
    for (final Object? k in raw.keys) {
      if (k is! String || !_keys.contains(k)) {
        throw const FormatException('event has an unknown field');
      }
    }
    final Object? seq = raw['seq'];
    final Object? at = raw['at'];
    final Object? type = raw['type'];
    if (seq is! int || seq < 0 || at is! int || at < 0 || type is! String) {
      throw const FormatException('event field invalid');
    }
    SecurityJournalEventType? t;
    for (final SecurityJournalEventType v in SecurityJournalEventType.values) {
      if (v.name == type) {
        t = v;
        break;
      }
    }
    if (t == null) {
      throw const FormatException('event type unknown');
    }
    return SecurityJournalEvent(
      seq: seq,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      type: t,
    );
  }
}

/// The whole journal (one encrypted settings row).
final class SecurityJournalDocument {
  const SecurityJournalDocument({
    required this.nextSeq,
    required this.discarded,
    required this.lost,
    required this.events,
  });

  static const String schema = 'sal.security_journal';
  static const int version = 1;

  /// Decoder hard limit (well above the retention cap).
  static const int maxDecodableEvents = 1000;

  /// Saturation bound for counters (never overflows).
  static const int maxCounter = 0x7fffffff;

  static const SecurityJournalDocument empty = SecurityJournalDocument(
    nextSeq: 0,
    discarded: 0,
    lost: 0,
    events: <SecurityJournalEvent>[],
  );

  /// Sequence the next event receives.
  final int nextSeq;

  /// Events removed by retention / count cap / size cap (cumulative).
  final int discarded;

  /// Events that could never be stored (queue overflow, failures).
  final int lost;

  /// Oldest first, strictly increasing seq.
  final List<SecurityJournalEvent> events;

  static int saturatingAdd(int a, int b) {
    final int s = a + b;
    return s > maxCounter || s < 0 ? maxCounter : s;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'schema': schema,
        'v': version,
        'nextSeq': nextSeq,
        'discarded': discarded,
        'lost': lost,
        'events': <Object?>[
          for (final SecurityJournalEvent e in events) e.toJson(),
        ],
      };

  /// Reads only the declared version (null when absent or not an int).
  static int? declaredVersion(Object? raw) {
    if (raw is Map && raw['v'] is int) {
      return raw['v'] as int;
    }
    return null;
  }

  static const Set<String> _keys = <String>{
    'schema',
    'v',
    'nextSeq',
    'discarded',
    'lost',
    'events',
  };

  /// Strict v1 decoder: throws [FormatException] on any invalid content.
  static SecurityJournalDocument fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('journal is not an object');
    }
    if (raw['schema'] != schema || raw['v'] != version) {
      throw const FormatException('journal schema/version mismatch');
    }
    for (final Object? k in raw.keys) {
      if (k is! String || !_keys.contains(k)) {
        throw const FormatException('journal has an unknown field');
      }
    }
    final Object? nextSeq = raw['nextSeq'];
    final Object? discarded = raw['discarded'];
    final Object? lost = raw['lost'];
    final Object? list = raw['events'];
    if (nextSeq is! int ||
        nextSeq < 0 ||
        discarded is! int ||
        discarded < 0 ||
        discarded > maxCounter ||
        lost is! int ||
        lost < 0 ||
        lost > maxCounter ||
        list is! List ||
        list.length > maxDecodableEvents) {
      throw const FormatException('journal header invalid');
    }
    final List<SecurityJournalEvent> events = <SecurityJournalEvent>[];
    int lastSeq = -1;
    for (final Object? item in list) {
      final SecurityJournalEvent e = SecurityJournalEvent.fromJson(item);
      if (e.seq <= lastSeq || e.seq >= nextSeq) {
        throw const FormatException('journal sequence invalid');
      }
      lastSeq = e.seq;
      events.add(e);
    }
    return SecurityJournalDocument(
      nextSeq: nextSeq,
      discarded: discarded,
      lost: lost,
      events: List<SecurityJournalEvent>.unmodifiable(events),
    );
  }
}
