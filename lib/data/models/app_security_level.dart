/// Per-app security level (PRD v2.1, Phase 8: 8A model, 8C–8E behaviour).
///
/// Pure Dart. Named `AppSecurityLevel` because the design system already
/// has an unrelated `SecurityLevel` (status tones: secured / at risk / ...).
///
/// Phase 8 / M2: the level changes re-locking only, through
/// `SecurityLevelPolicy` (Dart) and `SecurityLevelPolicy.kt` (native): the
/// grace after leaving and the inactivity window. Every protected app still
/// uses the same PIN/pattern challenge. See `docs/architecture.md`.
///
/// Persistence: [storageId] is the stable on-disk identifier (SQLite column
/// `protected_apps.security_level`, JSON key `securityLevel`). Never rename
/// an id; add new levels with new ids.
enum AppSecurityLevel {
  standard(
    storageId: 'standard',
    rank: 0,
    label: 'Standard',
    description: 'Everyday apps. Re-locks using your Security settings.',
  ),
  sensitive(
    storageId: 'sensitive',
    rank: 1,
    label: 'Sensitive',
    description: 'Private apps such as messages, photos or notes. Re-locks '
        'within 15 seconds of leaving, at most, and after 1 minute without '
        'activity.',
  ),
  critical(
    storageId: 'critical',
    rank: 2,
    label: 'Critical',
    description: 'Banking, payments or passwords. Asks for your PIN or '
        'pattern each time you return to the app. No grace period.',
  );

  const AppSecurityLevel({
    required this.storageId,
    required this.rank,
    required this.label,
    required this.description,
  });

  /// Stable persistent identifier. Exact, lowercase.
  final String storageId;

  /// Strictness order: higher is stricter (Critical > Sensitive > Standard).
  final int rank;

  /// Short user-facing name.
  final String label;

  /// One-line, concrete description of the re-lock behaviour. It claims no
  /// more than the observable behaviour (see `docs/capabilities.md`).
  final String description;

  /// Level given to an app when it is first protected, and to legacy
  /// records written before levels existed (missing value).
  static const AppSecurityLevel defaultLevel = AppSecurityLevel.standard;

  /// The strictest level; used for values that are present but unreadable.
  static const AppSecurityLevel strictest = AppSecurityLevel.critical;

  /// True when this level is stricter than [other].
  bool isStricterThan(AppSecurityLevel other) => rank > other.rank;

  /// Parses a persisted value. Never throws and never drops the app:
  ///
  ///  * `null` (legacy record without a level) → [defaultLevel] (Standard);
  ///  * an exact known [storageId] → that level;
  ///  * anything else (unknown id from a newer version, wrong case, wrong
  ///    type, corruption) → [strictest] (Critical). A damaged value can
  ///    only make the classification stricter, never weaker.
  static AppSecurityLevel fromStorage(Object? raw) {
    if (raw == null) return defaultLevel;
    if (raw is String) {
      for (final AppSecurityLevel level in values) {
        if (level.storageId == raw) return level;
      }
    }
    return strictest;
  }

  /// True when [raw] is exactly a known [storageId] (diagnostics/tests).
  static bool isKnownStorageId(Object? raw) =>
      values.any((AppSecurityLevel l) => l.storageId == raw);
}
