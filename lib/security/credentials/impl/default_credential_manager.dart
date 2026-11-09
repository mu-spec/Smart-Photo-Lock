import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

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
import '../verified_attempt.dart';
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
    VerifiedAttemptObserver? attemptObserver,
  })  : _settings = settings,
        _pinHasher = pinHasher ?? Pbkdf2PinHasher(),
        _patternHasher = patternHasher ?? Pbkdf2PatternHasher(),
        _machine = stateMachine ?? CredentialStateMachine(),
        _pinStore = pinStore ?? DefaultPinCredentialStore(settings),
        _patternHashPolicy = patternHashPolicy,
        _biometrics = biometricService,
        _now = now ?? DateTime.now,
        _observer = attemptObserver,
        _instanceNonce = _newInstanceNonce();

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

  /// Phase 12 / M1: observe-only sink for completed, counted verifications
  /// (the intruder monitor). Never awaited; exceptions are swallowed; it can
  /// never change a verdict.
  final VerifiedAttemptObserver? _observer;

  /// Phase 12 / M1: random per-instance prefix of every verification id, so
  /// ids stay unique across process recreation without using the clock.
  final String _instanceNonce;
  int _verificationSequence = 0;

  /// Phase 12 / M1 defect fix: every read-modify-write of the settings
  /// document (authentication counters, enrollment, preferences, clearAll)
  /// runs under ONE FIFO lock. Without it, concurrent verifications each
  /// loaded the same counters and overwrote one another — three concurrent
  /// wrong PINs persisted one failure and never tripped the lockout. A
  /// biometric system prompt is NEVER held under this lock (a stuck prompt
  /// must not block PIN entry); only its verdict is applied under it.
  final _SerialLock _lock = _SerialLock();

  /// Phase 12 / M1 gate B: the biometric "basis" epoch. Bumped (under
  /// [_lock], immediately before the write) by every credential-set or
  /// biometric-option write — enrollPin, enrollPattern, clearAll,
  /// updateBiometricOptions — whether or not the write lands. A biometric
  /// prompt captures it before it starts; a SUCCESS delivered after the
  /// epoch moved is stale and never authorizes. Separate from the CR-3
  /// [_credentialEpoch] so CR-3 grant semantics are untouched.
  int _biometricBasisEpoch = 0;

  static String _newInstanceNonce() {
    Random random;
    try {
      random = Random.secure();
    } on UnsupportedError {
      random = Random();
    }
    String part() => random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    return '${part()}${part()}';
  }

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
  }) =>
      _lock.run(() => _enrollPinLocked(pin, policy, authorization));

  Future<Result<void>> _enrollPinLocked(
    String pin,
    PinPolicy policy,
    CredentialChangeAuthorization? authorization,
  ) async {
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
    _biometricBasisEpoch++;
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
  }) =>
      _lock.run(() => _enrollPatternLocked(nodes, policy, authorization));

  Future<Result<void>> _enrollPatternLocked(
    List<int> nodes,
    PatternPolicy policy,
    CredentialChangeAuthorization? authorization,
  ) async {
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
    _biometricBasisEpoch++;
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
  Future<Result<void>> updateBiometricOptions(BiometricOptions? options) =>
      _lock.run(() async {
        final Result<SecuritySettings> loaded = await _settings.getSettings();
        _biometricBasisEpoch++;
        return loaded.fold(
          (SecuritySettings s) => _settings.saveSettings(
            options == null
                ? s.copyWith(clearBiometricOptions: true)
                : s.copyWith(biometricOptions: options),
          ),
          Result.failure,
        );
      });

  @override
  Future<Result<void>> setRandomizedKeypadEnabled(bool enabled) =>
      _lock.run(() async {
        final Result<SecuritySettings> loaded = await _settings.getSettings();
        return loaded.fold(
          (SecuritySettings s) => _settings.saveSettings(
            s.copyWith(randomizedKeypadEnabled: enabled),
          ),
          Result.failure,
        );
      });

  @override
  Future<Result<void>> setPatternVisibilityEnabled(bool enabled) =>
      _lock.run(() async {
        final Result<SecuritySettings> loaded = await _settings.getSettings();
        return loaded.fold(
          (SecuritySettings s) => _settings.saveSettings(
            s.copyWith(patternVisibilityEnabled: enabled),
          ),
          Result.failure,
        );
      });

  // -- authentication -----------------------------------------------------

  @override
  Future<Result<AuthAttemptResult>> authenticatePin(String pin) {
    // Attribution is captured when the call STARTS (Phase 12 / M1).
    final AuthAttemptContext context = AuthAttemptContext.current;
    return _lock.run(() => _authenticatePinLocked(pin, context));
  }

  Future<Result<AuthAttemptResult>> _authenticatePinLocked(
    String pin,
    AuthAttemptContext context,
  ) async {
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
    return _evaluateAndPersist(s, state, matches, AuthType.pin, context);
  }

  @override
  Future<Result<AuthAttemptResult>> authenticatePattern(List<int> nodes) {
    final AuthAttemptContext context = AuthAttemptContext.current;
    return _lock.run(() => _authenticatePatternLocked(nodes, context));
  }

  Future<Result<AuthAttemptResult>> _authenticatePatternLocked(
    List<int> nodes,
    AuthAttemptContext context,
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
    return _evaluateAndPersist(s, state, matches, AuthType.pattern, context);
  }

  @override
  Future<Result<AuthAttemptResult>> authenticateBiometric({
    String reason = 'Unlock Smart App Lock',
  }) async {
    final AuthAttemptContext context = AuthAttemptContext.current;
    // Gate B: captured BEFORE the pre-prompt read, so any credential or
    // biometric-option write that could race the read is still detected.
    final int basisEpoch = _biometricBasisEpoch;
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
      // H-3: cancellation (Back, the prompt's Cancel button), system
      // cancellation and timeout end the prompt without a verdict. They
      // never grant access, and they are neither counted as a failed app
      // credential attempt nor allowed to reset existing counters or a
      // lockout: nothing is persisted. Cancelling reveals nothing about the
      // app PIN or pattern, and an active lockout still blocks the prompt
      // (step 2).
      if (error is BiometricAuthException && error.isCancellation) {
        return Result.success(
          AuthFailure(
            reason: AuthFailureReason.cancelled,
            remainingAttempts: _remainingAttempts(state),
          ),
        );
      }
      // Any other platform error is treated as a rejection and counts, so
      // a failing prompt can never be used to dodge the escalating lockout.
      return _evaluateLatestAndPersist(
        false,
        AuthType.biometric,
        context,
        promptBasis: s,
        basisEpoch: basisEpoch,
      );
    }

    // Phase 12 / M1: the verdict is applied to the CURRENT counters (re-read
    // under the lock), not the pre-prompt snapshot — a lockout that started
    // while the prompt was open still blocks, and a stale write can never
    // revert newer counters or credentials. H-3 branches above are unchanged.
    return _evaluateLatestAndPersist(
      outcome.valueOrNull == true,
      AuthType.biometric,
      context,
      promptBasis: s,
      basisEpoch: basisEpoch,
    );
  }

  // -- lifecycle ----------------------------------------------------------

  @override
  Future<Result<void>> clearAll() => _lock.run(_clearAllLocked);

  Future<Result<void>> _clearAllLocked() async {
    _biometricBasisEpoch++;
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

  /// Attempts left before a lockout, without recording an attempt. Callers
  /// have already handled an ACTIVE lockout, so a non-null
  /// [CredentialState.lockedOutUntil] here is an expired one, which the
  /// state machine treats as a fresh count.
  int _remainingAttempts(CredentialState state) {
    final int used = state.lockedOutUntil != null ? 0 : state.failedAttempts;
    final int remaining = _machine.maxFailedAttempts - used;
    return remaining < 0 ? 0 : remaining;
  }

  /// Biometric verdicts: re-reads the settings under the lock and applies
  /// the verdict to the current counters (fails closed on a read failure).
  ///
  /// Gate B: a SUCCESS is discarded — no grant, no counter reset, nothing
  /// persisted, nothing reported — when, while the prompt was open,
  ///  * biometric unlock was disabled or every credential was cleared
  ///    (-> notConfigured, as the pre-prompt gate would answer), or
  ///  * the credential set / biometric options were written (basis epoch
  ///    moved) or now differ from what the prompt started against
  ///    (-> cancelled: the prompt ended without a usable verdict).
  /// A REJECTION is always counted against the current counters, so a
  /// stale prompt can never reduce counting either.
  Future<Result<AuthAttemptResult>> _evaluateLatestAndPersist(
    bool matches,
    AuthType type,
    AuthAttemptContext context, {
    required SecuritySettings promptBasis,
    required int basisEpoch,
  }) =>
      _lock.run(() async {
        final Result<SecuritySettings> loaded = await _settings.getSettings();
        if (loaded.isFailure) {
          return Result<AuthAttemptResult>.failure(loaded.errorOrNull!);
        }
        final SecuritySettings s = loaded.valueOrNull!;
        final CredentialState state = _stateFrom(s);
        if (matches) {
          if (s.biometricOptions == null || !s.hasAnyCredential) {
            return Result<AuthAttemptResult>.success(
              const AuthFailure(
                reason: AuthFailureReason.notConfigured,
                remainingAttempts: 0,
              ),
            );
          }
          if (basisEpoch != _biometricBasisEpoch ||
              _biometricBasisOf(promptBasis) != _biometricBasisOf(s)) {
            return Result<AuthAttemptResult>.success(
              AuthFailure(
                reason: AuthFailureReason.cancelled,
                remainingAttempts: _remainingAttempts(state),
              ),
            );
          }
        }
        return _evaluateAndPersist(s, state, matches, type, context);
      });

  /// What a biometric prompt authorizes against: the enrolled credential
  /// material, the biometric options and the primary method. Compared as
  /// canonical JSON (catches writes from any manager instance).
  static String _biometricBasisOf(SecuritySettings s) {
    final Map<String, dynamic> j = s.toJson();
    return jsonEncode(<String, dynamic>{
      'pinHash': j['pinHash'],
      'patternHash': j['patternHash'],
      'biometricOptions': j['biometricOptions'],
      'primaryAuthType': j['primaryAuthType'],
    });
  }

  /// Runs the state machine and persists the resulting counters. Always
  /// called under [_lock]. This is the ONE place a counted verdict exists,
  /// so it is the one place the [_observer] hears about it — after the
  /// counter write, so a lost event can never mean a lost counter.
  Future<Result<AuthAttemptResult>> _evaluateAndPersist(
    SecuritySettings s,
    CredentialState state,
    bool matches,
    AuthType type,
    AuthAttemptContext context,
  ) async {
    final DateTime now = _now();
    final (CredentialState next, AuthAttemptResult result) = _machine.evaluate(
      state: state,
      credentialMatches: matches,
      attemptType: type,
      now: now,
    );
    final Result<void> saved = await _settings.saveSettings(
      s.copyWith(
        failedAttempts: next.failedAttempts,
        lockedOutUntil: next.lockedOutUntil,
        clearLockout: next.lockedOutUntil == null,
        lockoutStreak: next.lockoutStreak,
      ),
    );
    _notifyObserver(
      VerifiedAttempt(
        verificationId: '$_instanceNonce:${++_verificationSequence}',
        type: type,
        matched: matches,
        result: result,
        counterPersisted: saved.isSuccess,
        lockoutStreak: next.lockoutStreak,
        context: context,
        at: now,
      ),
    );
    if (saved.isFailure) {
      return Result.failure(saved.errorOrNull!);
    }
    return Result.success(result);
  }

  /// Observe-only: synchronous, never awaited, never allowed to throw into
  /// the authentication path (monitoring can never override enforcement).
  void _notifyObserver(VerifiedAttempt attempt) {
    final VerifiedAttemptObserver? observer = _observer;
    if (observer == null) {
      return;
    }
    try {
      observer.onVerifiedAttempt(attempt);
    } catch (_) {
      // Deliberately ignored: a failing monitor must not affect the verdict.
    }
  }
}

/// Phase 12 / M1: minimal FIFO async mutex. Actions run one at a time in
/// call order; an action's failure never wedges the queue.
///
/// Zone-safe by construction: an uncontended action starts immediately in
/// the caller's zone, and each waiter parks on a [Completer] created in ITS
/// OWN zone, handed the lock directly on release. No future is ever shared
/// across callers (a completed future schedules its listeners in the zone
/// that created it, which can stall callers from another zone).
final class _SerialLock {
  bool _held = false;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() action) async {
    if (_held) {
      final Completer<void> turn = Completer<void>();
      _waiters.add(turn);
      await turn.future; // ownership is handed over; _held stays true
    } else {
      _held = true;
    }
    try {
      return await action();
    } finally {
      if (_waiters.isEmpty) {
        _held = false;
      } else {
        _waiters.removeFirst().complete();
      }
    }
  }
}

/// CR-3: registry entry backing a live [CredentialChangeAuthorization].
final class _ChangeGrant {
  const _ChangeGrant({required this.issuedAt, required this.epoch});

  final DateTime issuedAt;
  final int epoch;
}
