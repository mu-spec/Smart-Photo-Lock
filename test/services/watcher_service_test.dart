import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/services/impl/method_channel_watcher_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/watcher_service.dart';

/// Phase 5 mobile-QA fix: the watcher foreground-service bridge — wire
/// format on the Dart side and the static test service.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('smart_app_lock/watcher');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('MethodChannelWatcherService', () {
    test('start/stop/isRunning relay the native results', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'start') {
          return true;
        }
        if (call.method == 'stop') {
          return true;
        }
        if (call.method == 'isRunning') {
          return true;
        }
        return null;
      });
      final WatcherService service = MethodChannelWatcherService();
      expect((await service.start()).valueOrNull, isTrue);
      expect((await service.stop()).valueOrNull, isTrue);
      expect((await service.isRunning()).valueOrNull, isTrue);
    });

    test('a native false result is reported as false', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async => false);
      final WatcherService service = MethodChannelWatcherService();
      expect((await service.start()).valueOrNull, isFalse);
      expect((await service.stop()).valueOrNull, isFalse);
      expect((await service.isRunning()).valueOrNull, isFalse);
    });

    test('platform errors fail closed', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        throw PlatformException(code: 'watcher_error', message: 'boom');
      });
      final WatcherService service = MethodChannelWatcherService();
      expect((await service.start()).isFailure, isTrue);
      expect((await service.stop()).isFailure, isTrue);
      expect((await service.isRunning()).isFailure, isTrue);
      expect((await service.heartbeat()).isFailure, isTrue);
      expect((await service.getHealth()).isFailure, isTrue);
    });

    test('bootstrap configuration, heartbeat, pending and health decode',
        () async {
      final List<MethodCall> calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        if (call.method == 'takePendingChallenge') return 'com.example.locked';
        if (call.method == 'getHealth') {
          return <String, dynamic>{
            'protectionConfigured': true,
            'serviceRunning': true,
            'engineState': 'recovering',
            'notificationPermissionGranted': false,
            'lastError': 'recovering',
          };
        }
        return true;
      });
      final WatcherService service = MethodChannelWatcherService();

      expect(
        (await service.configureProtection(
          enabled: true,
          protectedPackages: {'com.example.locked'},
        ))
            .isSuccess,
        isTrue,
      );
      expect((await service.heartbeat()).isSuccess, isTrue);
      expect((await service.markEngineUnavailable()).isSuccess, isTrue);
      expect(
        (await service.takePendingChallenge()).valueOrNull,
        'com.example.locked',
      );
      final health = (await service.getHealth()).valueOrNull!;
      expect(health.engineState, ProtectionEngineState.recovering);
      expect(health.notificationPermissionGranted, isFalse);
      expect(
        calls.first.arguments,
        <String, dynamic>{
          'enabled': true,
          'protectedPackages': <String>['com.example.locked'],
        },
      );
    });
  });

  group('StaticWatcherService', () {
    test('lifecycle counters and running state', () async {
      final StaticWatcherService service = StaticWatcherService();

      expect((await service.isRunning()).valueOrNull, isFalse);
      expect((await service.start()).valueOrNull, isTrue);
      expect(service.startCalls, 1);
      expect(service.running, isTrue);
      expect((await service.isRunning()).valueOrNull, isTrue);

      expect((await service.stop()).valueOrNull, isTrue);
      expect(service.stopCalls, 1);
      expect(service.running, isFalse);

      await service.configureProtection(
        enabled: true,
        protectedPackages: {'com.example.locked'},
      );
      await service.start();
      await service.heartbeat();
      expect((await service.getHealth()).valueOrNull!.engineState,
          ProtectionEngineState.healthy);
      await service.markEngineUnavailable();
      expect((await service.getHealth()).valueOrNull!.engineState,
          ProtectionEngineState.recovering);
    });
  });
}
