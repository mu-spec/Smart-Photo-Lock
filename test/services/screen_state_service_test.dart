import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/services/impl/method_channel_screen_state_service.dart';
import 'package:smart_app_lock/services/impl/static_screen_state_service.dart';
import 'package:smart_app_lock/services/screen_state_service.dart';
import 'package:smart_app_lock/utilities/result.dart';

/// Phase 5K: the screen-state bridge — wire format on the Dart side and
/// the static test service.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const EventChannel channel = EventChannel('smart_app_lock/screen_state');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockStreamHandler(channel, null);
  });

  group('MethodChannelScreenStateService', () {
    test('relays native screen-state payloads (Phase 5K)', () async {
      messenger.setMockStreamHandler(
        channel,
        MockStreamHandler.inline(
          onListen: (Object? arguments, MockStreamHandlerEventSink events) {
            events.success('screen_off');
            events.success('screen_on');
          },
        ),
      );
      final ScreenStateService service = MethodChannelScreenStateService();
      final List<Result<ScreenStateEvent>> seen = <Result<ScreenStateEvent>>[];
      service.events.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(seen, hasLength(2));
      expect(seen[0].valueOrNull, ScreenStateEvent.screenOff);
      expect(seen[1].valueOrNull, ScreenStateEvent.screenOn);
    });

    test('unknown payloads surface as failures (never fabricated)',
        () async {
      messenger.setMockStreamHandler(
        channel,
        MockStreamHandler.inline(
          onListen: (Object? arguments, MockStreamHandlerEventSink events) {
            events.success('screen_maybe');
          },
        ),
      );
      final ScreenStateService service = MethodChannelScreenStateService();
      final List<Result<ScreenStateEvent>> seen = <Result<ScreenStateEvent>>[];
      service.events.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(seen, hasLength(1));
      expect(seen.single.isFailure, isTrue);
    });

    test('channel errors surface as failures', () async {
      messenger.setMockStreamHandler(
        channel,
        MockStreamHandler.inline(
          onListen: (Object? arguments, MockStreamHandlerEventSink events) {
            events.error('screen_error', 'boom', null);
          },
        ),
      );
      final ScreenStateService service = MethodChannelScreenStateService();
      final List<Result<ScreenStateEvent>> seen = <Result<ScreenStateEvent>>[];
      service.events.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(seen, hasLength(1));
      expect(seen.single.isFailure, isTrue);
    });

    test('no native handler: the stream emits a failure, never data',
        () async {
      final ScreenStateService service = MethodChannelScreenStateService();
      final List<Result<ScreenStateEvent>> seen = <Result<ScreenStateEvent>>[];
      service.events.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(seen, isNotEmpty);
      expect(seen.every((Result<ScreenStateEvent> e) => e.isFailure), isTrue);
    });
  });

  group('StaticScreenStateService', () {
    test('emits screen states and counts them', () async {
      final StaticScreenStateService service = StaticScreenStateService();
      final List<ScreenStateEvent> seen = <ScreenStateEvent>[];
      service.events.listen((Result<ScreenStateEvent> e) {
        if (e.isSuccess) {
          seen.add(e.valueOrNull!);
        }
      });

      service.emitScreenOff();
      service.emitScreenOff();
      service.emitScreenOn();
      await Future<void>.delayed(Duration.zero);

      expect(seen, <ScreenStateEvent>[
        ScreenStateEvent.screenOff,
        ScreenStateEvent.screenOff,
        ScreenStateEvent.screenOn,
      ]);
      expect(service.screenOffCount, 2);
      expect(service.screenOnCount, 1);
    });
  });
}
