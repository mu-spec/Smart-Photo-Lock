import 'package:flutter/services.dart';

import '../../utilities/result.dart';
import '../accessibility_lock_service.dart';

/// Production [AccessibilityLockService] over the native
/// `smart_app_lock/accessibility` channel (Phase 4C).
///
/// Capability state comes from the system's ENABLED_ACCESSIBILITY_SERVICES
/// setting; enabling happens exclusively through the system Accessibility
/// settings screen. The foreground-package stream is deliberately empty
/// until the lock-engine phase wires detection.
class MethodChannelAccessibilityLockService
    implements AccessibilityLockService {
  MethodChannelAccessibilityLockService({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('smart_app_lock/accessibility');

  final MethodChannel _channel;

  @override
  Future<Result<bool>> isServiceEnabled() async {
    try {
      final bool? enabled =
          await _channel.invokeMethod<bool>('isAccessibilityEnabled');
      return Result.success(enabled ?? false);
    } on PlatformException catch (e) {
      return Result.failure(e);
    } on MissingPluginException catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<void>> requestServiceEnable() async {
    try {
      final bool? opened =
          await _channel.invokeMethod<bool>('requestAccessibilityEnable');
      if (opened == true) {
        return Result.success(null);
      }
      return Result.failure(
        StateError('Could not open the accessibility settings screen.'),
      );
    } on PlatformException catch (e) {
      return Result.failure(e);
    } on MissingPluginException catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Stream<Result<String>> get foregroundPackages {
    // Detection wiring lands with the lock-engine phase; until then the
    // stream emits nothing (fail-closed: never fabricate events).
    return const Stream<Result<String>>.empty();
  }
}
