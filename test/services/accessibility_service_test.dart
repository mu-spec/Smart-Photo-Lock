import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/services/accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/method_channel_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/utilities/result.dart';

/// Phase 4C: the accessibility capability bridge — wire format on the
/// Dart side and the static test service.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel =
      MethodChannel('smart_app_lock/accessibility');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('MethodChannelAccessibilityLockService', () {
    test('isServiceEnabled decodes the native state', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        expect(call.method, 'isAccessibilityEnabled');
        return true;
      });
      final AccessibilityLockService service =
          MethodChannelAccessibilityLockService();
      final result = await service.isServiceEnabled();
      expect(result.isSuccess, isTrue);
      expect(result.valueOrNull, isTrue);
    });

    test('a null native result is treated as disabled', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async => null);
      final AccessibilityLockService service =
          MethodChannelAccessibilityLockService();
      final result = await service.isServiceEnabled();
      expect(result.isSuccess, isTrue);
      expect(result.valueOrNull, isFalse);
    });

    test('requestServiceEnable reports the native intent result', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        expect(call.method, 'requestAccessibilityEnable');
        return true;
      });
      final AccessibilityLockService service =
          MethodChannelAccessibilityLockService();
      expect((await service.requestServiceEnable()).isSuccess, isTrue);

      messenger.setMockMethodCallHandler(channel, (MethodCall call) async => false);
      final result = await service.requestServiceEnable();
      expect(result.isFailure, isTrue);
      expect(result.errorOrNull.toString(),
          contains('Could not open the accessibility settings'));
    });

    test('platform errors fail closed', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        throw PlatformException(code: 'accessibility_error', message: 'boom');
      });
      final AccessibilityLockService service =
          MethodChannelAccessibilityLockService();
      expect((await service.isServiceEnabled()).isFailure, isTrue);
      expect((await service.requestServiceEnable()).isFailure, isTrue);
    });

    test('the foreground stream is empty until the lock engine wires it',
        () async {
      final AccessibilityLockService service =
          MethodChannelAccessibilityLockService();
      final List<Result<String>> events = <Result<String>>[];
      service.foregroundPackages.listen(events.add);
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
    });
  });

  group('StaticAccessibilityLockService', () {
    test('mutable enabled state + request counter', () async {
      final StaticAccessibilityLockService service =
          StaticAccessibilityLockService(enabled: false);

      expect((await service.isServiceEnabled()).valueOrNull, isFalse);
      await service.requestServiceEnable();
      expect(service.requestServiceEnableCalls, 1);

      service.enabled = true; // simulated system-settings grant
      expect((await service.isServiceEnabled()).valueOrNull, isTrue);
    });
  });
}
