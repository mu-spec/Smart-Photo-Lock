import '../../../data/models/security_settings.dart';
import '../../../data/repositories/security_settings_repository.dart';
import '../../../services/biometric_service.dart';
import '../../../utilities/result.dart';
import '../../pin_hasher.dart';
import '../../pin_policy.dart';
import '../auth_result.dart';
import '../auth_type.dart';
import '../biometric_options.dart';
import '../credential_change_authorization.dart';
import '../credential_hash.dart';
import '../credential_state.dart';
import '../credential_state_machine.dart';
import '../credential_manager.dart';
import '../credential_hash_policy.dart';
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
    CredentialHashPolicy patternHashPolicy = CredentialHashPolicy.lenient,
    BiometricService? biometricService,
    DateTime Function()? now,
  })  : _settings = settings,
        _pinHasher = pinHasher ?? Pbkdf2PinHasher(),
        _patternHasher = patternHasher ?? Pbkdf2PatternHasher(),
        _machine = stateMachine ?? CredentialStateMachine(),
        _pinStore = pinStore ?? DefaultPinCredentialStore(settings),
        _patternHashPolicy = patternHashPolicy,
        _biometrics = biometricService,
        _now = now ?? DateTime.now;

  final SecuritySettingsRepository _settings;
  final PinHasher _pinHasher;
  final PatternHasher _patternHasher;
  final CredentialStateMachine _machine;
  final PinCredentialStore _pinStore;
  final CredentialHashPolicy _patternHashPolicy;

  /// Platform biometric service; null = not wired (attempts fail with
  /// [AuthFailureReason.notAvailable] — never a fabricated success).
  final BiometricService? _biometrics;

  /// Clock seam (Phase 2L QA): lockout timestamps come from here so tests
  /// can drive time deterministically; defaults to [DateTime.now].
  final DateTime Function() _now;

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
    CredentialChangeAuthorization? authorization,
  }) async {
    final PinValidation validation = policy.validate(pin);
    if (validation != PinValidation.valid) {
      return Result.failure(
        FormatException(policy.messageFor(validation)),
      );
    }
    // CR-3 write gate: runs before hashing and before any write.
    final Result<SecuritySettings> loaded = await _settings.getSettings();
    if (loaded.isFailure) {
      return Result.failure(loaded.errorOrNull!); // fail closed
    }
    final CredentialChangeNotAuthorized? denied =
        _consumeChangeAuthorization(loaded.valueOrNull!, authorization);
    if (denied != null) {
      return Result.failure(denied);
    }
    final PinHash hash = await _pinHasher.hash(pin);

    // The hash and all metadata that describes it must land in ONE settings
    // write. Two writes can leave an old hash paired with a new length or
    // primary method when the second write fails.
    final Result<void> saved = await _pinStore.save(
      hash,
      pinLength: pin.length,
      makePrimary: true,
      resetAttemptState: true,
    );
    _credentialSetChanged();
    return saved;
  }

  @override
  Future<Result<void>> enrollPattern(
    List<int> nodes, {
    PatternPolicy policy = PatternPolicy.defaults,
    CredentialChangeAuthorization? authorization,
  }) async {
    final PatternValidation validation = policy.validate(nodes);
    if (validation != PatternValidation.valid) {
      return Result.failure(
        FormatException(policy.messageFor(validation)),
      );
    }
    // CR-3 write gate: runs before hashing and before any write.
    final Result<SecuritySettings> gateLoaded = await _settings.getSettings();
    if (gateLoaded.isFailure) {
      return Result.failure(gateLoaded.errorOrNull!); // fail closed
    }
    final CredentialChangeNotAuthorized? denied =
        _consumeChangeAuthorization(gateLoaded.valueOrNull!, authorization);
    if (denied != null) {
      return Result.failure(denied);
    }
    final CredentialHash hash = await _patternHasher.hash(nodes);
    final Result<SecuritySettings> loaded = await _settings.getSettings();
    final Result<void> saved = await loaded.fold(
      (SecuritySettings s) => _settings.saveSettings(
        s.copyWith(
          patternHash: hash,
          primaryAuthType: AuthType.pattern,
          failedAttempts: 0,
          clearLockout: true,
        ),
      ),
      (Object e) async => Result<void>.failure(e),
    );
    _credentialSetChanged();
    return saved;
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
    final AuthLockedOut? activeLockout = _activeLockout(state, _now());
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
    final HashPolicyViolation? patternViolation =
        _patternHashPolicy.validate(patternHash);
    if (patternViolation != null) {
      return Result.failure(
        StateError(
          'Stored pattern credential failed the storage security policy '
          '(${patternViolation.name}). Re-enrollment required.',
        ),
      );
    }

    final CredentialState state = _stateFrom(s);
    final AuthLockedOut? activeLockout = _activeLockout(state, _now());
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
    final AuthLockedOut? activeLockout = _activeLockout(state, _now());
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
      final Object? error = outcome.errorOrNull;
      // Availability problems (no hardware, nothing enrolled, lockouts, ...)
      // are NOT authentication rejections — surface them without counting.
      if (error is BiometricAuthException && error.isAvailabilityError) {
        return Result.success(
          const AuthFailure(
            reason: AuthFailureReason.notAvailable,
            remainingAttempts: 0,
          ),
        );
      }
      // Rejections and cancellations count as failed attempts so
      // prompt-spamming cannot bypass the escalating lockout (2L policy).
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
  Future<Result<void>> clearAll() async {
    _credentialSetChanged();
    final Result<void> saved =
        await _settings.saveSettings(SecuritySettings.defaults);
    _credentialSetChanged();
    return saved;
  }

  // -- CR-3: credential-change authorization ------------------------------

  /// How long a credential-change grant stays valid after verification.
  static const Duration credentialChangeAuthorizationTtl =
      Duration(minutes: 2);

  /// Live grants, keyed by handle identity. Memory only: a recreated
  /// process starts empty, so no grant survives process death.
  final Map<CredentialChangeAuthorization, _ChangeGrant> _changeGrants =
      Map<CredentialChangeAuthorization, _ChangeGrant>.identity();

  /// Bumped on every credential-set write (successful or not, because a
  /// failed write may still have partly landed). A grant is bound to the
  /// epoch it was issued in.
  int _credentialEpoch = 0;

  @override
  Future<Result<CredentialChangeAttempt>> verifyPinForCredentialChange(
    String pin,
  ) async =>
      _issueOnSuccess(await authenticatePin(pin), AuthType.pin);

  @override
  Future<Result<CredentialChangeAttempt>> verifyPatternForCredentialChange(
    List<int> nodes,
  ) async =>
      _issueOnSuccess(await authenticatePattern(nodes), AuthType.pattern);

  @override
  void revokeCredentialChangeAuthorization(
    CredentialChangeAuthorization authorization,
  ) {
    _changeGrants.remove(authorization);
  }

  Result<CredentialChangeAttempt> _issueOnSuccess(
    Result<AuthAttemptResult> attempt,
    AuthType method,
  ) {
    if (attempt.isFailure) {
      return Result.failure(attempt.errorOrNull!);
    }
    final AuthAttemptResult result = attempt.valueOrNull!;
    if (result is! AuthSuccess || result.type != method) {
      return Result.success(CredentialChangeAttempt(result));
    }
    // At most one live grant: a new verification supersedes older ones.
    _changeGrants.clear();
    final CredentialChangeAuthorization handle =
        CredentialChangeAuthorization.handle(method: method);
    _changeGrants[handle] = _ChangeGrant(
      issuedAt: _now(),
      epoch: _credentialEpoch,
    );
    return Result.success(CredentialChangeAttempt(result, handle));
  }

  /// The CR-3 write gate. Returns null if the write may go ahead.
  ///
  /// When a usable app credential exists, the supplied grant is removed
  /// from the registry (consumed) BEFORE it is validated, so it can never be
  /// replayed, even after a denied or failed write.
  CredentialChangeNotAuthorized? _consumeChangeAuthorization(
    SecuritySettings s,
    CredentialChangeAuthorization? authorization,
  ) {
    final CredentialState state = _stateFrom(s);
    final bool hasExistingCredential =
        state.hasEnrolled(AuthType.pin) || state.hasEnrolled(AuthType.pattern);
    if (!hasExistingCredential) {
      return null; // initial enrollment
    }
    if (authorization == null) {
      return const CredentialChangeNotAuthorized(
        CredentialChangeDenial.missing,
      );
    }
    final _ChangeGrant? grant = _changeGrants.remove(authorization);
    if (grant == null) {
      return const CredentialChangeNotAuthorized(
        CredentialChangeDenial.unknown,
      );
    }
    if (grant.epoch != _credentialEpoch) {
      return const CredentialChangeNotAuthorized(CredentialChangeDenial.stale);
    }
    final DateTime now = _now();
    final Duration age = now.difference(grant.issuedAt);
    if (age.isNegative || age > credentialChangeAuthorizationTtl) {
      return const CredentialChangeNotAuthorized(
        CredentialChangeDenial.expired,
      );
    }
    if (_activeLockout(state, now) != null) {
      return const CredentialChangeNotAuthorized(
        CredentialChangeDenial.lockedOut,
      );
    }
    return null;
  }

  void _credentialSetChanged() {
    _credentialEpoch++;
    _changeGrants.clear();
  }

  // -- internals ----------------------------------------------------------

  /// Projects persisted settings onto a [CredentialState] snapshot.
  ///
  /// Legacy (direction-insensitive) pattern hashes are excluded from the
  /// enrolled set so flows treat them as "set up the pattern again" —
  /// re-enrollment overwrites the record with the ordered scheme.
  CredentialState _stateFrom(SecuritySettings s) {
    final bool patternUsable = s.patternHash != null &&
        !Pbkdf2PatternHasher.isLegacyHash(s.patternHash!) &&
        _patternHashPolicy.validate(s.patternHash!) == null;
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
      now: _now(),
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

/// CR-3: registry entry backing a live [CredentialChangeAuthorization].
final class _ChangeGrant {
  const _ChangeGrant({required this.issuedAt, required this.epoch});

  final DateTime issuedAt;
  final int epoch;
}
