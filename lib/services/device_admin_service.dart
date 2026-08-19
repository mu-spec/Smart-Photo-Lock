import '../utilities/result.dart';

/// Bridge to `DevicePolicyManager` — anti-tamper protection.
///
/// Implemented in the hardening phase:
///  * a `DeviceAdminReceiver` subclass declared in the manifest
///  * prevents casual uninstall while locking is active
///  * (alternative strategy: uninstall via usage-access watchdog)
abstract interface class DeviceAdminService {
  Future<Result<bool>> isAdminActive();

  /// Starts the system admin-activation flow.
  Future<Result<void>> requestAdmin();

  Future<Result<void>> removeAdmin();
}
