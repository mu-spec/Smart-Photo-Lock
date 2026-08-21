import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/protection/access_controller.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/protection/lock_trigger.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_screen_state_service.dart';

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

  // -- immediate re-lock (Phase 5J) -----------------------------------------

  test('leaving a protected app revokes its session immediately',
      () async {
    await protect('com.whatsapp');
    final DefaultAccessController controller =
        container.accessController as DefaultAccessController;
    await controller.grantAccess('com.whatsapp');
    expect(controller.sessionFor('com.whatsapp'), isNotNull);

    await trigger.start();
    final StaticInstalledAppsService installed =
        container.installedAppsService as StaticInstalledAppsService;

    // The user leaves WhatsApp for the launcher: the transition away
    // must revoke the session instantly — even though no new challenge
    // is required for the launcher itself.
    installed.foregroundPackage = 'com.example.launcher';
    await container.foregroundMonitor.probe();
    await Future<void>.delayed(Duration.zero);

    expect(controller.sessionFor('com.whatsapp'), isNull);
    expect(requirements, isEmpty); // the launcher is unprotected

    // Returning to WhatsApp now challenges again: immediate re-lock.
    installed.foregroundPackage = 'com.whatsapp';
    await container.foregroundMonitor.probe();
    await Future<void>.delayed(Duration.zero);

    expect(requirements, hasLength(1));
    expect(requirements.single.packageName, 'com.whatsapp');

    await trigger.stop();
  });

  test('a restart while inside the protected app still re-locks on leave',
      () async {
    await protect('com.whatsapp');
    final DefaultAccessController controller =
        container.accessController as DefaultAccessController;
    await controller.grantAccess('com.whatsapp');

    // The monitor's last known foreground is WhatsApp (simulating a
    // trigger restart while the user is inside the protected app).
    final StaticInstalledAppsService installed =
        container.installedAppsService as StaticInstalledAppsService;
    installed.foregroundPackage = 'com.whatsapp';
    await container.foregroundMonitor.probe();

    await trigger.start(); // seeds previous-package tracking
    expect(controller.sessionFor('com.whatsapp'), isNotNull);

    // Leaving must still revoke, even though the trigger never saw the
    // entry transition.
    installed.foregroundPackage = 'com.example.launcher';
    await container.foregroundMonitor.probe();
    await Future<void>.delayed(Duration.zero);

    expect(controller.sessionFor('com.whatsapp'), isNull);

    await trigger.stop();
  });

  // -- screen-off re-lock (Phase 5K) -----------------------------------------

  test('a screen-off revokes every unlock session and marks pending',
      () async {
    await protect('com.whatsapp');
    await protect('com.example.maps');
    final DefaultAccessController controller =
        container.accessController as DefaultAccessController;
    await controller.grantAccess('com.whatsapp');
    await controller.grantAccess('com.example.maps');
    expect(controller.sessionFor('com.whatsapp'), isNotNull);
    expect(controller.sessionFor('com.example.maps'), isNotNull);

    await trigger.start();
    expect(trigger.takeScreenOffPending(), isFalse);

    (container.screenState as StaticScreenStateService).emitScreenOff();
    await Future<void>.delayed(Duration.zero);

    // Every session is gone, and the resume-enforcement marker is set
    // exactly once.
    expect(controller.sessionFor('com.whatsapp'), isNull);
    expect(controller.sessionFor('com.example.maps'), isNull);
    expect(trigger.takeScreenOffPending(), isTrue);
    expect(trigger.takeScreenOffPending(), isFalse); // consumed

    await trigger.stop();
  });

  test('a screen-on event revokes nothing', () async {
    await protect('com.whatsapp');
    final DefaultAccessController controller =
        container.accessController as DefaultAccessController;
    await controller.grantAccess('com.whatsapp');

    await trigger.start();
    (container.screenState as StaticScreenStateService).emitScreenOn();
    await Future<void>.delayed(Duration.zero);

    expect(controller.sessionFor('com.whatsapp'), isNotNull);
    expect(trigger.takeScreenOffPending(), isFalse);

    await trigger.stop();
  });

  // -- grace periods (Phase 5L) ----------------------------------------------

  test('with a grace period, leaving keeps the session instead of '
      'revoking it', () async {
    await protect('com.whatsapp');
    final DefaultAccessController controller =
        container.accessController as DefaultAccessController;
    controller.setGracePeriod(const Duration(seconds: 30));

    await trigger.start();
    final StaticInstalledAppsService installed =
        container.installedAppsService as StaticInstalledAppsService;

    // First activation: no session -> challenge requirement.
    installed.foregroundPackage = 'com.whatsapp';
    await container.foregroundMonitor.probe();
    await Future<void>.delayed(Duration.zero);
    expect(requirements, hasLength(1));

    // Unlock, then LEAVE: the grace policy keeps the session alive.
    await controller.grantAccess('com.whatsapp');
    installed.foregroundPackage = 'com.example.launcher';
    await container.foregroundMonitor.probe();
    await Future<void>.delayed(Duration.zero);
    expect(controller.sessionFor('com.whatsapp'), isNotNull);

    // Return within grace: allowed, no new requirement.
    installed.foregroundPackage = 'com.whatsapp';
    await container.foregroundMonitor.probe();
    await Future<void>.delayed(Duration.zero);
    expect(requirements, hasLength(1));
    expect(controller.sessionFor('com.whatsapp'), isNotNull);

    await trigger.stop();
  });
}
