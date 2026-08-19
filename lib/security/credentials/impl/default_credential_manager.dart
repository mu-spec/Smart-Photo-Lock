import '../../../data/models/security_settings.dart';
import '../../../data/repositories/security_settings_repository.dart';
import '../../../services/biometric_service.dart';
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
    BiometricService? biometricService,
  })  : _settings = settings,
        _pinHasher = pinHasher ?? Pbkdf2PinHasher(),
        _patternHasher = patternHasher ?? Pbkdf2PatternHasher(),
        _machine = stateMachine ?? const CredentialStateMachine(),
        _pinStore = pinStore ?? DefaultPinCredentialStore(settings),
        _biometrics = biometricService;

  final SecuritySettingsRepository _settings;
  final PinHasher _pinHasher;
  final PatternHasher _patternHasher;
  final CredentialStateMachine _machine;
  final PinCredentialStore _pinStore;

  /// Platform biometric service; null = not wired (attempts fail with
  /// [AuthFailureReason.notAvailable] — never a fabricated success).
  final BiometricService? _biometrics;

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
        pinLength: pin.length,
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
  Future<Result<void>> updateBiometricOptions(BiometricOptions? options) async {
    final Result<SecuritySettings> loaded = await _settings.getSettings();
    return loaded.fold(
      (SecuritySettings s) => _settings.saveSettings(
        options == null
            ? s.copyWith(clearBiometricOptions: true)
            : s.copyWith(biometricOptions: options),
      ),
      Result.failure,
    );
  }

  @override
  Future<Result<void>> setRandomizedKeypadEnabled(bool enabled) async {
    final Result<SecuritySettings> loaded = await _settings.getSettings();
    return loaded.fold(
      (SecuritySettings s) => _settings.saveSettings(
        s.copyWith(randomizedKeypadEnabled: enabled),
      ),
      Result.failure,
    );
  }

  @override
  Future<Result<void>> setPatternVisibilityEnabled(bool enabled) async {
    final Result<SecuritySettings> loaded = await _settings.getSettings();
    return loaded.fold(
      (SecuritySettings s) => _settings.saveSettings(
        s.copyWith(patternVisibilityEnabled: enabled),
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
    final CredentialHash? patternHash = s.patternHash;
    // Fail closed: legacy (direction-insensitive) hashes are ambiguous and
    // must be re-enrolled — they are treated as not enrolled, never
    // verified against both orientations.
    if (patternHash == null || Pbkdf2PatternHasher.isLegacyHash(patternHash)) {
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

    final bool matches = await _patternHasher.verify(nodes, patternHash);
    return _evaluateAndPersist(s, state, matches, AuthType.pattern);
  }

  @override
  Future<Result<AuthAttemptResult>> authenticateBiometric({
    String reason = 'Unlock Smart App Lock',
  }) async {
    // 1. Configuration gates: biometric is an accelerator — it needs the
    //    user's explicit opt-in AND an enrolled primary credential.
    final Result<SecuritySettings> loaded = await _settings.getSettings();
    if (loaded.isFailure) {
      return Result.failure(loaded.errorOrNull!);
    }
    final SecuritySettings s = loaded.valueOrNull!;
    final BiometricOptions? options = s.biometricOptions;
    if (options == null || !s.hasAnyCredential) {
      return Result.success(
        const AuthFailure(
          reason: AuthFailureReason.notConfigured,
          remainingAttempts: 0,
        ),
      );
    }

    final BiometricService? service = _biometrics;
    if (service == null) {
      return Result.success(
        const AuthFailure(
          reason: AuthFailureReason.notAvailable,
          remainingAttempts: 0,
        ),
      );
    }

    // 2. Lockout gates everything — even the correct biometric.
    final CredentialState state = _stateFrom(s);
    final AuthLockedOut? activeLockout = _activeLockout(state, DateTime.now());
    if (activeLockout != null) {
      return Result.success(activeLockout);
    }

    // 3. Capability check (BiometricManager).
    final Result<bool> supported = await service.isSupported();
    if (supported.isFailure || supported.valueOrNull != true) {
      return Result.success(
        const AuthFailure(
          reason: AuthFailureReason.notAvailable,
          remainingAttempts: 0,
        ),
      );
    }

    // 4. Prompt (BiometricPrompt). The OS owns verification.
    final Result<bool> outcome =
        await service.authenticate(reason: reason, options: options);
    if (outcome.isFailure) {
      // Platform rejection (canceled, not enrolled, ...) counts as a
      // failed attempt so brute-forcing prompts cannot bypass lockouts.
      return _evaluateAndPersist(s, state, false, AuthType.biometric);
    }

    return _evaluateAndPersist(
      s,
      state,
      outcome.valueOrNull == true,
      AuthType.biometric,
    );
  }

  // -- lifecycle ----------------------------------------------------------

  @override
  Future<Result<void>> clearAll() =>
      _settings.saveSettings(SecuritySettings.defaults);

  // -- internals ----------------------------------------------------------

  /// Projects persisted settings onto a [CredentialState] snapshot.
  ///
  /// Legacy (direction-insensitive) pattern hashes are excluded from the
  /// enrolled set so flows treat them as "set up the pattern again" —
  /// re-enrollment overwrites the record with the ordered scheme.
  CredentialState _stateFrom(SecuritySettings s) {
    final bool patternUsable =
        s.patternHash != null &&
            !Pbkdf2PatternHasher.isLegacyHash(s.patternHash!);
    final Set<AuthType> enrolled = <AuthType>{
      if (s.pinHash != null) AuthType.pin,
      if (patternUsable) AuthType.pattern,
      if (s.biometricOptions != null) AuthType.biometric,
    };
    final AuthType? primary = s.primaryAuthType ??
        (s.pinHash != null
            ? AuthType.pin
            : patternUsable
                ? AuthType.pattern
                : null);
    // A legacy primary falls back to PIN (or none).
    final AuthType? effectivePrimary =
        primary == AuthType.pattern && !patternUsable
            ? (s.pinHash != null ? AuthType.pin : null)
            : primary;
    return CredentialState(
      enrolled: enrolled,
      primary: effectivePrimary,
      failedAttempts: s.failedAttempts,
      lockedOutUntil: s.lockedOutUntil,
      pinLength: s.pinLength,
      lockoutStreak: s.lockoutStreak,
      randomizedKeypadEnabled: s.randomizedKeypadEnabled,
      patternVisibilityEnabled: s.patternVisibilityEnabled,
    );
  }

  /// Returns the active lockout (if any) — used to skip hashing while
  /// authentication is blocked.
  AuthLockedOut? _activeLockout(CredentialState state, DateTime now) {
    final DateTime? until = state.lockedOutUntil;
    if (until != null && now.isBefore(until)) {
      return AuthLockedOut(retryAt: until, lockoutStreak: state.lockoutStreak);
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
        lockoutStreak: next.lockoutStreak,
      ),
    );
    if (saved.isFailure) {
      return Result.failure(saved.errorOrNull!);
    }
    return Result.success(result);
  }
}
