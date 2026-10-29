// Phase 5 / Milestone 2 — Challenge host security hardening (HB-1).
//
// Binds a protected-app lock challenge grant to an authentication that
// really happened on THAT challenge route, instead of trusting whatever
// value the route happened to complete with.

import '../security/credentials/auth_result.dart';
import '../security/credentials/auth_type.dart';
import '../security/credentials/biometric_options.dart';
import '../security/credentials/credential_change_authorization.dart';
import '../security/credentials/credential_manager.dart';
import '../security/credentials/credential_state.dart';
import '../security/credentials/pattern_policy.dart';
import '../security/pin_policy.dart';
import '../utilities/result.dart';

/// Records authentication for exactly ONE presented lock challenge route.
///
/// The host builds a fresh recorder for every challenge it presents, hands
/// it to that route's unlock screen as its [CredentialManager], and grants
/// access only when the route completes with `true` AND [close] reports a
/// success recorded by this same recorder.
///
///  * `status`, PIN, pattern and biometric authentication are forwarded
///    unchanged to the real manager, so attempt counting, lockout,
///    cooldowns and the H-3 biometric policy stay exactly as they are.
///  * Only a genuine [AuthSuccess] is recorded, only while the recorder is
///    open, only for an authentication type this route permits, and only
///    when the success's own type matches the method that produced it.
///  * A type the route does not permit is refused WITHOUT calling the real
///    manager (no attempt is counted, no prompt is shown).
///  * [close] is one-shot. The first call ends the challenge and reports
///    whether a success was recorded; afterwards the recorder is dead:
///    later calls report `false`, new attempts are refused, and a success
///    that arrives after closing (a late verification) is never recorded.
///  * Enrollment, every write, and the whole CR-3 credential-change grant
///    API are refused without touching the real manager. A challenge route
///    can therefore never mutate credentials or settings through it.
///
/// The recorder trusts its delegate's results: it binds a grant to an
/// authentication on this route; it does not re-verify the credential.
class ChallengeAuthRecorder implements CredentialManager {
  /// A recorder that permits only [permittedTypes]. Prefer the
  /// route-specific factories.
  ChallengeAuthRecorder(
    this._delegate, {
    required Set<AuthType> permittedTypes,
  }) : _permitted = Set<AuthType>.unmodifiable(permittedTypes);

  /// For the PIN challenge route: PIN plus the biometric accelerator
  /// (offered by the screen only when the user enabled it, Phase 5G).
  factory ChallengeAuthRecorder.forPinRoute(CredentialManager delegate) =>
      ChallengeAuthRecorder(
        delegate,
        permittedTypes: const <AuthType>{AuthType.pin, AuthType.biometric},
      );

  /// For the pattern challenge route: pattern plus the biometric
  /// accelerator (offered by the screen only when the user enabled it).
  factory ChallengeAuthRecorder.forPatternRoute(CredentialManager delegate) =>
      ChallengeAuthRecorder(
        delegate,
        permittedTypes: const <AuthType>{AuthType.pattern, AuthType.biometric},
      );

  final CredentialManager _delegate;
  final Set<AuthType> _permitted;

  bool _closed = false;
  bool _succeeded = false;

  /// Authentication types this route may record.
  Set<AuthType> get permittedTypes => _permitted;

  /// Whether the challenge this recorder belongs to is still open.
  bool get isOpen => !_closed;

  /// Ends the challenge. Returns `true` only on the FIRST call, and only if
  /// a permitted, genuine success was recorded while open. Every later call
  /// returns `false`; the success is consumed and can never be reused.
  bool close() {
    final bool succeeded = !_closed && _succeeded;
    _closed = true;
    _succeeded = false;
    return succeeded;
  }

  static Result<T> _refused<T>() => Result.failure(
        StateError('Not permitted on this lock challenge.'),
      );

  bool _accepts(AuthType method) => !_closed && _permitted.contains(method);

  Result<AuthAttemptResult> _record(
    AuthType method,
    Result<AuthAttemptResult> result,
  ) {
    final AuthAttemptResult? outcome = result.valueOrNull;
    // Re-checked when the result ARRIVES: a verification that started on
    // an open challenge but finishes after it closed is never recorded.
    if (!_closed &&
        _permitted.contains(method) &&
        outcome is AuthSuccess &&
        outcome.type == method) {
      _succeeded = true;
    }
    return result;
  }

  // -- delegated: read + authentication ------------------------------------

  @override
  Future<Result<CredentialState>> status() => _delegate.status();

  @override
  Future<Result<AuthAttemptResult>> authenticatePin(String pin) async {
    if (!_accepts(AuthType.pin)) return _refused();
    return _record(AuthType.pin, await _delegate.authenticatePin(pin));
  }

  @override
  Future<Result<AuthAttemptResult>> authenticatePattern(List<int> nodes) async {
    if (!_accepts(AuthType.pattern)) return _refused();
    return _record(
        AuthType.pattern, await _delegate.authenticatePattern(nodes));
  }

  @override
  Future<Result<AuthAttemptResult>> authenticateBiometric({
    String reason = 'Unlock Smart App Lock',
  }) async {
    if (!_accepts(AuthType.biometric)) return _refused();
    return _record(
      AuthType.biometric,
      await _delegate.authenticateBiometric(reason: reason),
    );
  }

  // -- CR-3 credential-change grant API: never available on a challenge -----

  @override
  Future<Result<CredentialChangeAttempt>> verifyPinForCredentialChange(
    String pin,
  ) async =>
      _refused();

  @override
  Future<Result<CredentialChangeAttempt>> verifyPatternForCredentialChange(
    List<int> nodes,
  ) async =>
      _refused();

  /// Intentionally a no-op: a challenge owns no credential-change grant and
  /// must never revoke one that belongs to a credential-change session.
  @override
  void revokeCredentialChangeAuthorization(
    CredentialChangeAuthorization authorization,
  ) {}

  // -- writes: always refused -----------------------------------------------

  @override
  Future<Result<void>> enrollPin(
    String pin, {
    PinPolicy policy = PinPolicy.defaults,
    CredentialChangeAuthorization? authorization,
  }) async =>
      _refused();

  @override
  Future<Result<void>> enrollPattern(
    List<int> nodes, {
    PatternPolicy policy = PatternPolicy.defaults,
    CredentialChangeAuthorization? authorization,
  }) async =>
      _refused();

  @override
  Future<Result<void>> updateBiometricOptions(
          BiometricOptions? options) async =>
      _refused();

  @override
  Future<Result<void>> setRandomizedKeypadEnabled(bool enabled) async =>
      _refused();

  @override
  Future<Result<void>> setPatternVisibilityEnabled(bool enabled) async =>
      _refused();

  @override
  Future<Result<void>> clearAll() async => _refused();
}
