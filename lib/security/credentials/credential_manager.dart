import '../../utilities/result.dart';
import '../pin_policy.dart';
import 'auth_result.dart';
import 'biometric_options.dart';
import 'credential_change_authorization.dart';
import 'credential_state.dart';
import 'pattern_policy.dart';

/// Credential lifecycle boundary — enrollment, status, authentication and
/// clearing for PIN, pattern and biometric methods.
///
/// This is the single facade screens will use. All persistence happens
/// through the repositories (encrypted settings); all attempt/lockout logic
/// lives in the pure [CredentialStateMachine].
abstract interface class CredentialManager {
  /// Current credential configuration + attempt/lockout counters.
  Future<Result<CredentialState>> status();

  // -- enrollment ---------------------------------------------------------

  /// Enrolls (or replaces) the PIN credential and makes it primary.
  ///
  /// CR-3: when ANY usable app credential (PIN or pattern) already exists,
  /// the write is refused with [CredentialChangeNotAuthorized] unless
  /// [authorization] is a live grant issued by this manager through
  /// [verifyPinForCredentialChange] or [verifyPatternForCredentialChange].
  /// The grant is consumed before anything is written. Initial enrollment
  /// (no usable credential) needs no authorization.
  Future<Result<void>> enrollPin(
    String pin, {
    PinPolicy policy = PinPolicy.defaults,
    CredentialChangeAuthorization? authorization,
  });

  /// Enrolls (or replaces) the pattern credential and makes it primary.
  ///
  /// The CR-3 authorization rules are the same as for [enrollPin].
  Future<Result<void>> enrollPattern(
    List<int> nodes, {
    PatternPolicy policy = PatternPolicy.defaults,
    CredentialChangeAuthorization? authorization,
  });

  // -- CR-3: credential-change authorization ------------------------------

  /// Verifies the EXISTING PIN for a credential change. The attempt goes
  /// through the normal authentication path, so attempts are counted and an
  /// active lockout blocks it. Only an [AuthSuccess] carries a
  /// [CredentialChangeAuthorization]. Issuing a grant supersedes any
  /// earlier one.
  Future<Result<CredentialChangeAttempt>> verifyPinForCredentialChange(
    String pin,
  );

  /// Pattern counterpart of [verifyPinForCredentialChange].
  Future<Result<CredentialChangeAttempt>> verifyPatternForCredentialChange(
    List<int> nodes,
  );

  /// Invalidates [authorization] immediately. Revoking an unknown, used or
  /// already-revoked handle does nothing.
  void revokeCredentialChangeAuthorization(
    CredentialChangeAuthorization authorization,
  );

  /// Configures (or removes) the biometric accelerator.
  ///
  /// Passing null disables biometric authentication entirely.
  Future<Result<void>> updateBiometricOptions(BiometricOptions? options);

  // -- security options ---------------------------------------------------

  /// Enables/disables the randomized unlock keypad (Phase 2G).
  Future<Result<void>> setRandomizedKeypadEnabled(bool enabled);

  /// Enables/disables pattern trail visibility on the unlock screen
  /// (Phase 2K).
  Future<Result<void>> setPatternVisibilityEnabled(bool enabled);

  // -- authentication -----------------------------------------------------

  Future<Result<AuthAttemptResult>> authenticatePin(String pin);

  Future<Result<AuthAttemptResult>> authenticatePattern(List<int> nodes);

  Future<Result<AuthAttemptResult>> authenticateBiometric({
    String reason = 'Unlock Smart App Lock',
  });

  // -- lifecycle ----------------------------------------------------------

  /// Removes every enrolled credential and resets counters.
  Future<Result<void>> clearAll();
}
