import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_screen_state_service.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';

/// Phase 5U — Core Lock Regression: the complete lock-engine QA
/// gauntlet.
///
/// CRITICAL CHECKPOINT: ordinary protected-app access must not
/// reproducibly bypass authentication. Every test below walks a REAL
/// bypass attempt (wrong credential, Back, Home, recents, gestures,
/// rapid switching, screen off/on, process recreation) or a positive
/// path (correct credential, grace window) through the PRODUCTION app
/// wiring — monitor → matcher → controller → trigger → host → router →
/// unlock screens.
void main() {
  /// The persisted stores shared across simulated process deaths.
  late InMemoryLocalDatabase database;
  late InMemorySecretStore secretStore;

  setUp(() {
    database = InMemoryLocalDatabase();
    secretStore = InMemorySecretStore();
  });

  AppContainer boot({
    DateTime Function()? accessClock,
    Duration? gracePeriod,
  }) {
    final AppContainer container = AppContainer.inMemory(
      accessClock: accessClock,
      database: database,
      secretStore: secretStore,
    );
    if (gracePeriod != null) {
      container.accessController.setGracePeriod(gracePeriod);
    }
    return container;
  }

  Future<AppContainer> pumpApp(
    WidgetTester tester, {
    DateTime Function()? accessClock,
    Duration? gracePeriod,
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final AppContainer container =
        boot(accessClock: accessClock, gracePeriod: gracePeriod);
    await tester.pumpWidget(SmartAppLockApp(container: container));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> protect(AppContainer container, String package) =>
      container.protectedApps.add(
        ProtectedApp(
          packageName: package,
          label: package,
          addedAt: DateTime(2026, 8, 21),
        ),
      );

  /// The user opens another app (accessibility detection path).
  Future<void> openApp(
    WidgetTester tester,
    AppContainer container,
    String package,
  ) async {
    (container.accessibility as StaticAccessibilityLockService)
        .emitForegroundPackage(package);
    await tester.pumpAndSettle();
  }

  Future<void> enterPin(WidgetTester tester, String pin) async {
    for (final String digit in pin.split('')) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
  }

  Object? sessionFor(AppContainer container, String package) =>
      (container.accessController as DefaultAccessController)
          .sessionFor(package);

  StaticInstalledAppsService appsOf(AppContainer container) =>
      container.installedAppsService as StaticInstalledAppsService;

  StaticOverlayLockService overlayOf(AppContainer container) =>
      container.overlay as StaticOverlayLockService;

  StaticScreenStateService screenOf(AppContainer container) =>
      container.screenState as StaticScreenStateService;

  Future<void> pressHome(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
  }

  Future<void> returnToApp(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  }

  Future<void> sleepWake(WidgetTester tester, AppContainer container) async {
    screenOf(container).emitScreenOff();
    await tester.pump();
    screenOf(container).emitScreenOn();
    await tester.pumpAndSettle();
  }

  // -------------------------------------------------------------------
  // 1. The full happy path, end to end
  // -------------------------------------------------------------------
  testWidgets(
      'GAUNTLET 1: protect -> challenge -> correct PIN -> launch -> '
      'leave re-locks -> unlock again', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    // Entry challenges.
    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(sessionFor(container, 'com.whatsapp'), isNull);

    // Correct PIN: session granted + app launched.
    await enterPin(tester, '1234');
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);
    expect(appsOf(container).launchedPackages, <String>['com.whatsapp']);

    // Immediate re-lock: leaving ends the session; returning
    // challenges again.
    await openApp(tester, container, 'com.example.launcher');
    expect(sessionFor(container, 'com.whatsapp'), isNull);
    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    await enterPin(tester, '1234');
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);
    expect(appsOf(container).launchAppCalls, 2);
  });

  // -------------------------------------------------------------------
  // 2-8. The bypass gauntlet — ordinary access NEVER passes
  // -------------------------------------------------------------------
  testWidgets('GAUNTLET 2: wrong PIN never opens the app',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    await enterPin(tester, '9999');

    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(find.textContaining(PinUnlockScreen.wrongPinPrefix),
        findsOneWidget);
    expect(sessionFor(container, 'com.whatsapp'), isNull);
    expect(appsOf(container).launchAppCalls, 0);
  });

  testWidgets('GAUNTLET 3: Back never bypasses the challenge',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    for (int i = 0; i < 4; i++) {
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget,
          reason: 'back press ${i + 1} must not dismiss the challenge');
    }
    expect(sessionFor(container, 'com.whatsapp'), isNull);
    expect(appsOf(container).launchAppCalls, 0);

    await enterPin(tester, '1234');
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);
  });

  testWidgets('GAUNTLET 4: Home + re-open never bypasses the challenge',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    // Home dismisses the visible challenge (never grants).
    await pressHome(tester);
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNull);
    expect(appsOf(container).launchAppCalls, 0);

    // Re-opening the protected app re-challenges — no unlocked pass.
    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(sessionFor(container, 'com.whatsapp'), isNull);
    expect(appsOf(container).launchAppCalls, 0);

    await enterPin(tester, '1234');
    expect(find.byType(PinUnlockScreen), findsNothing);
  });

  testWidgets('GAUNTLET 5: the recents task switch never bypasses',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    // Recents: leave, then tap the PROTECTED app's task while Smart
    // App Lock is backgrounded.
    await pressHome(tester);
    expect(find.byType(PinUnlockScreen), findsNothing);
    await openApp(tester, container, 'com.whatsapp');

    // The challenge comes straight back; the app never opens unlocked.
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(sessionFor(container, 'com.whatsapp'), isNull);
    expect(appsOf(container).launchAppCalls, 0);

    await enterPin(tester, '1234');
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(appsOf(container).launchAppCalls, 1);
  });

  testWidgets('GAUNTLET 6: cancelled gestures never dismiss the challenge',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    final int shows = overlayOf(container).showLockChallengeCalls;

    // Two cancelled home-swipes: the challenge stays untouched.
    for (int i = 0; i < 2; i++) {
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(overlayOf(container).showLockChallengeCalls, shows);
    expect(sessionFor(container, 'com.whatsapp'), isNull);

    await enterPin(tester, '1234');
    expect(find.byType(PinUnlockScreen), findsNothing);
  });

  testWidgets('GAUNTLET 7: rapid switching never opens the app and never '
      'stacks challenges', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');
    final StaticAccessibilityLockService a11y =
        container.accessibility as StaticAccessibilityLockService;

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    final int shows = overlayOf(container).showLockChallengeCalls;

    // The protected -> unprotected -> protected storm.
    a11y.emitForegroundPackage('com.example.launcher');
    a11y.emitForegroundPackage('com.whatsapp');
    a11y.emitForegroundPackage('com.example.launcher');
    a11y.emitForegroundPackage('com.whatsapp');
    await tester.pumpAndSettle();

    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(overlayOf(container).showLockChallengeCalls, shows);
    expect(sessionFor(container, 'com.whatsapp'), isNull);
    expect(appsOf(container).launchAppCalls, 0);

    await enterPin(tester, '1234');
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(appsOf(container).launchAppCalls, 1);
  });

  testWidgets('GAUNTLET 8: sleep/wake never reveals the unlocked app',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    await enterPin(tester, '1234');
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);

    // Screen off/on with WhatsApp still foreground: wake enforcement
    // re-challenges immediately — no unlocked reveal.
    await sleepWake(tester, container);
    expect(sessionFor(container, 'com.whatsapp'), isNull);
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    // Only the original unlock ever launched the app.
    expect(appsOf(container).launchAppCalls, 1);

    await enterPin(tester, '1234');
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);
  });

  // -------------------------------------------------------------------
  // 9. Grace window (positive path)
  // -------------------------------------------------------------------
  testWidgets(
      'GAUNTLET 9: the grace window allows quick returns and re-locks '
      'after it', (WidgetTester tester) async {
    DateTime clock = DateTime(2026, 8, 21, 9, 0);
    final AppContainer container = await pumpApp(
      tester,
      accessClock: () => clock,
      gracePeriod: const Duration(seconds: 30),
    );
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');
    final StaticAccessibilityLockService a11y =
        container.accessibility as StaticAccessibilityLockService;

    await openApp(tester, container, 'com.whatsapp');
    await enterPin(tester, '1234');
    expect(find.byType(PinUnlockScreen), findsNothing);

    // Leave and return 10s later: inside grace, no challenge.
    a11y.emitForegroundPackage('com.example.launcher');
    clock = DateTime(2026, 8, 21, 9, 0, 10);
    a11y.emitForegroundPackage('com.whatsapp');
    await tester.pumpAndSettle();
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);

    // Leave again; return past the grace: challenge.
    a11y.emitForegroundPackage('com.example.launcher');
    clock = DateTime(2026, 8, 21, 9, 1);
    a11y.emitForegroundPackage('com.whatsapp');
    await tester.pumpAndSettle();
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    await enterPin(tester, '1234');
    expect(find.byType(PinUnlockScreen), findsNothing);
  });

  // -------------------------------------------------------------------
  // 10. Pattern gate (positive + negative)
  // -------------------------------------------------------------------
  testWidgets('GAUNTLET 10: the pattern gate blocks wrong drawings and '
      'opens on the correct one', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPattern(const <int>[3, 6, 9, 8]);
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PatternUnlockScreen), findsOneWidget);

    // Wrong drawing: blocked.
    await drawPattern(tester, const <int>[1, 2, 3, 5]);
    expect(find.byType(PatternUnlockScreen), findsOneWidget);
    expect(sessionFor(container, 'com.whatsapp'), isNull);
    expect(appsOf(container).launchAppCalls, 0);

    // Correct drawing: granted + launched.
    await drawPattern(tester, const <int>[3, 6, 9, 8]);
    await tester.pumpAndSettle();
    expect(find.byType(PatternUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNotNull);
    expect(appsOf(container).launchAppCalls, 1);
  });

  // -------------------------------------------------------------------
  // 11. Process recreation (persisted-state recovery)
  // -------------------------------------------------------------------
  testWidgets(
      'GAUNTLET 11: process death mid-challenge recovers locked',
      (WidgetTester tester) async {
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

    // The process dies mid-challenge.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    // Reborn over the SAME persisted stores: the challenge re-presents
    // immediately (baseline enforcement + persisted credential).
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final AppContainer boot2 = boot();
    (boot2.installedAppsService as StaticInstalledAppsService)
        .foregroundPackage = 'com.whatsapp';
    await boot2.foregroundMonitor.probe();
    await tester.pumpWidget(SmartAppLockApp(container: boot2));
    await tester.pumpAndSettle();

    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(sessionFor(boot2, 'com.whatsapp'), isNull);

    await enterPin(tester, '1234');
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(sessionFor(boot2, 'com.whatsapp'), isNotNull);
    expect(appsOf(boot2).launchAppCalls, 1);
  });

  // -------------------------------------------------------------------
  // 12. Fail-safe: no credential -> never locked out of the device
  // -------------------------------------------------------------------
  testWidgets(
      'GAUNTLET 12: without a credential, the lock engine never bricks '
      'the device', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');

    // No credential exists: no challenge can be presented (setup lives
    // on the Security tab), the app is never launched by the engine,
    // and no session is granted.
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(find.byType(PatternUnlockScreen), findsNothing);
    expect(sessionFor(container, 'com.whatsapp'), isNull);
    expect(appsOf(container).launchAppCalls, 0);
    expect(tester.takeException(), isNull);
  });

  /// Draws [nodes] on the unlock screen's pattern grid (bounds-derived
  /// centers, arena-winning horizontal move, micro-stepped strokes).
  Future<void> drawPattern(WidgetTester tester, List<int> nodes) async {
    await tester.pump(const Duration(milliseconds: 450));
    final Finder gridFinder = find.byType(DsPatternGrid);
    expect(gridFinder, findsOneWidget);
    final Rect bounds = tester.getRect(gridFinder);

    final double pad = bounds.width * 0.10;
    final double step = (bounds.width - 2 * pad) / 2;
    Offset center(int node) {
      final int i = node - 1;
      return Offset(
        bounds.left + pad + (i % 3) * step,
        bounds.top + pad + (i ~/ 3) * step,
      );
    }

    final TestGesture gesture =
        await tester.startGesture(center(nodes.first));
    await tester.pump();
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();

    Offset current = center(nodes.first).translate(20, 0);
    for (final int node in nodes.skip(1)) {
      final Offset target = center(node);
      const int steps = 6;
      for (int s = 1; s <= steps; s++) {
        final Offset next = Offset(
          current.dx + (target.dx - current.dx) * s / steps,
          current.dy + (target.dy - current.dy) * s / steps,
        );
        await gesture.moveTo(next);
        await tester.pump();
      }
      current = target;
    }
    await gesture.up();
    await tester.pump();
  }
}
