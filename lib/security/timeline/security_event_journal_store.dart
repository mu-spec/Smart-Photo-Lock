// Phase 13 / Milestone 1 — encrypted single-row storage for the security
// event journal. Same database and AES-GCM settings cipher as the security
// settings; mirrors the Phase 12 failure-log store contract.
import 'dart:convert';

import '../../data/storage/local_database.dart';
import '../encryption/settings_cipher.dart';
import 'security_journal_event.dart';

sealed class SecurityJournalRead {
  const SecurityJournalRead();
}

final class SecurityJournalMissing extends SecurityJournalRead {
  const SecurityJournalMissing();
}

final class SecurityJournalLoaded extends SecurityJournalRead {
  const SecurityJournalLoaded(this.document);

  final SecurityJournalDocument document;
}

/// Undecryptable (GCM tamper), unparsable or schema-invalid. [raw] is kept
/// only so it can be quarantined before reinitialization.
final class SecurityJournalCorrupt extends SecurityJournalRead {
  const SecurityJournalCorrupt(this.raw);

  final String raw;
}

/// Written by a NEWER schema version: must never be overwritten.
final class SecurityJournalUnsupported extends SecurityJournalRead {
  const SecurityJournalUnsupported(this.version);

  final int version;
}

/// Storage could not be read (or ciphertext without a cipher): nothing is
/// known, so nothing may be overwritten.
final class SecurityJournalUnreadable extends SecurityJournalRead {
  const SecurityJournalUnreadable({required this.permanent});

  final bool permanent;
}

class SecurityEventJournalStore {
  SecurityEventJournalStore(this._database, {SettingsCipher? cipher})
      : _cipher = cipher;

  static const String storageKey = 'security_event_journal';
  static const String quarantineKey = 'security_event_journal.quarantine';
  static const String _encryptedPrefix = 'enc:v1:';

  final LocalDatabase _database;
  final SettingsCipher? _cipher;

  Future<SecurityJournalRead> read() async {
    final String? raw;
    try {
      raw = await _database.getSetting(storageKey);
    } catch (_) {
      return const SecurityJournalUnreadable(permanent: false);
    }
    if (raw == null) {
      return const SecurityJournalMissing();
    }
    final String jsonText;
    if (raw.startsWith(_encryptedPrefix)) {
      final SettingsCipher? cipher = _cipher;
      if (cipher == null) {
        return const SecurityJournalUnreadable(permanent: true);
      }
      try {
        jsonText =
            await cipher.decryptString(raw.substring(_encryptedPrefix.length));
      } catch (_) {
        return SecurityJournalCorrupt(raw);
      }
    } else if (_cipher == null) {
      jsonText = raw; // plaintext is only ever written without a cipher
    } else {
      return SecurityJournalCorrupt(raw); // plaintext where ciphertext belongs
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } catch (_) {
      return SecurityJournalCorrupt(raw);
    }
    final int? declared = SecurityJournalDocument.declaredVersion(decoded);
    if (declared != null &&
        declared > SecurityJournalDocument.version &&
        decoded is Map &&
        decoded['schema'] == SecurityJournalDocument.schema) {
      return SecurityJournalUnsupported(declared);
    }
    try {
      return SecurityJournalLoaded(SecurityJournalDocument.fromJson(decoded));
    } on FormatException {
      return SecurityJournalCorrupt(raw);
    }
  }

  /// Serialized exactly as [write] stores it (before encryption); used for
  /// the size bound.
  static String encode(SecurityJournalDocument doc) => jsonEncode(doc.toJson());

  /// Throws on failure; the previous row stays intact (single-row replace).
  Future<void> write(SecurityJournalDocument doc) async {
    final String json = encode(doc);
    final SettingsCipher? cipher = _cipher;
    final String stored = cipher == null
        ? json
        : '$_encryptedPrefix${await cipher.encryptString(json)}';
    await _database.setSetting(storageKey, stored);
  }

  /// Keeps the FIRST corrupt value only (bounded; never overwritten).
  /// Returns true when [raw] was quarantined now. Throws on storage failure.
  Future<bool> quarantine(String raw) async {
    if (await _database.getSetting(quarantineKey) != null) {
      return false;
    }
    await _database.setSetting(quarantineKey, raw);
    return true;
  }

  /// Presence of a quarantined (damaged) earlier journal. Throws on storage
  /// failure (the caller reports "integrity unknown").
  Future<bool> hasQuarantine() async =>
      await _database.getSetting(quarantineKey) != null;
}
