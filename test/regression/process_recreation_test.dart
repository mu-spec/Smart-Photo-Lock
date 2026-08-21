import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/access_controller.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';

/// Phase 5T: process recreation — Android destroys and recreates Smart
/// App Lock, and protection recovers safely.
///
/// What survives process death (production truth: SQLite + the Android
/// Keystore) and what does not:
///  * SURVIVES: the protected-app list, credentials, the persisted
///    lockout timestamp, the grace-period setting;
///  * DOES NOT (in-memory only): unlock sessions, grace deadlines,
///    queued requirements, the screen-off marker, window flags — all
///    of which must fail CLOSED after recreation.
void main() {
  /// Shared persisted stores — the simulation of SQLite + Keystore
  /// surviving the process.
  late InMemoryLocalDatabase database;
  late InMemorySecretStore secretStore;

  setUp(() {
    database = InMemoryLocalDatabase();
    secretStore = InMemorySecretStore();
  });

  AppContainer boot() => AppContainer.inMemory(
        database: database,
        secretStore: secretStore,
      );

  Future<void> protect(AppContainer container, String package) =>
      container.protectedApps.add(
        ProtectedApp(
          packageName: package,
          label: package,
          addedAt: DateTime(2026, 8, 21),
        ),
      );

  // -------------------------------------------------------------------
  // Persisted-state layers (unit)
  // -------------------------------------------------------------------
  test('unlock sessions and grace deadlines do not survive recreation '
      '(fail-closed)', () async {
    final AppContainer boot1 = boot();
    await protect(boot1, 'com.whatsapp');
    final DefaultAccessController c1 =
        boot1.accessController as DefaultAccessController;
    c1.setGracePeriod(const Duration(seconds: 30));
    await c1.grantAccess('com.whatsapp');
    await c1.revokeAccess('com.whatsapp'); // arms the grace deadline
    expect(c1.sessionFor('com.whatsapp'), isNotNull);
    expect(c1.departureAtFor('com.whatsapp'), isNotNull);

    // Recreation: a fresh stack over the same persisted stores.
    final AppContainer boot2 = boot();
    final DefaultAccessController c2 =
        boot2.accessController as DefaultAccessController;
    expect(c2.sessionFor('com.whatsapp'), isNull);
    expect(c2.departureAtFor('com.whatsapp'), isNull);
    expect(
      await c2.evaluate('com.whatsapp'),
      AccessDecision.challenge,
    );
  });

  test('the persisted grace setting survives recreation and applies '
      'fresh', () async {
    final AppContainer boot1 = boot();
    await boot1.lockSettings.setGracePeriod(const Duration(seconds: 30));

    final AppContainer boot2 = boot();
    expect(
      (await boot2.lockSettings.getGracePeriod()).valueOrNull,
      const Duration(seconds: 30),
    );
    // A fresh grace cycle works: grant, leave, return inside 30s.
    await protect(boot2, 'com.whatsapp');
    final DefaultAccessController c2 =
        boot2.accessController as DefaultAccessController;
    c2.setGracePeriod(const Duration(seconds: 30));
    await c2.grantAccess('com.whatsapp');
    await c2.revokeAccess('com.whatsapp');
    expect(
      await c2.evaluate('com.whatsapp'),
      AccessDecision.allow,
    );
  });

  test('credentials and an active lockout survive recreation',
      () async {
    final AppContainer boot1 = boot();
    await boot1.auth.enrollPin('1234');
    for (int i = 0; i < 3; i++) {
      await boot1.auth.authenticatePin('9999');
    }

    final AppContainer boot2 = boot();
    // The cooldown timestamp persisted: even the correct PIN stays
    // blocked while it is in force.
    expect(
      (await boot2.auth.authenticatePin('1234')).valueOrNull,
      isA<AuthLockedOut>(),
    );
  });

  // -------------------------------------------------------------------
  // Full-app recreation flows (widget)
  // -------------------------------------------------------------------
  Future<void> killProcess(WidgetTester tester) async {
    // The whole tree is torn down (host dispose -> trigger stop ->
    // monitor stop). A real process death takes the isolate with it;
    // this is the honest widget-level simulation.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  Future<AppContainer> reborn(
    WidgetTester tester, {
    String? foregroundPackage,
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final AppContainer container = boot();
    if (foregroundPackage != null) {
      // The recreated process discovers the foreground through the
      // usage-stats backend (simulated): seed and pre-probe so the
      // baseline knows it without emitting.
      (container.installedAppsService as StaticInstalledAppsService)
          .foregroundPackage = foregroundPackage;
      await container.foregroundMonitor.probe();
    }
    await tester.pumpWidget(SmartAppLockApp(container: container));
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets(
      'process death mid-challenge: recreation re-challenges and the PIN '
      'grants exactly once', (WidgetTester tester) async {
    final AppContainer boot1 = boot();
    await protect(boot1, 'com.whatsapp');
    await boot1.auth.enrollPin('1234');
    await tester.pumpWidget(SmartAppLockApp(container: boot1));
    await tester.pumpAndSettle();

    // The challenge is up when the process dies.
    (boot1.installedAppsService as StaticInstalledAppsService)
        .foregroundPackage = 'com.whatsapp';
    await boot1.foregroundMonitor.probe();
    await tester.pumpAndSettle();
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    // The process dies mid-challenge.
    await killProcess(tester);

    // Recreation with the protected app still the foreground: the
    // baseline enforcement re-presents the challenge immediately.
    final AppContainer boot2 = await reborn(
      tester,
      foregroundPackage: 'com.whatsapp',
    );
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(
      (boot2.accessController as DefaultAccessController)
          .sessionFor('com.whatsapp'),
      isNull,
    );

    // The correct PIN ends the recreated cycle with a single grant and
    // a single launch.
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(
      (boot2.accessController as DefaultAccessController)
          .sessionFor('com.whatsapp'),
      isNotNull,
    );
    final StaticInstalledAppsService apps =
        boot2.installedAppsService as StaticInstalledAppsService;
    expect(apps.launchAppCalls, 1);
    expect(apps.launchedPackages, <String>['com.whatsapp']);
  });

  testWidgets(
      'an in-memory grace deadline does not survive recreation '
      '(fail-closed)', (WidgetTester tester) async {
    final AppContainer boot1 = boot();
    await protect(boot1, 'com.whatsapp');
    await boot1.auth.enrollPin('1234');
    await boot1.lockSettings.setGracePeriod(const Duration(seconds: 30));
    await tester.pumpWidget(SmartAppLockApp(container: boot1));
    await tester.pumpAndSettle();

    // Unlock WhatsApp: a session + (on leave) a grace deadline exist.
    (boot1.installedAppsService as StaticInstalledAppsService)
        .foregroundPackage = 'com.whatsapp';
    await boot1.foregroundMonitor.probe();
    await tester.pumpAndSettle();
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(
      (boot1.accessController as DefaultAccessController)
          .sessionFor('com.whatsapp'),
      isNotNull,
    );

    await killProcess(tester);

    // Recreation: the persisted grace setting survives, but the
    // in-memory deadline is gone — the first contact challenges
    // (never extends a grace window that no longer exists).
    final AppContainer boot2 = await reborn(
      tester,
      foregroundPackage: 'com.whatsapp',
    );
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(
      (boot2.accessController as DefaultAccessController)
          .sessionFor('com.whatsapp'),
      isNull,
    );
  });

  testWidgets(
      'queued requirements are re-derived from the current foreground, '
      'never replayed', (WidgetTester tester) async {
    final AppContainer boot1 = boot();
    await protect(boot1, 'com.whatsapp');
    await protect(boot1, 'com.example.maps');
    await boot1.auth.enrollPin('1234');
    await tester.pumpWidget(SmartAppLockApp(container: boot1));
    await tester.pumpAndSettle();

    // WhatsApp challenges; while it is up, Maps becomes foreground
    // (its requirement queues).
    (boot1.installedAppsService as StaticInstalledAppsService)
        .foregroundPackage = 'com.whatsapp';
    await boot1.foregroundMonitor.probe();
    await tester.pumpAndSettle();
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    (boot1.installedAppsService as StaticInstalledAppsService)
        .foregroundPackage = 'com.example.maps';
    await boot1.foregroundMonitor.probe();
    await tester.pumpAndSettle();

    await killProcess(tester);

    // Recreation with MAPS as the current foreground: the challenge
    // targets Maps — the lost queue is re-derived, not replayed.
    final AppContainer boot2 = await reborn(
      tester,
      foregroundPackage: 'com.example.maps',
    );
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    final StaticOverlayLockService overlay =
        boot2.overlay as StaticOverlayLockService;
    expect(overlay.lastLockPackage, 'com.example.maps');
  });

  testWidgets(
      'the secure window re-arms on resume after an activity recreation '
      '(Phase 5T)', (WidgetTester tester) async {
    final AppContainer boot1 = boot();
    await protect(boot1, 'com.whatsapp');
    await boot1.auth.enrollPin('1234');
    await tester.pumpWidget(SmartAppLockApp(container: boot1));
    await tester.pumpAndSettle();

    (boot1.installedAppsService as StaticInstalledAppsService)
        .foregroundPackage = 'com.whatsapp';
    await boot1.foregroundMonitor.probe();
    await tester.pumpAndSettle();
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    final StaticOverlayLockService overlay =
        boot1.overlay as StaticOverlayLockService;
    expect(overlay.secureWindow, isTrue);

    // The platform rebuilt the activity window (flags reset), then the
    // app resumes: the host must re-arm FLAG_SECURE while the
    // challenge is up.
    overlay.secureWindow = false; // simulate the fresh window
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(overlay.secureWindow, isTrue);
  });
}
