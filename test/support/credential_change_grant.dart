import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/credential_change_authorization.dart';
import 'package:smart_app_lock/security/credentials/credential_manager.dart';
import 'package:smart_app_lock/utilities/result.dart';

/// CR-3 test helper. Obtains a REAL credential-change grant by verifying
/// the existing PIN through the manager's own verification API. Throws if
/// the verification does not succeed, so a test can never silently go on
/// without authorization.
Future<CredentialChangeAuthorization> grantWithPin(
  CredentialManager manager,
  String currentPin,
) async =>
    _grantFrom(await manager.verifyPinForCredentialChange(currentPin));

/// Pattern counterpart of [grantWithPin].
Future<CredentialChangeAuthorization> grantWithPattern(
  CredentialManager manager,
  List<int> currentPattern,
) async =>
    _grantFrom(await manager.verifyPatternForCredentialChange(currentPattern));

CredentialChangeAuthorization _grantFrom(
  Result<CredentialChangeAttempt> result,
) {
  final CredentialChangeAttempt? attempt = result.valueOrNull;
  if (attempt == null ||
      attempt.result is! AuthSuccess ||
      attempt.authorization == null) {
    throw StateError(
      'CR-3 test helper: existing-credential verification did not succeed '
      '(${attempt?.result}).',
    );
  }
  return attempt.authorization!;
}
