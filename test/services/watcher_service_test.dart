import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/services/impl/method_channel_watcher_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/watcher_service.dart';
import 'package:smart_app_lock/services/pending_lock_challenge.dart';

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
      messenger.setMockMethodCallHandler(
          channel, (MethodCall call) async => false);
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
      expect((await service.setGracePeriod(Duration.zero)).isFailure, isTrue);
      expect(
          (await service.authorizePackage(const PendingLockChallenge(
            packageName: 'com.example.locked',
            generation: 4,
          )))
              .isFailure,
          isTrue);
      expect((await service.revokeAllAuthorizations()).isFailure, isTrue);
      expect((await service.getHealth()).isFailure, isTrue);
    });

    test('bootstrap configuration, heartbeat, pending and health decode',
        () async {
      final List<MethodCall> calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        if (call.method == 'takePendingChallenge') {
          return <String, dynamic>{
            'packageName': 'com.example.locked',
            'generation': 4,
          };
        }
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
      expect(
        (await service.setGracePeriod(const Duration(seconds: 30))).isSuccess,
        isTrue,
      );
      expect(
        (await service.authorizePackage(const PendingLockChallenge(
          packageName: 'com.example.locked',
          generation: 4,
        )))
            .isSuccess,
        isTrue,
      );
      expect((await service.revokeAllAuthorizations()).isSuccess, isTrue);
      expect((await service.markEngineUnavailable()).isSuccess, isTrue);
      expect(
        (await service.takePendingChallenge()).valueOrNull,
        const PendingLockChallenge(
          packageName: 'com.example.locked',
          generation: 4,
        ),
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
      expect(
        calls
            .singleWhere((MethodCall c) => c.method == 'setGracePeriod')
            .arguments,
        <String, dynamic>{'milliseconds': 30000},
      );
      expect(
        calls
            .singleWhere((MethodCall c) => c.method == 'authorizePackage')
            .arguments,
        <String, dynamic>{
          'packageName': 'com.example.locked',
          'generation': 4,
          'sessionWindowMilliseconds': 120000,
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
      await service.setGracePeriod(const Duration(seconds: 30));
      expect(service.gracePeriod, const Duration(seconds: 30));
      expect(
        (await service.authorizePackage(const PendingLockChallenge(
          packageName: 'com.example.locked',
          generation: 1,
        )))
            .isSuccess,
        isTrue,
      );
      expect(service.authorizedPackages, {'com.example.locked'});
      await service.revokeAllAuthorizations();
      expect(service.authorizedPackages, isEmpty);
      expect((await service.getHealth()).valueOrNull!.engineState,
          ProtectionEngineState.healthy);
      await service.markEngineUnavailable();
      expect((await service.getHealth()).valueOrNull!.engineState,
          ProtectionEngineState.recovering);
    });

    test('a stale wake generation cannot authorize the protected package',
        () async {
      final StaticWatcherService service = StaticWatcherService();
      await service.configureProtection(
        enabled: true,
        protectedPackages: {'com.example.locked'},
      );
      service
        ..pendingChallenge = 'com.example.locked'
        ..pendingChallengeGeneration = 12;

      final result = await service.authorizePackage(
        const PendingLockChallenge(
          packageName: 'com.example.locked',
          generation: 11,
        ),
      );

      expect(result.isFailure, isTrue);
      expect(service.authorizedPackages, isEmpty);
      expect(service.pendingChallenge, 'com.example.locked');
    });
  });
}
