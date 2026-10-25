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

/// CR-3: the UI side of "verify an EXISTING app credential before any PIN
/// or pattern is added, replaced or changed".
///
/// The binding check lives in [CredentialManager.enrollPin] and
/// [CredentialManager.enrollPattern], which refuse to write over an
/// existing credential without a live manager-issued
/// [CredentialChangeAuthorization]. This file only obtains that grant
/// through a real PIN or pattern verification and passes it to the setup
/// step.

/// Route name of the existing-credential verification step.
const String credentialChangeVerifyRouteName = '/security/credential-verify';

/// Titles used when the credential being verified is not the one being
/// changed (for example, verifying the PIN in order to add a pattern).
const String verifyExistingPinTitle = 'Enter current PIN';
const String verifyExistingPatternTitle = 'Enter current pattern';

enum CredentialChangeGateOutcome {
  /// No usable app credential exists, so initial enrollment needs no
  /// verification.
  initialEnrollment,

  /// An existing credential was verified and a grant was issued.
  verified,

  /// Cancelled, Back, wrong credential, lockout, or a storage error.
  /// Nothing may be written.
  denied,
}

final class CredentialChangeGateResult {
  const CredentialChangeGateResult._(this.outcome, [this.authorization]);

  final CredentialChangeGateOutcome outcome;

  /// Non-null only for [CredentialChangeGateOutcome.verified].
  final CredentialChangeAuthorization? authorization;
}

/// Decides whether a credential write needs verification. If it does, the
/// user verifies an existing app credential, preferring [preferred] and
/// otherwise using the other one that is enrolled.
///
/// Biometric is hidden and refused on the verification screen. An
/// unreadable credential status fails closed ([denied]).
Future<CredentialChangeGateResult> verifyExistingCredentialForChange(
  NavigatorState navigator,
  CredentialManager manager, {
  required AuthType preferred,
  String pinTitle = verifyExistingPinTitle,
  String patternTitle = verifyExistingPatternTitle,
}) async {
  final CredentialState? state = (await manager.status()).valueOrNull;
  if (state == null) {
    return const CredentialChangeGateResult._(
      CredentialChangeGateOutcome.denied,
    );
  }
  final bool hasPin = state.hasEnrolled(AuthType.pin);
  final bool hasPattern = state.hasEnrolled(AuthType.pattern);
  if (!hasPin && !hasPattern) {
    return const CredentialChangeGateResult._(
      CredentialChangeGateOutcome.initialEnrollment,
    );
  }
  final AuthType method = state.hasEnrolled(preferred)
      ? preferred
      : (hasPin ? AuthType.pin : AuthType.pattern);

  final _ChangeVerifier verifier = _ChangeVerifier(manager, method);
  final bool? popped = await navigator.push<bool>(
    MaterialPageRoute<bool>(
      settings: const RouteSettings(name: credentialChangeVerifyRouteName),
      builder: (_) => method == AuthType.pin
          ? PinUnlockScreen(credentialManager: verifier, title: pinTitle)
          : PatternUnlockScreen(
              credentialManager: verifier,
              title: patternTitle,
            ),
    ),
  );
  final CredentialChangeAuthorization? authorization = verifier.close();

  // BOTH the manager-issued grant AND the screen's explicit success
  // completion are required.
  if (popped != true || authorization == null) {
    if (authorization != null) {
      manager.revokeCredentialChangeAuthorization(authorization);
    }
    return const CredentialChangeGateResult._(
      CredentialChangeGateOutcome.denied,
    );
  }
  return CredentialChangeGateResult._(
    CredentialChangeGateOutcome.verified,
    authorization,
  );
}

/// Owns one verified grant for the setup step that follows verification.
///
/// * [setupManager] sends the grant with every enrollment.
/// * When the app is backgrounded (`hidden`, `paused` or `detached`), the
///   grant is revoked and the setup step is closed with `false`, so app
///   switching can never be followed by a credential write.
/// * [end] revokes a grant that was never used and stops observing.
class CredentialChangeSession with WidgetsBindingObserver {
  CredentialChangeSession(this._manager, this.authorization) {
    WidgetsBinding.instance.addObserver(this);
  }

  final CredentialManager _manager;
  final CredentialChangeAuthorization authorization;

  NavigatorState? _navigator;
  Route<bool>? _setupRoute;
  bool _spent = false;
  bool _ended = false;

  /// Revoked because the app left the foreground.
  bool revokedByLifecycle = false;

  /// The manager to give the setup screen.
  CredentialManager get setupManager => _AuthorizedEnroller(
        _manager,
        authorization,
        onEnrolled: () => _spent = true,
      );

  /// Registers the setup route so it can be closed on backgrounding.
  void attach(NavigatorState navigator, Route<bool> setupRoute) {
    _navigator = navigator;
    _setupRoute = setupRoute;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (_ended || _spent) return;
      revokedByLifecycle = true;
      final Route<bool>? route = _setupRoute;
      final NavigatorState? navigator = _navigator;
      end();
      if (route != null && navigator != null && route.isActive) {
        navigator.removeRoute(route, false);
      }
    }
  }

  /// Revokes the grant (if it was not used) and stops observing.
  void end() {
    if (_ended) return;
    _ended = true;
    WidgetsBinding.instance.removeObserver(this);
    if (!_spent) {
      _manager.revokeCredentialChangeAuthorization(authorization);
    }
  }
}

/// Wraps the real manager for the verification screen only. The screen's
/// `authenticatePin`/`authenticatePattern` calls are routed through the
/// manager's credential-change verification, so the same attempt counting
/// and lockout apply. Biometric and every write are refused.
class _ChangeVerifier implements CredentialManager {
  _ChangeVerifier(this._delegate, this._method);

  final CredentialManager _delegate;
  final AuthType _method;

  CredentialChangeAuthorization? _authorization;
  bool _closed = false;

  /// Ends the verification. A grant that arrives afterwards is revoked.
  CredentialChangeAuthorization? close() {
    _closed = true;
    return _authorization;
  }

  static Result<T> _refused<T>() => Result.failure(
        StateError('Not permitted while verifying a credential change.'),
      );

  Result<AuthAttemptResult> _capture(Result<CredentialChangeAttempt> r) {
    if (r.isFailure) {
      return Result.failure(r.errorOrNull!);
    }
    final CredentialChangeAttempt attempt = r.valueOrNull!;
    final CredentialChangeAuthorization? granted = attempt.authorization;
    if (granted != null) {
      if (_closed) {
        _delegate.revokeCredentialChangeAuthorization(granted);
      } else {
        final CredentialChangeAuthorization? previous = _authorization;
        if (previous != null && !identical(previous, granted)) {
          _delegate.revokeCredentialChangeAuthorization(previous);
        }
        _authorization = granted;
      }
    }
    return Result.success(attempt.result);
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
    return _capture(await _delegate.verifyPinForCredentialChange(pin));
  }

  @override
  Future<Result<AuthAttemptResult>> authenticatePattern(List<int> nodes) async {
    if (_closed || _method != AuthType.pattern) return _refused();
    return _capture(await _delegate.verifyPatternForCredentialChange(nodes));
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
  ) =>
      _delegate.revokeCredentialChangeAuthorization(authorization);

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

/// Sends the verified grant with every enrollment made by the setup step.
/// Everything else goes to the real manager unchanged.
class _AuthorizedEnroller implements CredentialManager {
  _AuthorizedEnroller(
    this._delegate,
    this._authorization, {
    required this.onEnrolled,
  });

  final CredentialManager _delegate;
  final CredentialChangeAuthorization _authorization;
  final void Function() onEnrolled;

  Result<void> _track(Result<void> result) {
    if (result.isSuccess) onEnrolled();
    return result;
  }

  @override
  Future<Result<void>> enrollPin(
    String pin, {
    PinPolicy policy = PinPolicy.defaults,
    CredentialChangeAuthorization? authorization,
  }) async =>
      _track(
        await _delegate.enrollPin(
          pin,
          policy: policy,
          authorization: _authorization,
        ),
      );

  @override
  Future<Result<void>> enrollPattern(
    List<int> nodes, {
    PatternPolicy policy = PatternPolicy.defaults,
    CredentialChangeAuthorization? authorization,
  }) async =>
      _track(
        await _delegate.enrollPattern(
          nodes,
          policy: policy,
          authorization: _authorization,
        ),
      );

  @override
  Future<Result<CredentialState>> status() => _delegate.status();

  @override
  Future<Result<AuthAttemptResult>> authenticatePin(String pin) =>
      _delegate.authenticatePin(pin);

  @override
  Future<Result<AuthAttemptResult>> authenticatePattern(List<int> nodes) =>
      _delegate.authenticatePattern(nodes);

  @override
  Future<Result<AuthAttemptResult>> authenticateBiometric({
    String reason = 'Unlock Smart App Lock',
  }) =>
      _delegate.authenticateBiometric(reason: reason);

  @override
  Future<Result<CredentialChangeAttempt>> verifyPinForCredentialChange(
    String pin,
  ) =>
      _delegate.verifyPinForCredentialChange(pin);

  @override
  Future<Result<CredentialChangeAttempt>> verifyPatternForCredentialChange(
    List<int> nodes,
  ) =>
      _delegate.verifyPatternForCredentialChange(nodes);

  @override
  void revokeCredentialChangeAuthorization(
    CredentialChangeAuthorization authorization,
  ) =>
      _delegate.revokeCredentialChangeAuthorization(authorization);

  @override
  Future<Result<void>> updateBiometricOptions(BiometricOptions? options) =>
      _delegate.updateBiometricOptions(options);

  @override
  Future<Result<void>> setRandomizedKeypadEnabled(bool enabled) =>
      _delegate.setRandomizedKeypadEnabled(enabled);

  @override
  Future<Result<void>> setPatternVisibilityEnabled(bool enabled) =>
      _delegate.setPatternVisibilityEnabled(enabled);

  @override
  Future<Result<void>> clearAll() => _delegate.clearAll();
}
