// Phase 12 / Milestone 2 — encrypted, bounded, local evidence store.
//
// Layout (existing LocalDatabase settings table — app-private SQLite):
//  * `intruder_evidence_index`        enc JSON {v:1, items:[{seq,at,bytes,pkg}]}
//  * `intruder_evidence_blob_<seq>`   enc base64(JPEG)
// Keys derive ONLY from the integer M1 event seq (no paths, no traversal).
// Write order blob -> index; an orphan blob left by a crash is removed by
// [sweepOrphans]. AES-256-GCM via the Keystore-backed SettingsCipher; a
// cipher is mandatory (no plaintext mode). Metadata segments (EXIF/GPS/
// comments) are stripped before encryption. The M1 log and the credential
// document are never touched.
//
// Phase 12 / Milestone 3 — owner evidence management. The index may carry
// three optional, backward-compatible fields:
//  * `floor` int   — every seq <= floor was cleared by the owner and can
//                    never be saved again (clear-all resurrection guard);
//  * `tomb`  [int] — individually deleted seqs (at most [maxTombstones])
//                    that can never be saved again (delete-vs-late-capture
//                    guard);
//  * `hw`    int   — tombstone compaction high-water mark: every seq <= hw
//                    that is not currently listed is retired. When `tomb`
//                    would exceed its bound, ALL tombstones are folded into
//                    `hw` (never dropped), so no deleted seq is re-opened and
//                    no listed item is affected (listed items are exempt by
//                    definition and may lie below `hw`).
// Retired(s) := s <= floor || s in tomb || (s <= hw && s not listed).
// Deletes are logical-then-physical: the index rewrite is the commit point
// (the item is no longer listed or readable), then the blob row is removed;
// a crash in between leaves an orphan that [sweepOrphans] removes. Rows are
// deleted from SQLite; no secure physical erasure of flash is claimed.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../../data/storage/local_database.dart';
import '../encryption/settings_cipher.dart';

/// One stored image's metadata (no image bytes, no credential material).
final class EvidenceItem {
  const EvidenceItem({
    required this.seq,
    required this.at,
    required this.bytes,
    this.packageName,
  });

  /// The M1 failed-attempt event seq this evidence belongs to.
  final int seq;
  final DateTime at;
  final int bytes;
  final String? packageName;

  Map<String, Object?> toJson() => <String, Object?>{
        'seq': seq,
        'at': at.millisecondsSinceEpoch,
        'bytes': bytes,
        'pkg': packageName,
      };

  static EvidenceItem fromJson(Object? raw) {
    if (raw is! Map ||
        raw['seq'] is! int ||
        raw['at'] is! int ||
        raw['bytes'] is! int ||
        (raw['pkg'] != null && raw['pkg'] is! String) ||
        (raw['seq'] as int) < 0 ||
        (raw['bytes'] as int) <= 0) {
      throw const FormatException('evidence item');
    }
    return EvidenceItem(
      seq: raw['seq'] as int,
      at: DateTime.fromMillisecondsSinceEpoch(raw['at'] as int),
      bytes: raw['bytes'] as int,
      packageName: raw['pkg'] as String?,
    );
  }
}

enum EvidenceSaveResult {
  saved,

  /// The caller's `stillValid` check failed at the commit point (owner
  /// success / consent revoked): nothing was written.
  cancelled,
  duplicate,
  invalidImage,
  oversized,
  unsupportedSchema,
  encryptionFailed,
  storageFailed,

  /// Phase 12 / M3: the seq was deleted or cleared by the owner (tombstone
  /// or clear-all floor). Nothing was written — deleted evidence never
  /// comes back.
  superseded,
}

enum EvidenceIndexHealth { ok, unsupported, unreadable }

/// Phase 12 / M3 — outcome of an owner delete.
enum EvidenceDeleteResult {
  deleted,

  /// Not in the index (already deleted, swept or expired). Idempotent.
  notFound,

  /// The caller's `stillValid` check failed at the commit point.
  cancelled,

  /// Written by a newer schema: never overwritten.
  unsupportedSchema,

  /// The index could not be read or rewritten; nothing changed.
  storageFailed,
}

/// Phase 12 / M3 — outcome of an owner clear-all.
enum EvidenceClearResult {
  cleared,
  cancelled,
  unsupportedSchema,
  storageFailed
}

/// Phase 12 / M3 — index summary for the settings screen (no image bytes).
final class EvidenceSummary {
  const EvidenceSummary(this.count, this.totalBytes, this.health);

  final int count;
  final int totalBytes;
  final EvidenceIndexHealth health;
}

final class _Index {
  const _Index(this.items, this.health,
      {this.floor = -1, this.tombs = const <int>[], this.highWater = -1});

  final List<EvidenceItem> items;
  final EvidenceIndexHealth health;
  final int floor;
  final List<int> tombs;
  final int highWater;

  /// True when [seq] was deleted or cleared by the owner (or folded into the
  /// compaction high-water mark and not listed).
  bool retired(int seq) =>
      seq <= floor ||
      tombs.contains(seq) ||
      (seq <= highWater && !items.any((EvidenceItem e) => e.seq == seq));
}

/// JPEG helpers: validation and metadata stripping (APP1..APP15 + COM).
abstract final class JpegSanitizer {
  static bool looksLikeJpeg(Uint8List b) =>
      b.length >= 4 &&
      b[0] == 0xFF &&
      b[1] == 0xD8 &&
      b[b.length - 2] == 0xFF &&
      b[b.length - 1] == 0xD9;

  /// Returns the image without APPn (n>=1) and COM segments, or null if the
  /// header structure is malformed. Image data after SOS is kept verbatim.
  static Uint8List? strip(Uint8List b) {
    if (!looksLikeJpeg(b)) return null;
    final BytesBuilder out = BytesBuilder(copy: false)..add(<int>[0xFF, 0xD8]);
    int i = 2;
    while (i + 4 <= b.length) {
      if (b[i] != 0xFF) return null;
      final int marker = b[i + 1];
      if (marker == 0xDA) {
        out.add(Uint8List.sublistView(b, i)); // SOS: rest of the file
        return out.takeBytes();
      }
      final int len = (b[i + 2] << 8) | b[i + 3];
      if (len < 2 || i + 2 + len > b.length) return null;
      final bool metadata =
          (marker >= 0xE1 && marker <= 0xEF) || marker == 0xFE;
      if (!metadata) {
        out.add(Uint8List.sublistView(b, i, i + 2 + len));
      }
      i += 2 + len;
    }
    return null; // no SOS
  }
}

class IntruderEvidenceStore {
  IntruderEvidenceStore(
    this._database,
    this._cipher, {
    DateTime Function()? now,
    this.maxImageBytes = defaultMaxImageBytes,
    this.maxItems = defaultMaxItems,
    this.maxTotalBytes = defaultMaxTotalBytes,
    this.retention = defaultRetention,
  }) : _now = now ?? DateTime.now;

  static const int schemaVersion = 1;
  static const String indexKey = 'intruder_evidence_index';
  static const String quarantineKey = 'intruder_evidence_index.quarantine';
  static const String blobPrefix = 'intruder_evidence_blob_';
  static const String _enc = 'enc:v1:';
  static const int defaultMaxImageBytes = 256 * 1024;
  static const int defaultMaxItems = 10;
  static const int defaultMaxTotalBytes = 2560 * 1024;
  static const Duration defaultRetention = Duration(days: 30);
  static const int maxTombstones = 64;

  final LocalDatabase _database;
  final SettingsCipher _cipher;
  final DateTime Function() _now;
  final int maxImageBytes;
  final int maxItems;
  final int maxTotalBytes;
  final Duration retention;

  // Zone-safe FIFO lock (same design as the credential manager's: a held
  // flag plus one Completer per waiter, ownership handed over on release).
  bool _held = false;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  /// Serializes every store operation (no concurrent index writes).
  Future<T> _serial<T>(Future<T> Function() op) async {
    if (_held) {
      final Completer<void> turn = Completer<void>();
      _waiters.add(turn);
      await turn.future;
    } else {
      _held = true;
    }
    try {
      return await op();
    } finally {
      if (_waiters.isEmpty) {
        _held = false;
      } else {
        _waiters.removeFirst().complete();
      }
    }
  }

  static String blobKey(int seq) {
    if (seq < 0) throw ArgumentError.value(seq, 'seq');
    return '$blobPrefix$seq';
  }

  Future<_Index> _readIndex() async {
    final String? raw;
    try {
      raw = await _database.getSetting(indexKey);
    } catch (_) {
      return const _Index(<EvidenceItem>[], EvidenceIndexHealth.unreadable);
    }
    if (raw == null) {
      return const _Index(<EvidenceItem>[], EvidenceIndexHealth.ok);
    }
    Object? decoded;
    try {
      if (!raw.startsWith(_enc)) throw const FormatException('plaintext');
      decoded =
          jsonDecode(await _cipher.decryptString(raw.substring(_enc.length)));
      if (decoded is Map &&
          decoded['v'] is int &&
          (decoded['v'] as int) > schemaVersion) {
        return const _Index(<EvidenceItem>[], EvidenceIndexHealth.unsupported);
      }
      if (decoded is! Map ||
          decoded['v'] != schemaVersion ||
          decoded['items'] is! List) {
        throw const FormatException('index');
      }
      final List<EvidenceItem> items = <EvidenceItem>[
        for (final Object? e in decoded['items'] as List)
          EvidenceItem.fromJson(e),
      ];
      final Set<int> seqs = items.map((EvidenceItem e) => e.seq).toSet();
      if (seqs.length != items.length) throw const FormatException('dup seq');
      // Phase 12 / M3 optional guard fields (absent in M2-written indexes).
      final Object? f = decoded['floor'];
      if (f != null && (f is! int || f < -1)) {
        throw const FormatException('floor');
      }
      final Object? t = decoded['tomb'];
      if (t != null &&
          (t is! List ||
              t.length > maxTombstones ||
              t.any((Object? e) => e is! int || e < 0))) {
        throw const FormatException('tomb');
      }
      final Object? h = decoded['hw'];
      if (h != null && (h is! int || h < -1)) {
        throw const FormatException('hw');
      }
      final int floor = (f as int?) ?? -1;
      final List<int> tombs = <int>[
        for (final Object? e in (t as List?) ?? const <Object?>[]) e as int,
      ];
      // An item at or below the floor / tombstoned cannot be live.
      if (items
          .any((EvidenceItem e) => e.seq <= floor || tombs.contains(e.seq))) {
        throw const FormatException('retired item listed');
      }
      return _Index(items, EvidenceIndexHealth.ok,
          floor: floor, tombs: tombs, highWater: (h as int?) ?? -1);
    } catch (_) {
      // Corrupt: keep the first corrupt value for diagnosis, start empty.
      try {
        if (await _database.getSetting(quarantineKey) == null) {
          await _database.setSetting(quarantineKey, raw);
        }
        await _database.removeSetting(indexKey);
      } catch (_) {
        return const _Index(<EvidenceItem>[], EvidenceIndexHealth.unreadable);
      }
      return const _Index(<EvidenceItem>[], EvidenceIndexHealth.ok);
    }
  }

  Future<void> _writeIndex(
    List<EvidenceItem> items, {
    required int floor,
    required List<int> tombs,
    required int highWater,
  }) async {
    final String enc = await _cipher.encryptString(jsonEncode(<String, Object?>{
      'v': schemaVersion,
      'items': <Object?>[for (final EvidenceItem e in items) e.toJson()],
      if (floor >= 0) 'floor': floor,
      if (tombs.isNotEmpty) 'tomb': tombs,
      if (highWater >= 0) 'hw': highWater,
    }));
    await _database.setSetting(indexKey, '$_enc$enc');
  }

  /// Items currently stored (oldest first). Empty when unreadable.
  Future<List<EvidenceItem>> list() =>
      _serial(() async => (await _readIndex()).items);

  Future<EvidenceIndexHealth> health() =>
      _serial(() async => (await _readIndex()).health);

  Future<bool> contains(int seq) => _serial(() async =>
      (await _readIndex()).items.any((EvidenceItem e) => e.seq == seq));

  /// Phase 12 / M3 — items and index health from ONE serialized read.
  Future<(List<EvidenceItem>, EvidenceIndexHealth)> snapshot() =>
      _serial(() async {
        final _Index idx = await _readIndex();
        return (idx.items, idx.health);
      });

  /// Phase 12 / M3 — count / size / health for the settings screen. Never
  /// decrypts an image.
  Future<EvidenceSummary> summary() => _serial(() async {
        final _Index idx = await _readIndex();
        return EvidenceSummary(
          idx.items.length,
          idx.items.fold<int>(0, (int s, EvidenceItem e) => s + e.bytes),
          idx.health,
        );
      });

  /// Decrypts one image. Null when missing, corrupt, unreadable, or not
  /// (any longer) listed in the index — a deleted, cleared or expired item
  /// is never readable even if its row survived a crash. Phase 12 / M3: the
  /// owner evidence viewer calls this inside a verified owner session.
  Future<Uint8List?> readImage(int seq) => _serial(() async {
        if (seq < 0) return null;
        try {
          final _Index idx = await _readIndex();
          if (idx.health != EvidenceIndexHealth.ok ||
              !idx.items.any((EvidenceItem e) => e.seq == seq)) {
            return null;
          }
          final String? raw = await _database.getSetting(blobKey(seq));
          if (raw == null || !raw.startsWith(_enc)) return null;
          final Uint8List bytes = base64Decode(
              await _cipher.decryptString(raw.substring(_enc.length)));
          return JpegSanitizer.looksLikeJpeg(bytes) ? bytes : null;
        } catch (_) {
          return null;
        }
      });

  /// Encrypts and stores [jpeg] as the evidence for M1 event [seq].
  ///
  /// [stillValid] is evaluated synchronously inside the serialized write,
  /// immediately before the blob is written (the commit point); when it
  /// returns false nothing is written and [EvidenceSaveResult.cancelled] is
  /// returned.
  Future<EvidenceSaveResult> save({
    required int seq,
    required Uint8List jpeg,
    String? packageName,
    bool Function()? stillValid,
  }) =>
      _serial(() async {
        if (seq < 0) return EvidenceSaveResult.invalidImage;
        final Uint8List? clean = JpegSanitizer.strip(jpeg);
        if (clean == null) return EvidenceSaveResult.invalidImage;
        if (clean.length > maxImageBytes) return EvidenceSaveResult.oversized;
        final _Index idx = await _readIndex();
        final List<EvidenceItem> items = idx.items;
        if (idx.health == EvidenceIndexHealth.unsupported) {
          return EvidenceSaveResult.unsupportedSchema;
        }
        if (idx.health == EvidenceIndexHealth.unreadable) {
          return EvidenceSaveResult.storageFailed;
        }
        if (items.any((EvidenceItem e) => e.seq == seq)) {
          return EvidenceSaveResult.duplicate;
        }
        // Phase 12 / M3: deleted / cleared evidence never comes back.
        if (idx.retired(seq)) {
          return EvidenceSaveResult.superseded;
        }
        final String blob;
        try {
          blob = await _cipher.encryptString(base64Encode(clean));
        } catch (_) {
          return EvidenceSaveResult.encryptionFailed;
        }
        final List<EvidenceItem> next = _bounded(<EvidenceItem>[
          ...items,
          EvidenceItem(
            seq: seq,
            at: _now(),
            bytes: clean.length,
            packageName: packageName,
          ),
        ]);
        if (stillValid != null && !stillValid()) {
          return EvidenceSaveResult.cancelled;
        }
        try {
          await _database.setSetting(blobKey(seq), '$_enc$blob');
          await _writeIndex(next,
              floor: idx.floor, tombs: idx.tombs, highWater: idx.highWater);
        } catch (_) {
          try {
            await _database.removeSetting(blobKey(seq));
          } catch (_) {}
          return EvidenceSaveResult.storageFailed;
        }
        final Set<int> kept = next.map((EvidenceItem e) => e.seq).toSet();
        for (final EvidenceItem e in items) {
          if (!kept.contains(e.seq)) {
            try {
              await _database.removeSetting(blobKey(e.seq));
            } catch (_) {}
          }
        }
        return EvidenceSaveResult.saved;
      });

  List<EvidenceItem> _bounded(List<EvidenceItem> items) {
    final DateTime cutoff = _now().subtract(retention);
    List<EvidenceItem> kept = items
        .where((EvidenceItem e) => !e.at.isBefore(cutoff)) // future kept
        .toList()
      ..sort((EvidenceItem a, EvidenceItem b) => a.seq.compareTo(b.seq));
    while (kept.length > maxItems ||
        kept.fold<int>(0, (int s, EvidenceItem e) => s + e.bytes) >
            maxTotalBytes) {
      kept = kept.sublist(1);
    }
    return kept;
  }

  /// Removes blobs the index does not reference (crash between blob and
  /// index write) and index entries whose blob is missing. Returns the
  /// number of orphan blobs removed. Never touches a newer-schema index.
  Future<int> sweepOrphans() => _serial(_sweepUnlocked);

  /// Phase 12 / M3 — startup crash recovery then retention as ONE
  /// serialized operation (a single lock acquisition, as in M2).
  Future<void> startupMaintenance() => _serial(() async {
        await _sweepUnlocked();
        await _retentionUnlocked();
      });

  Future<int> _sweepUnlocked() async {
    final _Index idx = await _readIndex();
    final List<EvidenceItem> items = idx.items;
    if (idx.health != EvidenceIndexHealth.ok) return 0;
    final Map<String, String> all;
    try {
      all = await _database.getAllSettings();
    } catch (_) {
      return 0;
    }
    final Set<String> referenced =
        items.map((EvidenceItem e) => blobKey(e.seq)).toSet();
    int removed = 0;
    for (final String k in all.keys) {
      if (k.startsWith(blobPrefix) && !referenced.contains(k)) {
        try {
          await _database.removeSetting(k);
          removed++;
        } catch (_) {}
      }
    }
    final List<EvidenceItem> present = items
        .where((EvidenceItem e) => all.containsKey(blobKey(e.seq)))
        .toList();
    if (present.length != items.length) {
      try {
        await _writeIndex(present,
            floor: idx.floor, tombs: idx.tombs, highWater: idx.highWater);
      } catch (_) {}
    }
    return removed;
  }

  // -------------------------------------------------------------------
  // Phase 12 / Milestone 3 — owner evidence management.
  // -------------------------------------------------------------------

  /// Owner delete of the evidence for [seq].
  ///
  /// Commit point: the index rewrite that removes the item AND records the
  /// tombstone in the same write — after it, the item is neither listed nor
  /// readable and a late save for the same seq is refused. The blob row is
  /// removed afterwards (a crash leaves an orphan for [sweepOrphans]).
  /// [stillValid] is evaluated synchronously immediately before the commit.
  /// Never touches the M1 log, counters, cooldown or settings.
  Future<EvidenceDeleteResult> delete(int seq, {bool Function()? stillValid}) =>
      _serial(() async {
        if (seq < 0) return EvidenceDeleteResult.notFound;
        final _Index idx = await _readIndex();
        if (idx.health == EvidenceIndexHealth.unsupported) {
          return EvidenceDeleteResult.unsupportedSchema;
        }
        if (idx.health == EvidenceIndexHealth.unreadable) {
          return EvidenceDeleteResult.storageFailed;
        }
        if (!idx.items.any((EvidenceItem e) => e.seq == seq)) {
          return EvidenceDeleteResult.notFound;
        }
        final List<EvidenceItem> next =
            idx.items.where((EvidenceItem e) => e.seq != seq).toList();
        List<int> tombs = <int>[...idx.tombs, seq];
        int highWater = idx.highWater;
        if (tombs.length > maxTombstones) {
          // R-M3-6 exact compaction: fold EVERY tombstone into the high-water
          // mark (never drop one). A tombstone is never listed, so it stays
          // retired as "<= hw and not listed"; listed items are exempt.
          for (final int t in tombs) {
            if (t > highWater) highWater = t;
          }
          tombs = <int>[];
        }
        if (stillValid != null && !stillValid()) {
          return EvidenceDeleteResult.cancelled;
        }
        try {
          await _writeIndex(next,
              floor: idx.floor, tombs: tombs, highWater: highWater);
        } catch (_) {
          return EvidenceDeleteResult.storageFailed;
        }
        try {
          await _database.removeSetting(blobKey(seq));
        } catch (_) {
          // Orphan row (ciphertext, unreferenced): removed by sweepOrphans.
        }
        return EvidenceDeleteResult.deleted;
      });

  /// Owner clear-all.
  ///
  /// Commit point: ONE index write with no items and
  /// `floor = max(existing floor, every listed/tombstoned seq, hw, floorSeq)`.
  /// The caller passes the coordinator's highest handled event seq as
  /// [floorSeq] so a capture already in flight for an earlier failure can
  /// never be saved after the clear. Blob rows are then removed
  /// (best-effort; leftovers are unreferenced and swept).
  Future<EvidenceClearResult> clearAll({
    int floorSeq = -1,
    bool Function()? stillValid,
  }) =>
      _serial(() async {
        final _Index idx = await _readIndex();
        if (idx.health == EvidenceIndexHealth.unsupported) {
          return EvidenceClearResult.unsupportedSchema;
        }
        if (idx.health == EvidenceIndexHealth.unreadable) {
          return EvidenceClearResult.storageFailed;
        }
        int floor = idx.floor > floorSeq ? idx.floor : floorSeq;
        for (final EvidenceItem e in idx.items) {
          if (e.seq > floor) floor = e.seq;
        }
        for (final int t in idx.tombs) {
          if (t > floor) floor = t;
        }
        if (idx.highWater > floor) floor = idx.highWater;
        if (stillValid != null && !stillValid()) {
          return EvidenceClearResult.cancelled;
        }
        try {
          await _writeIndex(const <EvidenceItem>[],
              floor: floor, tombs: const <int>[], highWater: -1);
        } catch (_) {
          return EvidenceClearResult.storageFailed;
        }
        await _removeUnreferencedBlobs(const <String>{});
        return EvidenceClearResult.cleared;
      });

  /// Removes items older than [retention] (index first, then blobs).
  /// Runs at startup and before every owner list. Returns the number of
  /// items removed. Never touches a newer-schema or unreadable index.
  Future<int> enforceRetention() => _serial(_retentionUnlocked);

  Future<int> _retentionUnlocked() async {
    final _Index idx = await _readIndex();
    if (idx.health != EvidenceIndexHealth.ok) return 0;
    final DateTime cutoff = _now().subtract(retention);
    final List<EvidenceItem> kept =
        idx.items.where((EvidenceItem e) => !e.at.isBefore(cutoff)).toList();
    if (kept.length == idx.items.length) return 0;
    try {
      await _writeIndex(kept,
          floor: idx.floor, tombs: idx.tombs, highWater: idx.highWater);
    } catch (_) {
      return 0;
    }
    final Set<int> keptSeqs = kept.map((EvidenceItem e) => e.seq).toSet();
    for (final EvidenceItem e in idx.items) {
      if (!keptSeqs.contains(e.seq)) {
        try {
          await _database.removeSetting(blobKey(e.seq));
        } catch (_) {}
      }
    }
    return idx.items.length - kept.length;
  }

  Future<void> _removeUnreferencedBlobs(Set<String> referenced) async {
    final Map<String, String> all;
    try {
      all = await _database.getAllSettings();
    } catch (_) {
      return;
    }
    for (final String k in all.keys) {
      if (k.startsWith(blobPrefix) && !referenced.contains(k)) {
        try {
          await _database.removeSetting(k);
        } catch (_) {}
      }
    }
  }
}
