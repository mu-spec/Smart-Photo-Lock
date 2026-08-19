import '../../../data/models/security_settings.dart';
import '../../../data/repositories/security_settings_repository.dart';
import '../../../utilities/result.dart';
import '../../pin_hasher.dart';
import '../credential_hash_policy.dart';
import '../pin_storage.dart';

/// [PinCredentialStore] over the encrypted security settings.
///
/// Storage chain (see docs/architecture.md §2D):
///
/// ```
/// PIN ──PBKDF2──► PinHash ──► SecuritySettings.pinHash
///                                  │ AES-256-GCM (Keystore-backed key)
///                                  ▼
///                        enc:v1:<ciphertext>  ──► SQLite
/// ```
///
/// The raw PIN exists only transiently in the caller's memory while
/// hashing — it is never persisted, never logged, and never returned.
class DefaultPinCredentialStore implements PinCredentialStore {
  DefaultPinCredentialStore(
    this._settings, {
    CredentialHashPolicy? policy,
  }) : _policy = policy ?? CredentialHashPolicy.lenient;

  final SecuritySettingsRepository _settings;
  final CredentialHashPolicy _policy;

  @override
  Future<Result<void>> save(PinHash hash) async {
    // Refuse to persist credential material below the storage policy.
    final HashPolicyViolation? violation = _policy.validate(hash);
    if (violation != null) {
      return Result.failure(
        StateError(
          'Refusing to store a PIN credential that violates the storage '
          'security policy: ${violation.name}',
        ),
      );
    }

    final Result<SecuritySettings> loaded = await _settings.getSettings();
    return loaded.fold(
      (SecuritySettings s) => _settings.saveSettings(
        s.copyWith(pinHash: hash),
      ),
      Result.failure,
    );
  }

  @override
  Future<Result<PinHash?>> load() async {
    final Result<SecuritySettings> loaded = await _settings.getSettings();
    if (loaded.isFailure) {
      return Result.failure(loaded.errorOrNull!);
    }
    final PinHash? stored = loaded.valueOrNull!.pinHash;
    if (stored == null) {
      return Result.success(null);
    }

    // Fail closed: a corrupted or weakened record must never be used for
    // verification.
    final HashPolicyViolation? violation = _policy.validate(stored);
    if (violation != null) {
      return Result.failure(
        StateError(
          'Stored PIN credential failed the storage security policy '
          '(${violation.name}). Re-enrollment required.',
        ),
      );
    }
    return Result.success(stored);
  }

  @override
  Future<Result<void>> delete() async {
    final Result<SecuritySettings> loaded = await _settings.getSettings();
    return loaded.fold(
      (SecuritySettings s) => _settings.saveSettings(
        s.copyWith(clearPin: true),
      ),
      Result.failure,
    );
  }
}
