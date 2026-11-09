// Phase 12 / Milestone 2 — Intruder Defense owner settings.
//
// The owner's explicit opt-ins for camera evidence and the alarm, plus the
// configured failure threshold. Stored as ONE encrypted row in the existing
// LocalDatabase settings table, separate from the credential document (the
// auth core is not touched). Privacy fail-safe: anything unreadable,
// corrupt or written by a newer schema reads as DISABLED and is never
// overwritten. This record controls evidence and the alarm only — it is
// never consulted for any access decision.

import 'dart:convert';

import '../../data/storage/local_database.dart';
import '../encryption/settings_cipher.dart';

/// The owner's intruder-defense choices. Everything defaults to off.
final class IntruderDefenseSettings {
  const IntruderDefenseSettings({
    this.evidenceEnabled = false,
    this.alarmEnabled = false,
    this.threshold = defaultThreshold,
  });

  static const int schemaVersion = 1;
  static const int defaultThreshold = 3;
  static const int minThreshold = 1;
  static const int maxThreshold = 10;

  static const IntruderDefenseSettings disabled = IntruderDefenseSettings();

  /// Camera evidence after the threshold (requires CAMERA permission).
  final bool evidenceEnabled;

  /// Audible alarm after the threshold.
  final bool alarmEnabled;

  /// Consecutive verified failures that trigger evidence / alarm.
  final int threshold;

  IntruderDefenseSettings copyWith({
    bool? evidenceEnabled,
    bool? alarmEnabled,
    int? threshold,
  }) =>
      IntruderDefenseSettings(
        evidenceEnabled: evidenceEnabled ?? this.evidenceEnabled,
        alarmEnabled: alarmEnabled ?? this.alarmEnabled,
        threshold: threshold ?? this.threshold,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'v': schemaVersion,
        'evidence': evidenceEnabled,
        'alarm': alarmEnabled,
        'threshold': threshold,
      };

  /// Strict decode; throws [FormatException] on anything unexpected.
  static IntruderDefenseSettings fromJson(Object? raw) {
    if (raw is! Map ||
        raw['v'] != schemaVersion ||
        raw['evidence'] is! bool ||
        raw['alarm'] is! bool ||
        raw['threshold'] is! int) {
      throw const FormatException('intruder defense settings');
    }
    final int t = raw['threshold'] as int;
    if (t < minThreshold || t > maxThreshold) {
      throw const FormatException('threshold out of range');
    }
    return IntruderDefenseSettings(
      evidenceEnabled: raw['evidence'] as bool,
      alarmEnabled: raw['alarm'] as bool,
      threshold: t,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is IntruderDefenseSettings &&
      other.evidenceEnabled == evidenceEnabled &&
      other.alarmEnabled == alarmEnabled &&
      other.threshold == threshold;

  @override
  int get hashCode => Object.hash(evidenceEnabled, alarmEnabled, threshold);
}

/// Why the stored settings are (or are not) in effect.
enum IntruderSettingsHealth { ok, missing, corrupt, unsupported, unreadable }

final class IntruderSettingsRead {
  const IntruderSettingsRead(this.settings, this.health);

  /// The settings in effect — [IntruderDefenseSettings.disabled] unless
  /// [health] is ok.
  final IntruderDefenseSettings settings;
  final IntruderSettingsHealth health;

  /// Only a missing or valid record may be replaced; a corrupt, newer or
  /// unreadable one is never overwritten.
  bool get writable =>
      health == IntruderSettingsHealth.ok ||
      health == IntruderSettingsHealth.missing;
}

/// Encrypted persistence for [IntruderDefenseSettings]. A cipher is
/// mandatory: there is no plaintext mode.
class IntruderDefenseSettingsStore {
  IntruderDefenseSettingsStore(this._database, this._cipher);

  static const String storageKey = 'intruder_defense_settings';
  static const String _prefix = 'enc:v1:';

  final LocalDatabase _database;
  final SettingsCipher _cipher;

  Future<IntruderSettingsRead> read() async {
    final String? raw;
    try {
      raw = await _database.getSetting(storageKey);
    } catch (_) {
      return const IntruderSettingsRead(
          IntruderDefenseSettings.disabled, IntruderSettingsHealth.unreadable);
    }
    if (raw == null) {
      return const IntruderSettingsRead(
          IntruderDefenseSettings.disabled, IntruderSettingsHealth.missing);
    }
    if (!raw.startsWith(_prefix)) {
      return const IntruderSettingsRead(
          IntruderDefenseSettings.disabled, IntruderSettingsHealth.corrupt);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(
          await _cipher.decryptString(raw.substring(_prefix.length)));
    } catch (_) {
      return const IntruderSettingsRead(
          IntruderDefenseSettings.disabled, IntruderSettingsHealth.corrupt);
    }
    if (decoded is Map &&
        decoded['v'] is int &&
        (decoded['v'] as int) > IntruderDefenseSettings.schemaVersion) {
      return const IntruderSettingsRead(
          IntruderDefenseSettings.disabled, IntruderSettingsHealth.unsupported);
    }
    try {
      return IntruderSettingsRead(
          IntruderDefenseSettings.fromJson(decoded), IntruderSettingsHealth.ok);
    } on FormatException {
      return const IntruderSettingsRead(
          IntruderDefenseSettings.disabled, IntruderSettingsHealth.corrupt);
    }
  }

  /// Saves [settings]. Returns false (and writes nothing) when the current
  /// record must not be overwritten, or when the write fails.
  Future<bool> write(IntruderDefenseSettings settings) async {
    final IntruderSettingsRead current = await read();
    if (!current.writable) {
      return false;
    }
    try {
      final String enc =
          await _cipher.encryptString(jsonEncode(settings.toJson()));
      await _database.setSetting(storageKey, '$_prefix$enc');
      return true;
    } catch (_) {
      return false;
    }
  }
}
