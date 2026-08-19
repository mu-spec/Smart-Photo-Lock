import '../../utilities/result.dart';
import '../pin_hasher.dart';

/// Secure PIN storage boundary.
///
/// **The raw PIN never crosses this boundary.** Callers hash first
/// ([PinHasher]) and hand over only the derived, verifiable [PinHash].
/// Implementations must:
///
///  * persist only the hash (salt + digest + parameters);
///  * validate the stored record against a [CredentialHashPolicy] on load
///    and fail closed when it is corrupted or weakened;
///  * never log or return raw credential material.
///
/// The production implementation stores the hash inside the encrypted
/// security settings document (Phase 1F chain: AES-256-GCM with a
/// Keystore-backed master key).
abstract interface class PinCredentialStore {
  /// Persists ONLY the derived [PinHash]. A hash that violates the storage
  /// policy is refused with a [Failure].
  Future<Result<void>> save(PinHash hash);

  /// Loads the stored hash for verification.
  ///
  /// Resolves to null when no PIN is enrolled; resolves to a [Failure] when
  /// the stored record fails the security policy (corrupted/weakened).
  Future<Result<PinHash?>> load();

  /// Removes the stored PIN credential.
  Future<Result<void>> delete();
}
