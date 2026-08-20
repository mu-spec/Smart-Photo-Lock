import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/services/impl/method_channel_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/installed_apps_service.dart';

/// Phase 3A: the native bridge's wire format (Dart side) and the static
/// test service.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('smart_app_lock/apps');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('MethodChannelInstalledAppsService', () {
    test('decodes the native app list and forwards includeSystemApps',
        () async {
      final List<Map<String, dynamic>> calls = <Map<String, dynamic>>[];
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        expect(call.method, 'getInstalledApps');
        calls.add((call.arguments as Map<dynamic, dynamic>).cast<String, dynamic>());
        return <Map<String, dynamic>>[
          <String, dynamic>{
            'packageName': 'com.whatsapp',
            'label': 'WhatsApp',
            'isSystemApp': false,
            'versionName': '2.24.1',
          },
          <String, dynamic>{
            'packageName': 'com.android.settings',
            'label': 'Settings',
            'isSystemApp': true,
            'versionName': null,
          },
        ];
      });

      final InstalledAppsService service = MethodChannelInstalledAppsService();
      final result = await service.getInstalledApps(includeSystemApps: true);

      expect(result.isSuccess, isTrue);
      final List<AppEntry> apps = result.valueOrNull!;
      expect(apps, hasLength(2));
      expect(apps.first.packageName, 'com.whatsapp');
      expect(apps.first.label, 'WhatsApp');
      expect(apps.first.isSystemApp, isFalse);
      expect(apps.first.versionName, '2.24.1');
      expect(apps.last.isSystemApp, isTrue);
      expect(apps.last.versionName, isNull);

      expect(calls, hasLength(1));
      expect(calls.single['includeSystemApps'], isTrue);
    });

    test('forwards includeSystemApps=false by default', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        expect(
          (call.arguments as Map<dynamic, dynamic>)['includeSystemApps'],
          isFalse,
        );
        return <Map<String, dynamic>>[];
      });

      final InstalledAppsService service = MethodChannelInstalledAppsService();
      final result = await service.getInstalledApps();
      expect(result.isSuccess, isTrue);
      expect(result.valueOrNull, isEmpty);
    });

    test('null result is treated as an empty list', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async => null);
      final InstalledAppsService service = MethodChannelInstalledAppsService();
      final result = await service.getInstalledApps();
      expect(result.isSuccess, isTrue);
      expect(result.valueOrNull, isEmpty);
    });

    test('platform errors fail closed as Failures', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        throw PlatformException(code: 'installed_apps_error', message: 'boom');
      });
      final InstalledAppsService service = MethodChannelInstalledAppsService();
      final result = await service.getInstalledApps();
      expect(result.isFailure, isTrue);
      expect(result.errorOrNull, isA<PlatformException>());
    });

    test('usage-access methods fail closed until that phase lands', () async {
      final InstalledAppsService service = MethodChannelInstalledAppsService();
      expect((await service.getRecentlyUsedApps()).isFailure, isTrue);
      expect((await service.hasUsageAccess()).isFailure, isTrue);
      expect((await service.requestUsageAccess()).isFailure, isTrue);
    });
  });

  group('StaticInstalledAppsService', () {
    const List<AppEntry> apps = <AppEntry>[
      AppEntry(packageName: 'com.whatsapp', label: 'WhatsApp'),
      AppEntry(
        packageName: 'com.android.settings',
        label: 'Settings',
        isSystemApp: true,
      ),
    ];

    test('filters system apps by default and counts calls', () async {
      final StaticInstalledAppsService service = StaticInstalledAppsService(apps);

      final Result<List<AppEntry>> user = await service.getInstalledApps();
      expect(user.valueOrNull, hasLength(1));
      expect(user.valueOrNull!.single.packageName, 'com.whatsapp');

      final Result<List<AppEntry>> all =
          await service.getInstalledApps(includeSystemApps: true);
      expect(all.valueOrNull, hasLength(2));

      expect(service.getInstalledAppsCalls, 2);
    });

    test('recently used caps at the limit; usage access reports granted',
        () async {
      final StaticInstalledAppsService service = StaticInstalledAppsService(apps);
      expect((await service.getRecentlyUsedApps(limit: 1)).valueOrNull,
          hasLength(1));
      expect((await service.hasUsageAccess()).valueOrNull, isTrue);
      expect((await service.requestUsageAccess()).isSuccess, isTrue);
    });
  });
}
