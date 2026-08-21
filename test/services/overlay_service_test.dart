import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/services/impl/method_channel_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/overlay_lock_service.dart';

/// Phase 4D: the overlay capability bridge — wire format on the Dart side
/// and the static test service.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('smart_app_lock/overlay');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('MethodChannelOverlayLockService', () {
    test('canDrawOverlays decodes the native state', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        expect(call.method, 'isOverlayGranted');
        return true;
      });
      final OverlayLockService service = MethodChannelOverlayLockService();
      final result = await service.canDrawOverlays();
      expect(result.isSuccess, isTrue);
      expect(result.valueOrNull, isTrue);
    });

    test('a null native result is treated as not granted', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async => null);
      final OverlayLockService service = MethodChannelOverlayLockService();
      final result = await service.canDrawOverlays();
      expect(result.isSuccess, isTrue);
      expect(result.valueOrNull, isFalse);
    });

    test('requestOverlayPermission reports the native intent result',
        () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        expect(call.method, 'requestOverlayPermission');
        return true;
      });
      final OverlayLockService service = MethodChannelOverlayLockService();
      expect((await service.requestOverlayPermission()).isSuccess, isTrue);

      messenger.setMockMethodCallHandler(channel, (MethodCall call) async => false);
      final result = await service.requestOverlayPermission();
      expect(result.isFailure, isTrue);
      expect(result.errorOrNull.toString(),
          contains('Could not open the overlay permission screen'));
    });

    test('platform errors fail closed', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        throw PlatformException(code: 'overlay_error', message: 'boom');
      });
      final OverlayLockService service = MethodChannelOverlayLockService();
      expect((await service.canDrawOverlays()).isFailure, isTrue);
      expect((await service.requestOverlayPermission()).isFailure, isTrue);
    });

    test('showLockChallenge/hideLockChallenge report the native results '
        '(Phase 5D)', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'showLockChallenge') {
          return true;
        }
        if (call.method == 'hideLockChallenge') {
          return true;
        }
        return null;
      });
      final OverlayLockService service = MethodChannelOverlayLockService();
      expect((await service.showLockChallenge('com.whatsapp')).isSuccess,
          isTrue);
      expect((await service.hideLockChallenge()).isSuccess, isTrue);

      // A native false reports a failure (the challenge could not be
      // presented) — never a fabricated success.
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async => false);
      expect((await service.showLockChallenge('com.whatsapp')).isFailure,
          isTrue);
      expect((await service.hideLockChallenge()).isFailure, isTrue);
    });

    test('challenge platform errors fail closed', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        throw PlatformException(code: 'overlay_error', message: 'boom');
      });
      final OverlayLockService service = MethodChannelOverlayLockService();
      expect((await service.showLockChallenge('com.whatsapp')).isFailure,
          isTrue);
      expect((await service.hideLockChallenge()).isFailure, isTrue);
    });
  });

  group('StaticOverlayLockService', () {
    test('mutable grant state + request counter', () async {
      final StaticOverlayLockService service =
          StaticOverlayLockService(overlayGranted: false);

      expect((await service.canDrawOverlays()).valueOrNull, isFalse);
      await service.requestOverlayPermission();
      expect(service.requestCalls, 1);

      service.overlayGranted = true; // simulated system-settings grant
      expect((await service.canDrawOverlays()).valueOrNull, isTrue);
    });

    test('challenge calls are counted and the package is recorded '
        '(Phase 5D)', () async {
      final StaticOverlayLockService service = StaticOverlayLockService();

      expect(
        (await service.showLockChallenge('com.whatsapp')).isSuccess,
        isTrue,
      );
      expect(service.showLockChallengeCalls, 1);
      expect(service.lastLockPackage, 'com.whatsapp');

      expect((await service.hideLockChallenge()).isSuccess, isTrue);
      expect(service.hideLockChallengeCalls, 1);

      service.showLockChallengeSucceeds = false;
      expect(
        (await service.showLockChallenge('com.whatsapp')).isFailure,
        isTrue,
      );
      expect(service.showLockChallengeCalls, 2);
    });
  });
}
