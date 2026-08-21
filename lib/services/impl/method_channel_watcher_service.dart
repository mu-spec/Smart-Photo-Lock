import 'package:flutter/services.dart';

import '../../utilities/result.dart';
import '../watcher_service.dart';

/// Production [WatcherService] over the native `smart_app_lock/watcher`
/// channel (Phase 5 mobile-QA fix).
class MethodChannelWatcherService implements WatcherService {
  MethodChannelWatcherService({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('smart_app_lock/watcher');

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
}
