import 'package:flutter/material.dart';

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

/// H-3 F4: verify the configured PRIMARY Smart App Lock credential before
/// a security setting is turned on (currently: enabling biometric unlock).
///
/// Deliberately separate from the CR-3 credential-change flow:
///  * the PIN/pattern screens are reused, but attempts go through the
///    manager's NORMAL [CredentialManager.authenticatePin] /
///    [CredentialManager.authenticatePattern] (same attempt counting and
///    lockout as any unlock);
///  * it never calls `verifyPinForCredentialChange` /
///    `verifyPatternForCredentialChange`, and never issues, revokes,
///    consumes or replaces a [CredentialChangeAuthorization];
///  * biometric is hidden and refused, and every write is refused;
///  * the result is a one-shot value for the current operation. No token
///    or reusable authorization exists: the verifier is closed as soon as
///    the screen is gone, and later successes are ignored.

/// Route name of the setting-change verification step.
const String appCredentialVerifyRouteName = '/security/app-credential-verify';

const String appCredentialVerifyPinTitle = 'Enter current PIN';
const String appCredentialVerifyPatternTitle = 'Enter current pattern';

enum AppCredentialVerificationOutcome {
  /// The primary credential was entered correctly on the screen, and the
  /// screen completed with an explicit success.
  verified,

  /// No usable primary app credential exists (or its status is
  /// unreadable). Nothing may be enabled.
  unavailable,

  /// Back, cancel, wrong credential, lockout, or a storage error.
  denied,
}

final class AppCredentialVerificationResult {
  const AppCredentialVerificationResult._(this.outcome, [this.method]);

  final AppCredentialVerificationOutcome outcome;

  /// The credential type that was verified. Non-null only when
  /// [outcome] is [AppCredentialVerificationOutcome.verified].
  final AuthType? method;

  bool get isVerified => outcome == AppCredentialVerificationOutcome.verified;
}

/// Asks the user for the configured primary app credential.
///
/// Returns [AppCredentialVerificationOutcome.verified] only when BOTH the
/// manager reported an [AuthSuccess] of the primary type through this
/// call's verifier AND the screen popped with `true`.
Future<AppCredentialVerificationResult> verifyPrimaryAppCredential(
  NavigatorState navigator,
  CredentialManager manager,
) async {
  final CredentialState? state = (await manager.status()).valueOrNull;
  final AuthType? primary = state?.primary;
  if (state == null ||
      primary == null ||
      (primary != AuthType.pin && primary != AuthType.pattern) ||
      !state.hasEnrolled(primary)) {
    return const AppCredentialVerificationResult._(
      AppCredentialVerificationOutcome.unavailable,
    );
  }

  final _SettingChangeVerifier verifier =
      _SettingChangeVerifier(manager, primary);
  final bool? popped = await navigator.push<bool>(
    MaterialPageRoute<bool>(
      settings: const RouteSettings(name: appCredentialVerifyRouteName),
      builder: (_) => primary == AuthType.pin
          ? PinUnlockScreen(
              credentialManager: verifier,
              title: appCredentialVerifyPinTitle,
            )
          : PatternUnlockScreen(
              credentialManager: verifier,
              title: appCredentialVerifyPatternTitle,
            ),
    ),
  );
  final bool succeeded = verifier.close();

  if (popped != true || !succeeded) {
    return const AppCredentialVerificationResult._(
      AppCredentialVerificationOutcome.denied,
    );
  }
  return AppCredentialVerificationResult._(
    AppCredentialVerificationOutcome.verified,
    primary,
  );
}

/// Wraps the real manager for ONE verification screen.
///
/// Only the primary credential's normal authentication is forwarded.
/// Biometric, every write, and the whole CR-3 grant API are refused
/// without touching the real manager.
class _SettingChangeVerifier implements CredentialManager {
  _SettingChangeVerifier(this._delegate, this._method);

  final CredentialManager _delegate;
  final AuthType _method;

  bool _closed = false;
  bool _succeeded = false;

  /// Ends the verification and reports whether a matching success was
  /// observed. Attempts after this are refused.
  bool close() {
    _closed = true;
    return _succeeded;
  }

  static Result<T> _refused<T>() => Result.failure(
        StateError('Not permitted while verifying the app credential.'),
      );

  Result<AuthAttemptResult> _record(Result<AuthAttemptResult> result) {
    final AuthAttemptResult? outcome = result.valueOrNull;
    if (!_closed && outcome is AuthSuccess && outcome.type == _method) {
      _succeeded = true;
    }
    return result;
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
    if (_closed || _method != AuthType.pin) return _refused();
    return _record(await _delegate.authenticatePin(pin));
  }

  @override
  Future<Result<AuthAttemptResult>> authenticatePattern(List<int> nodes) async {
    if (_closed || _method != AuthType.pattern) return _refused();
    return _record(await _delegate.authenticatePattern(nodes));
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

  // -- CR-3 grant API: never used by this flow ---------------------------

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

  /// Intentionally a no-op: this flow owns no grant and must never revoke
  /// one that belongs to a credential-change session.
  @override
  void revokeCredentialChangeAuthorization(
    CredentialChangeAuthorization authorization,
  ) {}

  // -- writes: all refused -------------------------------------------------

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
