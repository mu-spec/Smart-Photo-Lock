// Phase 12 / Milestone 1 — Intruder Defense foundation.
//
// Persistence of the failed-attempt log: ONE row in the existing
// LocalDatabase settings table (SQLite in production — a single-row replace
// is atomic), encrypted with the SAME AES-256-GCM SettingsCipher and
// Keystore-backed master key as the security settings. No new store, SDK or
// permission.
import 'dart:convert';

import '../../data/storage/local_database.dart';
import '../encryption/settings_cipher.dart';
import 'failed_attempt_event.dart';

/// Outcome of reading the stored log.
sealed class IntruderLogRead {
  const IntruderLogRead();
}

/// Nothing stored yet.
final class IntruderLogMissing extends IntruderLogRead {
  const IntruderLogMissing();
}

/// A valid v1 document.
final class IntruderLogLoaded extends IntruderLogRead {
  const IntruderLogLoaded(this.log);
  final IntruderFailureLog log;
}

/// Undecryptable (GCM tamper), unparsable or schema-invalid. [raw] is the
/// stored value so it can be quarantined before reinitialization.
final class IntruderLogCorrupt extends IntruderLogRead {
  const IntruderLogCorrupt(this.raw);
  final String raw;
}

/// Written by a NEWER schema version: must never be overwritten.
final class IntruderLogUnsupported extends IntruderLogRead {
  const IntruderLogUnsupported(this.version);
  final int version;
}

/// Storage could not be read (or encrypted data without a cipher): nothing
/// is known, so nothing may be overwritten.
final class IntruderLogUnreadable extends IntruderLogRead {
  const IntruderLogUnreadable({required this.permanent});

  /// True when retrying cannot help (encrypted data, no cipher).
  final bool permanent;
}

class IntruderFailureLogStore {
  IntruderFailureLogStore(this._database, {SettingsCipher? cipher})
      : _cipher = cipher;

  static const String storageKey = 'intruder_failure_log';
  static const String quarantineKey = 'intruder_failure_log.quarantine';
  static const String _encryptedPrefix = 'enc:v1:';

  final LocalDatabase _database;
  final SettingsCipher? _cipher;

  Future<IntruderLogRead> read() async {
    final String? raw;
    try {
      raw = await _database.getSetting(storageKey);
    } catch (_) {
      return const IntruderLogUnreadable(permanent: false);
    }
    if (raw == null) {
      return const IntruderLogMissing();
    }
    final String jsonText;
    if (raw.startsWith(_encryptedPrefix)) {
      final SettingsCipher? cipher = _cipher;
      if (cipher == null) {
        return const IntruderLogUnreadable(permanent: true);
      }
      try {
        jsonText =
            await cipher.decryptString(raw.substring(_encryptedPrefix.length));
      } catch (_) {
        return IntruderLogCorrupt(raw);
      }
    } else if (_cipher == null) {
      jsonText = raw; // plaintext is only ever written without a cipher
    } else {
      return IntruderLogCorrupt(raw); // plaintext where ciphertext belongs
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } catch (_) {
      return IntruderLogCorrupt(raw);
    }
    final int? declared = IntruderFailureLog.declaredVersion(decoded);
    if (declared != null &&
        declared > IntruderFailureLog.version &&
        decoded is Map &&
        decoded['schema'] == IntruderFailureLog.schema) {
      return IntruderLogUnsupported(declared);
    }
    try {
      return IntruderLogLoaded(IntruderFailureLog.fromJson(decoded));
    } on FormatException {
      return IntruderLogCorrupt(raw);
    }
  }

  /// Serializes [log] exactly as [write] would store it (before encryption);
  /// used for the size bound.
  static String encode(IntruderFailureLog log) => jsonEncode(log.toJson());

  /// Throws on failure; the previous row stays intact (single-row replace).
  Future<void> write(IntruderFailureLog log) async {
    final String json = encode(log);
    final SettingsCipher? cipher = _cipher;
    final String stored = cipher == null
        ? json
        : '$_encryptedPrefix${await cipher.encryptString(json)}';
    await _database.setSetting(storageKey, stored);
  }

  /// Keeps the FIRST corrupt value only (bounded; never overwritten).
  /// Returns true when [raw] was quarantined now.
  Future<bool> quarantine(String raw) async {
    if (await _database.getSetting(quarantineKey) != null) {
      return false;
    }
    await _database.setSetting(quarantineKey, raw);
    return true;
  }
}
