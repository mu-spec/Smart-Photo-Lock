import 'package:flutter/material.dart';

import '../../../data/repositories/protected_apps_repository.dart';
import '../../../security/credentials/auth_result.dart';
import '../../../security/credentials/auth_type.dart';
import '../../../security/credentials/biometric_options.dart';
import '../../../security/credentials/credential_change_authorization.dart';
import '../../../security/credentials/credential_manager.dart';
import '../../../security/credentials/credential_state.dart';
import '../../../security/credentials/pattern_policy.dart';
import '../../../security/pin_policy.dart';
import '../../../utilities/result.dart';
import '../pattern/pattern_unlock_screen.dart';
import '../pin/pin_unlock_screen.dart';

/// CR-2 fix: removing protection requires Smart App Lock app-credential
/// authentication.
///
/// The gate never trusts UI state, such as a route popping `true`.
///
///  * The confirmation screen (the existing PIN or pattern unlock screen)
///    receives a wrapped [CredentialManager]. That wrapper records an
///    [AuthSuccess] only when the REAL manager returns one for an app
///    credential (PIN or pattern). Attempts, lockouts and cooldowns are the
///    real manager's, shared with the lock engine.
///  * Biometric is hidden and refused on this surface. The system prompt can
///    accept the DEVICE credential (H-3), and the approved policy requires
///    the app's own credential.
///  * Enrollment and settings changes are refused through the wrapper.
///  * Only this library can mint an [UnprotectAuthorization], and only from a
///    recorded success. The proof is in memory only, so it dies with the
///    process. It is bound to the exact package set, expires after
///    [UnprotectAuthorization.maxAge], and is consumed once per package by
///    [removeProtectionWith].
///
/// Cancellation, Back, a wrong credential, a lockout, a storage failure,
/// teardown or process death all yield no authorization, so nothing is
/// removed.

/// Why an unprotect request was not authorized.
enum UnprotectDenial {
  /// The user dismissed the confirmation (Back or cancel), or the route was
  /// torn down before a verified credential was recorded.
  notAuthenticated,

  /// No PIN and no pattern is enrolled. There is no app credential to verify.
  noAppCredential,

  /// The credential state could not be read. Fail closed.
  credentialUnavailable,
}

/// The outcome of [requestUnprotectAuthorization]: exactly one of
/// [authorization] or [denial] is non-null.
final class UnprotectRequestResult {
  const UnprotectRequestResult._authorized(UnprotectAuthorization this.authorization)
      : denial = null;

  const UnprotectRequestResult._denied(UnprotectDenial this.denial)
      : authorization = null;

  final UnprotectAuthorization? authorization;
  final UnprotectDenial? denial;

  bool get isAuthorized => authorization != null;
}

/// A one-time, in-memory, package-scoped proof that the app credential was
/// verified by the real [CredentialManager].
///
/// The constructor is private to this library. UI code cannot fabricate one.
final class UnprotectAuthorization {
  UnprotectAuthorization._({
    required Set<String> packages,
    required this.method,
    required this.verifiedAt,
  }) : packages = Set<String>.unmodifiable(packages);

  /// How long a proof stays usable after the credential was verified.
  static const Duration maxAge = Duration(seconds: 60);

  /// The exact packages this proof may unprotect.
  final Set<String> packages;

  /// The verified app credential (PIN or pattern; never biometric).
  final AuthType method;

  /// When the real credential manager reported success.
  final DateTime verifiedAt;

  final Set<String> _consumed = <String>{};

  /// Whether [packageName] may still be unprotected with this proof at [now].
  bool allows(String packageName, DateTime now) {
    if (!packages.contains(packageName) || _consumed.contains(packageName)) {
      return false;
    }
    final Duration age = now.difference(verifiedAt);
    // A clock that moved backwards is treated as invalid (fail closed).
    return !age.isNegative && age <= maxAge;
  }
}

/// Asks the user to confirm with their Smart App Lock PIN or pattern before
/// [packages] lose protection.
///
/// [navigator] and [credentials] are captured by the caller before any
/// await, so no BuildContext crosses an async gap. [clock] is a test seam.
Future<UnprotectRequestResult> requestUnprotectAuthorization({
  required NavigatorState navigator,
  required CredentialManager credentials,
  required Set<String> packages,
  DateTime Function()? clock,
}) async {
  final DateTime Function() now = clock ?? DateTime.now;
  final Result<CredentialState> statusResult = await credentials.status();
  final CredentialState? state = statusResult.valueOrNull;
  if (statusResult.isFailure || state == null) {
    return const UnprotectRequestResult._denied(
      UnprotectDenial.credentialUnavailable,
    );
  }
  final bool hasPin = state.hasEnrolled(AuthType.pin);
  final bool hasPattern = state.hasEnrolled(AuthType.pattern);
  if (!hasPin && !hasPattern) {
    return const UnprotectRequestResult._denied(UnprotectDenial.noAppCredential);
  }
  if (!navigator.mounted) {
    return const UnprotectRequestResult._denied(
      UnprotectDenial.notAuthenticated,
    );
  }

  // Same routing as the lock challenge: the PRIMARY app credential.
  final bool usePattern =
      hasPattern && (!hasPin || state.primary == AuthType.pattern);
  final _AppCredentialVerifier verifier =
      _AppCredentialVerifier(credentials, now);
  final bool? popped = await navigator.push<bool>(
    MaterialPageRoute<bool>(
      settings: const RouteSettings(name: unprotectConfirmRouteName),
      builder: (BuildContext _) => usePattern
          ? PatternUnlockScreen(
              credentialManager: verifier,
              title: unprotectConfirmTitle,
            )
          : PinUnlockScreen(
              credentialManager: verifier,
              title: unprotectConfirmTitle,
            ),
    ),
  );
  verifier.close();

  final AuthType? method = verifier.verifiedMethod;
  final DateTime? verifiedAt = verifier.verifiedAt;
  // BOTH the real manager's recorded success AND the screen's explicit
  // success completion are required. Neither alone is enough.
  if (popped != true || method == null || verifiedAt == null) {
    return const UnprotectRequestResult._denied(
      UnprotectDenial.notAuthenticated,
    );
  }
  return UnprotectRequestResult._authorized(
    UnprotectAuthorization._(
      packages: packages,
      method: method,
      verifiedAt: verifiedAt,
    ),
  );
}

/// Removes protection from [packageName] only if [authorization] covers it,
/// has not expired, and has not already been used for it.
///
/// The proof is consumed for the package BEFORE the repository call, so a
/// failed write still needs a fresh confirmation to retry (fail closed).
Future<Result<void>> removeProtectionWith(
  UnprotectAuthorization authorization,
  ProtectedAppsRepository repository,
  String packageName, {
  DateTime Function()? clock,
}) async {
  final DateTime now = (clock ?? DateTime.now)();
  if (!authorization.allows(packageName, now)) {
    return Result.failure(
      StateError('Unprotect is not authorized for $packageName.'),
    );
  }
  authorization._consumed.add(packageName);
  return repository.remove(packageName);
}

/// Route name of the confirmation screen (diagnostics and tests).
const String unprotectConfirmRouteName = '/apps/unprotect-confirm';

/// Title shown on the confirmation screen.
const String unprotectConfirmTitle = 'Confirm to remove protection';

/// Wraps the real manager for the confirmation surface only.
class _AppCredentialVerifier implements CredentialManager {
  _AppCredentialVerifier(this._delegate, this._now);

  final CredentialManager _delegate;
  final DateTime Function() _now;

  AuthType? verifiedMethod;
  DateTime? verifiedAt;
  bool _closed = false;

  /// After the route resolves, nothing can record a success anymore.
  void close() => _closed = true;

  static Result<T> _refused<T>() => Result.failure(
        StateError('Not permitted while confirming an unprotect.'),
      );

  void _record(Result<AuthAttemptResult> result) {
    if (_closed) return;
    final AuthAttemptResult? outcome = result.valueOrNull;
    if (outcome is AuthSuccess &&
        (outcome.type == AuthType.pin || outcome.type == AuthType.pattern)) {
      verifiedMethod = outcome.type;
      verifiedAt = _now();
    }
  }

  @override
  Future<Result<CredentialState>> status() async {
    final Result<CredentialState> result = await _delegate.status();
    final CredentialState? state = result.valueOrNull;
    if (state == null) return result;
    // Hide biometric so the screen offers only the app credential.
    return Result.success(
      state.copyWith(
        enrolled: state.enrolled.difference(<AuthType>{AuthType.biometric}),
      ),
    );
  }

  @override
  Future<Result<AuthAttemptResult>> authenticatePin(String pin) async {
    final Result<AuthAttemptResult> result =
        await _delegate.authenticatePin(pin);
    _record(result);
    return result;
  }

  @override
  Future<Result<AuthAttemptResult>> authenticatePattern(List<int> nodes) async {
    final Result<AuthAttemptResult> result =
        await _delegate.authenticatePattern(nodes);
    _record(result);
    return result;
  }

  @override
  Future<Result<AuthAttemptResult>> authenticateBiometric({
    String reason = 'Unlock Smart App Lock',
  }) async =>
      Result.success(
        const AuthFailure(
          reason: AuthFailureReason.notAvailable,
          remainingAttempts: 0,
        ),
      );

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

  // CR-3: an unprotect confirmation must never mint credential-change
  // grants.
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

  @override
  void revokeCredentialChangeAuthorization(
    CredentialChangeAuthorization authorization,
  ) {}

  @override
  Future<Result<void>> updateBiometricOptions(BiometricOptions? options) async =>
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
