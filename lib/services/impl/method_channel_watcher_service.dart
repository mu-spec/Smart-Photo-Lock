import 'package:flutter/services.dart';

import '../../utilities/result.dart';
import '../watcher_service.dart';

/// Production [WatcherService] over the native `smart_app_lock/watcher`
/// channel (Phase 5 mobile-QA fix).
class MethodChannelWatcherService implements WatcherService {
  MethodChannelWatcherService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('smart_app_lock/watcher');

  final MethodChannel _channel;

  @override
  Future<Result<bool>> start() async {
    try {
      final bool? started = await _channel.invokeMethod<bool>('start');
      return Result.success(started ?? false);
    } on PlatformException catch (e) {
      return Result.failure(e);
    } on MissingPluginException catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<bool>> stop() async {
    try {
      final bool? stopped = await _channel.invokeMethod<bool>('stop');
      return Result.success(stopped ?? false);
    } on PlatformException catch (e) {
      return Result.failure(e);
    } on MissingPluginException catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<bool>> isRunning() async {
    try {
      final bool? running = await _channel.invokeMethod<bool>('isRunning');
      return Result.success(running ?? false);
    } on PlatformException catch (e) {
      return Result.failure(e);
    } on MissingPluginException catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<void>> configureProtection({
    required bool enabled,
    required Set<String> protectedPackages,
  }) =>
      _invokeVoid('configureProtection', <String, dynamic>{
        'enabled': enabled,
        'protectedPackages': protectedPackages.toList(growable: false),
      });

  @override
  Future<Result<void>> heartbeat() => _invokeVoid('heartbeat');

  @override
  Future<Result<void>> setGracePeriod(Duration period) =>
      _invokeVoid('setGracePeriod', <String, dynamic>{
        'milliseconds': period.isNegative ? 0 : period.inMilliseconds,
      });

  @override
  Future<Result<void>> authorizePackage(
    String packageName, {
    Duration sessionWindow = const Duration(minutes: 2),
  }) =>
      _invokeVoid('authorizePackage', <String, dynamic>{
        'packageName': packageName,
        'sessionWindowMilliseconds':
            sessionWindow.isNegative ? 0 : sessionWindow.inMilliseconds,
      });

  @override
  Future<Result<void>> revokeAllAuthorizations() =>
      _invokeVoid('revokeAllAuthorizations');

  @override
  Future<Result<void>> markEngineUnavailable() =>
      _invokeVoid('markEngineUnavailable');

  @override
  Future<Result<String?>> takePendingChallenge() async {
    try {
      return Result.success(
        await _channel.invokeMethod<String>('takePendingChallenge'),
      );
    } on PlatformException catch (e) {
      return Result.failure(e);
    } on MissingPluginException catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<ProtectionEngineHealth>> getHealth() async {
    try {
      final Map<dynamic, dynamic>? value =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('getHealth');
      if (value == null) {
        return Result.failure(StateError('Native health was unavailable.'));
      }
      return Result.success(ProtectionEngineHealth.fromMap(value));
    } on PlatformException catch (e) {
      return Result.failure(e);
    } on MissingPluginException catch (e) {
      return Result.failure(e);
    }
  }

  Future<Result<void>> _invokeVoid(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    try {
      final bool? applied =
          await _channel.invokeMethod<bool>(method, arguments);
      return applied == true
          ? Result.success(null)
          : Result.failure(StateError('Native watcher rejected $method.'));
    } on PlatformException catch (e) {
      return Result.failure(e);
    } on MissingPluginException catch (e) {
      return Result.failure(e);
    }
  }
}
