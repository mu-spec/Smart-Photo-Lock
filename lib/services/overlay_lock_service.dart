import '../utilities/result.dart';

/// Bridge to Android's overlay API and native recovery shield.
///
/// Implemented in the lock phases:
///  * `SYSTEM_ALERT_WINDOW` + `Settings.ACTION_MANAGE_OVERLAY_PERMISSION`
///  * a `TYPE_APPLICATION_OVERLAY` window that blocks content and touches
///    while the Flutter credential challenge is brought to the foreground
///  * foreground-service recovery for isolate/process loss
abstract interface class OverlayLockService {
  /// True when the "draw over other apps" permission is granted.
  Future<Result<bool>> canDrawOverlays();

  /// Opens the system overlay-permission settings screen.
  Future<Result<void>> requestOverlayPermission();

  /// Shows the lock challenge on top of the protected app.
  Future<Result<void>> showLockChallenge(String packageName);

  /// Removes the native fail-closed shield only after Android confirms the
  /// Flutter challenge activity is resumed and ready for interaction.
  Future<Result<void>> markChallengeReady();

  /// Dismisses the lock challenge (called after a successful unlock).
  Future<Result<void>> hideLockChallenge();

  /// Phase 5O (recents hardening): toggles FLAG_SECURE on the activity
  /// window — while set, the recents snapshot and screenshots render
  /// blank, so a lock challenge never leaks through task switching.
  Future<Result<void>> setSecureWindow(bool secure);
}
