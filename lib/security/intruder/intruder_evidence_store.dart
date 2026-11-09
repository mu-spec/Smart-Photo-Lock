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
}

enum EvidenceIndexHealth { ok, unsupported, unreadable }

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

  Future<(List<EvidenceItem>, EvidenceIndexHealth)> _readIndex() async {
    final String? raw;
    try {
      raw = await _database.getSetting(indexKey);
    } catch (_) {
      return (const <EvidenceItem>[], EvidenceIndexHealth.unreadable);
    }
    if (raw == null) return (const <EvidenceItem>[], EvidenceIndexHealth.ok);
    Object? decoded;
    try {
      if (!raw.startsWith(_enc)) throw const FormatException('plaintext');
      decoded =
          jsonDecode(await _cipher.decryptString(raw.substring(_enc.length)));
      if (decoded is Map &&
          decoded['v'] is int &&
          (decoded['v'] as int) > schemaVersion) {
        return (const <EvidenceItem>[], EvidenceIndexHealth.unsupported);
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
      return (items, EvidenceIndexHealth.ok);
    } catch (_) {
      // Corrupt: keep the first corrupt value for diagnosis, start empty.
      try {
        if (await _database.getSetting(quarantineKey) == null) {
          await _database.setSetting(quarantineKey, raw);
        }
        await _database.removeSetting(indexKey);
      } catch (_) {
        return (const <EvidenceItem>[], EvidenceIndexHealth.unreadable);
      }
      return (const <EvidenceItem>[], EvidenceIndexHealth.ok);
    }
  }

  Future<void> _writeIndex(List<EvidenceItem> items) async {
    final String enc = await _cipher.encryptString(jsonEncode(<String, Object?>{
      'v': schemaVersion,
      'items': <Object?>[for (final EvidenceItem e in items) e.toJson()],
    }));
    await _database.setSetting(indexKey, '$_enc$enc');
  }

  /// Items currently stored (oldest first). Empty when unreadable.
  Future<List<EvidenceItem>> list() =>
      _serial(() async => (await _readIndex()).$1);

  Future<EvidenceIndexHealth> health() =>
      _serial(() async => (await _readIndex()).$2);

  Future<bool> contains(int seq) => _serial(() async =>
      (await _readIndex()).$1.any((EvidenceItem e) => e.seq == seq));

  /// Decrypts one image. Null when missing, corrupt or unreadable. (No UI
  /// exposes this in M2; it exists for integrity tests and later phases.)
  Future<Uint8List?> readImage(int seq) => _serial(() async {
        if (seq < 0) return null;
        try {
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
        final (List<EvidenceItem> items, EvidenceIndexHealth h) =
            await _readIndex();
        if (h == EvidenceIndexHealth.unsupported) {
          return EvidenceSaveResult.unsupportedSchema;
        }
        if (h == EvidenceIndexHealth.unreadable) {
          return EvidenceSaveResult.storageFailed;
        }
        if (items.any((EvidenceItem e) => e.seq == seq)) {
          return EvidenceSaveResult.duplicate;
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
          await _writeIndex(next);
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
  Future<int> sweepOrphans() => _serial(() async {
        final (List<EvidenceItem> items, EvidenceIndexHealth h) =
            await _readIndex();
        if (h != EvidenceIndexHealth.ok) return 0;
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
            await _writeIndex(present);
          } catch (_) {}
        }
        return removed;
      });
}
