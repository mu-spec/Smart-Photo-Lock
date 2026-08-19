import '../../utilities/result.dart';
import '../pin_policy.dart';
import 'auth_result.dart';
import 'biometric_options.dart';
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
  Future<Result<void>> enrollPin(String pin, {PinPolicy policy = PinPolicy.defaults});

  /// Enrolls (or replaces) the pattern credential and makes it primary.
  Future<Result<void>> enrollPattern(
    List<int> nodes, {
    PatternPolicy policy = PatternPolicy.defaults,
  });

  /// Configures (or removes) the biometric accelerator.
  ///
  /// Passing null disables biometric authentication entirely.
  Future<Result<void>> updateBiometricOptions(BiometricOptions? options);

  // -- security options ---------------------------------------------------

  /// Enables/disables the randomized unlock keypad (Phase 2G).
  Future<Result<void>> setRandomizedKeypadEnabled(bool enabled);

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
