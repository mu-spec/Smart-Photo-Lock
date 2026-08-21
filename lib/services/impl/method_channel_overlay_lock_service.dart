import 'package:flutter/services.dart';

import '../../utilities/result.dart';
import '../overlay_lock_service.dart';

/// Production [OverlayLockService] over the native
/// `smart_app_lock/overlay` channel (Phase 4D capability state; 5D
/// challenge methods).
///
/// Capability state comes from `Settings.canDrawOverlays`; the grant is
/// made exclusively through the system overlay-permission screen. Phase
/// 5D: `showLockChallenge` presents the challenge by bringing Smart App
/// Lock's own activity to the foreground (the TYPE_APPLICATION_OVERLAY
/// lock window lands in a later lock-screen phase).
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
    try {
      final bool? shown =
          await _channel.invokeMethod<bool>('showLockChallenge');
      if (shown == true) {
        return Result.success(null);
      }
      return Result.failure(
        StateError('Could not show the lock challenge.'),
      );
    } on PlatformException catch (e) {
      return Result.failure(e);
    } on MissingPluginException catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<void>> hideLockChallenge() async {
    try {
      final bool? hidden =
          await _channel.invokeMethod<bool>('hideLockChallenge');
      if (hidden == true) {
        return Result.success(null);
      }
      return Result.failure(
        StateError('Could not dismiss the lock challenge.'),
      );
    } on PlatformException catch (e) {
      return Result.failure(e);
    } on MissingPluginException catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<void>> setSecureWindow(bool secure) async {
    try {
      final bool? applied = await _channel.invokeMethod<bool>(
        'setSecureWindow',
        <String, dynamic>{'secure': secure},
      );
      if (applied == true) {
        return Result.success(null);
      }
      return Result.failure(
        StateError('Could not toggle the secure window.'),
      );
    } on PlatformException catch (e) {
      return Result.failure(e);
    } on MissingPluginException catch (e) {
      return Result.failure(e);
    }
  }
}
