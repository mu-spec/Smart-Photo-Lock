import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/protection/access_controller.dart';
import 'package:smart_app_lock/protection/lock_trigger.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';

/// Phase 5D: the lock trigger — a protected app becoming active emits a
/// lock requirement; unprotected apps and open unlock windows do not.
void main() {
  late AppContainer container;
  late LockTrigger trigger;
  late List<LockRequired> requirements;

  setUp(() {
    container = AppContainer.inMemory();
    trigger = container.lockTrigger;
    requirements = <LockRequired>[];
    trigger.lockRequired.listen(requirements.add);
  });

  tearDown(() async {
    await trigger.dispose();
  });

  Future<void> protect(String package) => container.protectedApps.add(
        ProtectedApp(
          packageName: package,
          label: package,
          addedAt: DateTime(2026, 8, 21),
        ),
      );

  test('a protected app becoming active emits a lock requirement',
      () async {
    await protect('com.whatsapp');
    await trigger.start();

    (container.installedAppsService as StaticInstalledAppsService)
        .foregroundPackage = 'com.whatsapp';
    await container.foregroundMonitor.probe();
    await Future<void>.delayed(Duration.zero);

    expect(requirements, hasLength(1));
    expect(requirements.single.packageName, 'com.whatsapp');

    await trigger.stop();
  });

  test('an unprotected app emits nothing', () async {
    await trigger.start();

    (container.installedAppsService as StaticInstalledAppsService)
        .foregroundPackage = 'com.example.chat';
    await container.foregroundMonitor.probe();
    await Future<void>.delayed(Duration.zero);

    expect(requirements, isEmpty);

    await trigger.stop();
  });

  test('an open unlock session suppresses the requirement', () async {
    await protect('com.whatsapp');
    await container.accessController.grantAccess('com.whatsapp');
    await trigger.start();

    (container.installedAppsService as StaticInstalledAppsService)
        .foregroundPackage = 'com.whatsapp';
    await container.foregroundMonitor.probe();
    await Future<void>.delayed(Duration.zero);

    expect(requirements, isEmpty);

    await trigger.stop();
  });

  test('the accessibility path also drives the trigger', () async {
    await protect('com.android.chrome');
    await trigger.start();

    (container.accessibility as StaticAccessibilityLockService)
        .emitForegroundPackage('com.android.chrome');
    await Future<void>.delayed(Duration.zero);

    expect(requirements, hasLength(1));
    expect(requirements.single.packageName, 'com.android.chrome');

    await trigger.stop();
  });

  test('the same protected package does not spam requirements', () async {
    await protect('com.whatsapp');
    await trigger.start();
    final StaticInstalledAppsService installed =
        container.installedAppsService as StaticInstalledAppsService;

    installed.foregroundPackage = 'com.whatsapp';
    await container.foregroundMonitor.probe();
    await Future<void>.delayed(Duration.zero);
    expect(requirements, hasLength(1));

    // Switch away and back: a NEW transition fires a NEW requirement
    // (the session was not granted in this test).
    installed.foregroundPackage = 'com.example.other';
    await container.foregroundMonitor.probe();
    installed.foregroundPackage = 'com.whatsapp';
    await container.foregroundMonitor.probe();
    await Future<void>.delayed(Duration.zero);

    expect(requirements, hasLength(2));

    await trigger.stop();
  });

  test('start is idempotent and stop halts the pipeline', () async {
    await protect('com.whatsapp');
    await trigger.start();
    await trigger.start(); // no-op

    final StaticInstalledAppsService installed =
        container.installedAppsService as StaticInstalledAppsService;
    installed.foregroundPackage = 'com.whatsapp';
    await container.foregroundMonitor.probe();
    await Future<void>.delayed(Duration.zero);
    expect(requirements, hasLength(1));

    await trigger.stop();
    installed.foregroundPackage = 'com.example.other';
    await container.foregroundMonitor.probe();
    await Future<void>.delayed(Duration.zero);
    expect(requirements, hasLength(1)); // stopped: nothing new
  });
}
