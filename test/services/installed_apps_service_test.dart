import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/services/impl/method_channel_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/installed_apps_service.dart';
import 'package:smart_app_lock/utilities/result.dart';

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

    test('getForegroundPackage decodes the native package (Phase 5A)',
        () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        expect(call.method, 'getForegroundPackage');
        return 'com.example.chat';
      });
      final InstalledAppsService service = MethodChannelInstalledAppsService();
      final result = await service.getForegroundPackage();
      expect(result.isSuccess, isTrue);
      expect(result.valueOrNull, 'com.example.chat');
    });

    test('getForegroundPackage treats a null native result as unknown '
        '(fail-closed)', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async => null);
      final InstalledAppsService service = MethodChannelInstalledAppsService();
      final result = await service.getForegroundPackage();
      expect(result.isSuccess, isTrue);
      expect(result.valueOrNull, isNull);
    });

    test('getForegroundPackage platform errors fail closed', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        throw PlatformException(code: 'usage_stats_error', message: 'boom');
      });
      final InstalledAppsService service = MethodChannelInstalledAppsService();
      expect((await service.getForegroundPackage()).isFailure, isTrue);
    });

    test('launchApp forwards the package and reports success (Phase 5E)',
        () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        expect(call.method, 'launchApp');
        expect(call.arguments, <String, dynamic>{
          'packageName': 'com.whatsapp',
        });
        return true;
      });
      final InstalledAppsService service = MethodChannelInstalledAppsService();
      expect((await service.launchApp('com.whatsapp')).isSuccess, isTrue);
    });

    test('launchApp reports failure when the native side cannot launch',
        () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async => false);
      final InstalledAppsService service = MethodChannelInstalledAppsService();
      final result = await service.launchApp('com.whatsapp');
      expect(result.isFailure, isTrue);
      expect(result.errorOrNull.toString(), contains('Could not open'));
    });

    test('launchApp platform errors fail closed', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        throw PlatformException(code: 'launch_error', message: 'boom');
      });
      final InstalledAppsService service = MethodChannelInstalledAppsService();
      expect((await service.launchApp('com.whatsapp')).isFailure, isTrue);
    });

    test('hasUsageAccess decodes the native grant state', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        expect(call.method, 'hasUsageAccess');
        return true;
      });
      final InstalledAppsService service = MethodChannelInstalledAppsService();
      final result = await service.hasUsageAccess();
      expect(result.isSuccess, isTrue);
      expect(result.valueOrNull, isTrue);
    });

    test('hasUsageAccess treats a null native result as denied', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async => null);
      final InstalledAppsService service = MethodChannelInstalledAppsService();
      final result = await service.hasUsageAccess();
      expect(result.isSuccess, isTrue);
      expect(result.valueOrNull, isFalse);
    });

    test('requestUsageAccess reports the native intent result', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        expect(call.method, 'requestUsageAccess');
        return true;
      });
      final InstalledAppsService service = MethodChannelInstalledAppsService();
      expect((await service.requestUsageAccess()).isSuccess, isTrue);

      messenger.setMockMethodCallHandler(channel, (MethodCall call) async => false);
      final result = await service.requestUsageAccess();
      expect(result.isFailure, isTrue);
      expect(result.errorOrNull.toString(),
          contains('Could not open the usage access settings'));
    });

    test('usage-access platform errors fail closed', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        throw PlatformException(code: 'usage_access_error', message: 'boom');
      });
      final InstalledAppsService service = MethodChannelInstalledAppsService();
      expect((await service.hasUsageAccess()).isFailure, isTrue);
      expect((await service.requestUsageAccess()).isFailure, isTrue);
    });

    test(
        'usage-access MissingPluginException fails closed (the Phase 4 '
        'device defect signature: an unwired native method answered with '
        'notImplemented must surface as a real error, never as granted',
        () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        throw MissingPluginException();
      });
      final InstalledAppsService service = MethodChannelInstalledAppsService();
      expect((await service.hasUsageAccess()).isFailure, isTrue);
      expect((await service.requestUsageAccess()).isFailure, isTrue);
    });

    test('usage enumeration still fails closed until the watcher phase',
        () async {
      final InstalledAppsService service = MethodChannelInstalledAppsService();
      expect((await service.getRecentlyUsedApps()).isFailure, isTrue);
    });

    test('getAppIcon decodes the native base64 payload', () async {
      final Uint8List png = Uint8List.fromList(<int>[137, 80, 78, 71]);
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        expect(call.method, 'getAppIcon');
        expect(
          (call.arguments as Map<dynamic, dynamic>)['packageName'],
          'com.whatsapp',
        );
        return base64Encode(png);
      });

      final InstalledAppsService service = MethodChannelInstalledAppsService();
      final result = await service.getAppIcon('com.whatsapp');
      expect(result.isSuccess, isTrue);
      expect(result.valueOrNull, png);
    });

    test('getAppIcon maps a null native result to a null icon', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async => null);
      final InstalledAppsService service = MethodChannelInstalledAppsService();
      final result = await service.getAppIcon('com.whatsapp');
      expect(result.isSuccess, isTrue);
      expect(result.valueOrNull, isNull);
    });

    test('getAppIcon caches per package (single channel call)', () async {
      int calls = 0;
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        calls++;
        return base64Encode(Uint8List.fromList(<int>[1, 2, 3]));
      });

      final InstalledAppsService service = MethodChannelInstalledAppsService();
      await service.getAppIcon('com.whatsapp');
      await service.getAppIcon('com.whatsapp');
      await service.getAppIcon('com.instagram');
      expect(calls, 2); // second whatsapp call served from cache
    });

    test('getAppIcon platform errors fail closed', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        throw PlatformException(code: 'icon_error', message: 'boom');
      });
      final InstalledAppsService service = MethodChannelInstalledAppsService();
      final result = await service.getAppIcon('com.whatsapp');
      expect(result.isFailure, isTrue);
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

    test('foreground package is mutable and counted (Phase 5A)',
        () async {
      final StaticInstalledAppsService service = StaticInstalledAppsService(apps);

      expect((await service.getForegroundPackage()).valueOrNull, isNull);
      service.foregroundPackage = 'com.whatsapp';
      expect((await service.getForegroundPackage()).valueOrNull, 'com.whatsapp');
      expect(service.getForegroundPackageCalls, 2);
    });

    test('launchApp is counted and recorded (Phase 5E)', () async {
      final StaticInstalledAppsService service = StaticInstalledAppsService(apps);

      expect((await service.launchApp('com.whatsapp')).isSuccess, isTrue);
      expect(service.launchAppCalls, 1);
      expect(service.launchedPackages, <String>['com.whatsapp']);

      service.launchAppSucceeds = false;
      expect((await service.launchApp('com.whatsapp')).isFailure, isTrue);
      expect(service.launchAppCalls, 2);
      expect(service.launchedPackages, <String>['com.whatsapp']);
    });

    test('getAppIcon returns seeded bytes or null', () async {
      final Uint8List png = Uint8List.fromList(<int>[1, 2, 3]);
      final StaticInstalledAppsService service = StaticInstalledAppsService(
        apps,
        iconBytesFor: <String, Uint8List>{'com.whatsapp': png},
      );
      expect((await service.getAppIcon('com.whatsapp')).valueOrNull, png);
      expect((await service.getAppIcon('com.instagram')).valueOrNull, isNull);
    });
  });
}
