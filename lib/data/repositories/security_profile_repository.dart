import '../../profiles/security_profile.dart';
import '../../utilities/result.dart';

/// Why a Security Profile storage operation failed.
enum SecurityProfileStoreErrorKind {
  /// The saved profiles could not be read (storage threw).
  storageUnavailable,

  /// The saved profiles exist but cannot be decoded. Kept as-is; no write
  /// replaces them (never silently reset to defaults).
  corrupt,

  /// Written by a newer build. Kept as-is; no write.
  unsupportedVersion,

  /// A write failed or could not be confirmed. The previous value was
  /// restored (best effort); the change was NOT saved.
  writeFailed,

  /// The stored profiles are not the ones the caller read. Nothing was
  /// written; reload and retry.
  conflict,
}

class SecurityProfileStoreException implements Exception {
  const SecurityProfileStoreException(this.kind, this.message, [this.cause]);

  final SecurityProfileStoreErrorKind kind;
  final String message;
  final Object? cause;

  @override
  String toString() => 'SecurityProfileStoreException(${kind.name}): $message';
}

/// Phase 11 / M1: configuration storage for Security Profiles.
///
/// Configuration only: nothing here changes protection, a level, the
/// protected set, grace, authorization, a challenge or anything native.
/// A failed write is never reported as saved.
///
/// Phase 11 / M1 has no production caller of [saveProfiles] (switching and
/// editing are M2); the active profile is Normal for every user.
abstract interface class SecurityProfileRepository {
  /// The saved profiles, or the defaults (Normal active) when nothing is
  /// saved. Reading never writes.
  Future<Result<SecurityProfileSet>> getProfiles();

  /// Replaces the stored profiles by [profiles] only when the stored value
  /// still equals [expected] (compare-and-swap; `conflict` otherwise).
  /// Refused while the stored document is corrupt, unsupported or
  /// unreadable.
  Future<Result<void>> saveProfiles(
    SecurityProfileSet profiles, {
    required SecurityProfileSet expected,
  });
}
