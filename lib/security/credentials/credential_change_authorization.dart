import 'auth_result.dart';
import 'auth_type.dart';

/// CR-3: an opaque handle proving that an EXISTING Smart App Lock app
/// credential (PIN or pattern) was just verified, specifically so that the
/// credential set can be changed.
///
/// The handle itself carries **no authority**. Its validity lives entirely
/// in the issuing [CredentialManager]'s in-memory registry. A handle built
/// any other way is unknown to that registry and is rejected. Validity ends
/// when any of these happens:
///
///  * one enrollment uses it (single use);
///  * its TTL passes;
///  * the credential set changes, or a newer authorization is issued;
///  * an explicit revoke (for example when the app is backgrounded);
///  * the process dies (it is never persisted).
///
/// Biometric (and therefore the device credential) can never produce one.
final class CredentialChangeAuthorization {
  /// Creates an unregistered handle. Only a [CredentialManager] can make a
  /// handle valid, by registering it at issue time.
  CredentialChangeAuthorization.handle({required this.method})
      : assert(method == AuthType.pin || method == AuthType.pattern);

  /// The existing app credential that was verified.
  final AuthType method;
}

/// The outcome of a credential-change verification attempt.
///
/// [authorization] is non-null if and only if [result] is [AuthSuccess].
final class CredentialChangeAttempt {
  const CredentialChangeAttempt(this.result, [this.authorization]);

  /// The ordinary attempt outcome. The attempt was counted and lockouts were
  /// applied exactly as for an unlock attempt.
  final AuthAttemptResult result;

  final CredentialChangeAuthorization? authorization;
}

/// Why an enrollment was refused by the CR-3 write gate.
enum CredentialChangeDenial {
  /// An app credential exists and no authorization was supplied.
  missing,

  /// The handle was never issued by this manager, was already used, or was
  /// revoked or superseded.
  unknown,

  /// The credential set changed after the authorization was issued.
  stale,

  /// The authorization is older than its TTL, or the clock moved backwards.
  expired,

  /// An attempt lockout is active.
  lockedOut,
}

/// The error returned (inside `Result.failure`) when an enrollment is
/// refused because the existing credential was not verified.
final class CredentialChangeNotAuthorized implements Exception {
  const CredentialChangeNotAuthorized(this.denial);

  final CredentialChangeDenial denial;

  @override
  String toString() =>
      'CredentialChangeNotAuthorized(${denial.name}): verify the existing '
      'PIN or pattern before changing credentials.';
}
