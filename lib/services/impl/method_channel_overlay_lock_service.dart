import 'package:flutter/services.dart';

import '../../utilities/result.dart';
import '../overlay_lock_service.dart';

/// Production [OverlayLockService] over the native
/// `smart_app_lock/overlay` channel (Phase 4D).
///
/// Capability state comes from `Settings.canDrawOverlays`; the grant is
/// made exclusively through the system overlay-permission screen. The
/// challenge-window methods fail closed until the lock-screen phase —
/// never fabricate a lock screen.
class MethodChannelOverlayLockService implements OverlayLockService {
  MethodChannelOverlayLockService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('smart_app_lock/overlay');

  final MethodChannel _channel;

  @override
  Future<Result<bool>> canDrawOverlays() async {
    try {
      final bool? granted =
          await _channel.invokeMethod<bool>('isOverlayGranted');
      return Result.success(granted ?? false);
    } on PlatformException catch (e) {
      return Result.failure(e);
    } on MissingPluginException catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<void>> requestOverlayPermission() async {
    try {
      final bool? opened =
          await _channel.invokeMethod<bool>('requestOverlayPermission');
      if (opened == true) {
        return Result.success(null);
      }
      return Result.failure(
        StateError('Could not open the overlay permission screen.'),
      );
    } on PlatformException catch (e) {
      return Result.failure(e);
    } on MissingPluginException catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<void>> showLockChallenge(String packageName) async {
    // The overlay lock window lands with the lock-screen phase.
    return Result.failure(StateError('Lock challenge not implemented yet.'));
  }

  @override
  Future<Result<void>> hideLockChallenge() async {
    return Result.failure(StateError('Lock challenge not implemented yet.'));
  }
}
