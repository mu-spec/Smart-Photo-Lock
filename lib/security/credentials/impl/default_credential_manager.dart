import '../../../data/models/security_settings.dart';
import '../../../data/repositories/security_settings_repository.dart';
import '../../../utilities/result.dart';
import '../../pin_hasher.dart';
import '../../pin_policy.dart';
import '../auth_result.dart';
import '../auth_type.dart';
import '../biometric_options.dart';
import '../credential_state.dart';
import '../credential_state_machine.dart';
import '../credential_manager.dart';
import '../pattern_hasher.dart';
import '../pattern_policy.dart';
import '../pin_storage.dart';
import 'default_pin_credential_store.dart';

/// Production [CredentialManager].
///
/// Pure Dart end-to-end: hashes credentials with PBKDF2, persists them
/// through the (encrypted) [SecuritySettingsRepository], and routes every
/// attempt through the [CredentialStateMachine] so lockouts survive app
/// restarts. Biometric authentication is delegated to a platform service
/// (wired in a later phase; until then attempts fail with
/// [AuthFailureReason.notAvailable]).
///
/// PIN credential material flows exclusively through the [PinCredentialStore]
/// (Phase 2D): the raw PIN is hashed in memory and only the derived hash
/// reaches persistence — never the PIN itself.
class DefaultCredentialManager implements CredentialManager {
  DefaultCredentialManager({
    required SecuritySettingsRepository settings,
    PinHasher? pinHasher,
    PatternHasher? patternHasher,
    CredentialStateMachine? stateMachine,
    PinCredentialStore? pinStore,
  })  : _settings = settings,
        _pinHasher = pinHasher ?? Pbkdf2PinHasher(),
        _patternHasher = patternHasher ?? Pbkdf2PatternHasher(),
        _machine = stateMachine ?? const CredentialStateMachine(),
        _pinStore = pinStore ?? DefaultPinCredentialStore(settings);

  final SecuritySettingsRepository _settings;
  final PinHasher _pinHasher;
  final PatternHasher _patternHasher;
  final CredentialStateMachine _machine;
  final PinCredentialStore _pinStore;

  // -- status -------------------------------------------------------------

  @override
  Future<Result<CredentialState>> status() async {
    final Result<SecuritySettings> loaded = await _settings.getSettings();
    return loaded.fold(
      (SecuritySettings s) => Result.success(_stateFrom(s)),
      Result.failure,
    );
  }

  // -- enrollment ---------------------------------------------------------

  @override
  Future<Result<void>> enrollPin(
    String pin, {
    PinPolicy policy = PinPolicy.defaults,
  }) async {
    final PinValidation validation = policy.validate(pin);
    if (validation != PinValidation.valid) {
      return Result.failure(
        FormatException(policy.messageFor(validation)),
      );
    }
    final PinHash hash = await _pinHasher.hash(pin);

    // Reset counters/primary first (benign if the credential write fails),
    // then persist ONLY the derived hash through the secure store.
    final Result<SecuritySettings> loaded = await _settings.getSettings();
    if (loaded.isFailure) {
      return Result.failure(loaded.errorOrNull!);
    }
    final Result<void> reset = await _settings.saveSettings(
      loaded.valueOrNull!.copyWith(
        primaryAuthType: AuthType.pin,
        failedAttempts: 0,
        clearLockout: true,
      ),
    );
    if (reset.isFailure) {
      return Result.failure(reset.errorOrNull!);
    }
    return _pinStore.save(hash);
  }

  @override
  Future<Result<void>> enrollPattern(
    List<int> nodes, {
    PatternPolicy policy = PatternPolicy.defaults,
  }) async {
    final PatternValidation validation = policy.validate(nodes);
    if (validation != PatternValidation.valid) {
      return Result.failure(
        FormatException(policy.messageFor(validation)),
      );
    }
    final CredentialHash hash = await _patternHasher.hash(nodes);
    final Result<SecuritySettings> loaded = await _settings.getSettings();
    return loaded.fold(
      (SecuritySettings s) => _settings.saveSettings(
        s.copyWith(
          patternHash: hash,
          primaryAuthType: AuthType.pattern,
          failedAttempts: 0,
          clearLockout: true,
        ),
      ),
      Result.failure,
    );
  }

  @override
  Future<Result<void>> updateBiometricOptions(BiometricOptions options) async {
    final Result<SecuritySettings> loaded = await _settings.getSettings();
    return loaded.fold(
      (SecuritySettings s) => _settings.saveSettings(
        s.copyWith(biometricOptions: options),
      ),
      Result.failure,
    );
  }

  // -- authentication -----------------------------------------------------

  @override
  Future<Result<AuthAttemptResult>> authenticatePin(String pin) async {
    final Result<PinHash?> loadedHash = await _pinStore.load();
    if (loadedHash.isFailure) {
      // Fail closed: corrupted/weakened stored credential.
      return Result.failure(loadedHash.errorOrNull!);
    }
    final PinHash? stored = loadedHash.valueOrNull;
    if (stored == null) {
      return Result.success(
        const AuthFailure(
          reason: AuthFailureReason.noCredentialEnrolled,
          remainingAttempts: 0,
        ),
      );
    }

    final Result<SecuritySettings> loaded = await _settings.getSettings();
    if (loaded.isFailure) {
      return Result.failure(loaded.errorOrNull!);
    }
    final SecuritySettings s = loaded.valueOrNull!;

    final CredentialState state = _stateFrom(s);
    final AuthLockedOut? activeLockout = _activeLockout(state, DateTime.now());
    if (activeLockout != null) {
      return Result.success(activeLockout);
    }

    final bool matches = await _pinHasher.verify(pin, stored);
    return _evaluateAndPersist(s, state, matches, AuthType.pin);
  }

  @override
  Future<Result<AuthAttemptResult>> authenticatePattern(
    List<int> nodes,
  ) async {
    final Result<SecuritySettings> loaded = await _settings.getSettings();
    if (loaded.isFailure) {
      return Result.failure(loaded.errorOrNull!);
    }
    final SecuritySettings s = loaded.valueOrNull!;
    if (s.patternHash == null) {
      return Result.success(
        const AuthFailure(
          reason: AuthFailureReason.noCredentialEnrolled,
          remainingAttempts: 0,
        ),
      );
    }

    final CredentialState state = _stateFrom(s);
    final AuthLockedOut? activeLockout = _activeLockout(state, DateTime.now());
    if (activeLockout != null) {
      return Result.success(activeLockout);
    }

    final bool matches = await _patternHasher.verify(nodes, s.patternHash!);
    return _evaluateAndPersist(s, state, matches, AuthType.pattern);
  }

  @override
  Future<Result<AuthAttemptResult>> authenticateBiometric({
    String reason = 'Unlock Smart App Lock',
  }) async {
    // Platform biometric prompt lands with the BiometricService phase.
    // Fail explicitly — never pretend success without OS verification.
    return Result.success(
      const AuthFailure(
        reason: AuthFailureReason.notAvailable,
        remainingAttempts: 0,
      ),
    );
  }

  // -- lifecycle ----------------------------------------------------------

  @override
  Future<Result<void>> clearAll() =>
      _settings.saveSettings(SecuritySettings.defaults);

  // -- internals ----------------------------------------------------------

  /// Projects persisted settings onto a [CredentialState] snapshot.
  CredentialState _stateFrom(SecuritySettings s) {
    final Set<AuthType> enrolled = <AuthType>{
      if (s.pinHash != null) AuthType.pin,
      if (s.patternHash != null) AuthType.pattern,
      if (s.biometricOptions != null) AuthType.biometric,
    };
    final AuthType? primary = s.primaryAuthType ??
        (s.pinHash != null
            ? AuthType.pin
            : s.patternHash != null
                ? AuthType.pattern
                : null);
    return CredentialState(
      enrolled: enrolled,
      primary: primary,
      failedAttempts: s.failedAttempts,
      lockedOutUntil: s.lockedOutUntil,
    );
  }

  /// Returns the active lockout (if any) — used to skip hashing while
  /// authentication is blocked.
  AuthLockedOut? _activeLockout(CredentialState state, DateTime now) {
    final DateTime? until = state.lockedOutUntil;
    if (until != null && now.isBefore(until)) {
      return AuthLockedOut(retryAt: until);
    }
    return null;
  }

  /// Runs the state machine and persists the resulting counters.
  Future<Result<AuthAttemptResult>> _evaluateAndPersist(
    SecuritySettings s,
    CredentialState state,
    bool matches,
    AuthType type,
  ) async {
    final (CredentialState next, AuthAttemptResult result) = _machine.evaluate(
      state: state,
      credentialMatches: matches,
      attemptType: type,
      now: DateTime.now(),
    );
    final Result<void> saved = await _settings.saveSettings(
      s.copyWith(
        failedAttempts: next.failedAttempts,
        lockedOutUntil: next.lockedOutUntil,
        clearLockout: next.lockedOutUntil == null,
      ),
    );
    if (saved.isFailure) {
      return Result.failure(saved.errorOrNull!);
    }
    return Result.success(result);
  }
}
