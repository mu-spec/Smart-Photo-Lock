import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/router.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_native_challenge_contract.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/pending_lock_challenge.dart';
import 'package:smart_app_lock/ui/screens/diagnostics/detection_diagnostics_screen.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_setup_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_setup_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/shell/main_shell.dart';

/// Phase 6 / Milestone 1 — Alternate Entry Paths.
///
/// SIMULATED. Nothing here executes Kotlin, Android, a launcher, a
/// notification, a share sheet, a widget host, Accessibility, UsageEvents
/// or a real overlay window, and nothing here is evidence of device
/// behaviour.
///
/// Android delivers every alternate entry (notification tap or action
/// that opens UI, deep link / external VIEW intent, ACTION_SEND /
/// ACTION_SEND_MULTIPLE target, launcher shortcut, widget click) by
/// RESUMING AN ACTIVITY OF THE TARGET PACKAGE, often inside the caller's
/// task. Smart App Lock never intercepts those intents (it cannot); it sees
/// the resulting window as a foreground report for the protected package.
/// The groups below replay the report sequences each path produces:
///
///  * Group A — [StaticNativeChallengeContract], the Dart model of the
///    Kotlin `WatcherService` ticket rules (the Kotlin policy itself is in
///    `android/app/src/test/.../AlternateEntryPathTest.kt`);
///  * Group B — the production Dart wiring (monitor → matcher → controller
///    → trigger → host → router → unlock screens) driven through the
///    static Accessibility service;
///  * Group C — Smart App Lock's OWN exported Activity: an external intent
///    (deep link data or Flutter's `route` extra) must never choose a
///    destination in this app's navigator.
const String _pkg = 'com.whatsapp';
const String _other = 'com.example.bank';
const String _launcher = 'com.example.launcher';
const String _systemUi = 'com.android.systemui';
const String _browser = 'com.android.chrome';
const String _gallery = 'com.example.gallery';

/// Android 10-13 chooser package (H-1 transient) and the Android 14+
/// IntentResolver chooser (an ordinary unprotected Activity).
const String _frameworkChooser = 'android';
const String _intentResolver = 'com.android.intentresolver';

/// Report sequences that end with the protected package in front.
const Map<String, List<String>> _entryPaths = <String, List<String>>{
  'notification tap from Home (shade, then the app)': <String>[
    _launcher,
    _systemUi,
    _pkg,
  ],
  'heads-up notification tapped inside another app': <String>[
    _browser,
    _systemUi,
    _pkg,
  ],
  'deep link / external VIEW intent (target runs in the caller task)':
      <String>[_browser, _pkg],
  'ACTION_SEND through the framework chooser': <String>[
    _gallery,
    _frameworkChooser,
    _pkg,
  ],
  'ACTION_SEND_MULTIPLE through the Android 14+ IntentResolver': <String>[
    _gallery,
    _intentResolver,
    _pkg,
  ],
  'launcher shortcut (static, dynamic or pinned)': <String>[_launcher, _pkg],
  'home-screen widget click': <String>[_launcher, _pkg],
};

void main() {
  // -------------------------------------------------------------------
  // Group A — native ticket contract (SIMULATED Dart model)
  // -------------------------------------------------------------------
  group('SIMULATED A: native contract — alternate entry never grants', () {
    StaticNativeChallengeContract configured() {
      final StaticNativeChallengeContract native =
          StaticNativeChallengeContract();
      native.configure(enabled: true, packages: <String>{_pkg, _other});
      return native;
    }

    void replay(StaticNativeChallengeContract native, List<String> path) {
      for (final String package in path) {
        native.reportForeground(package);
      }
    }

    for (final MapEntry<String, List<String>> path in _entryPaths.entries) {
      test('SIMULATED: ${path.key} -> shield + exactly one pending ticket, '
          'no authorization; only the exact ready ticket authorizes', () {
        final StaticNativeChallengeContract native = configured();
        native.activityResumed = false;
        replay(native, path.value);

        expect(native.shieldVisible, isTrue);
        expect(native.pending?.packageName, _pkg);
        expect(native.authorizedPackages, isEmpty);
        expect(native.recoveryAttempts, isNotEmpty);
        final PendingLockChallenge ticket = native.pending!;

        // Authentication from a route that was never handed coverage
        // cannot grant, even with the right ticket.
        expect(native.authorizePackage(ticket), isFalse);
        expect(native.authorizedPackages, isEmpty);

        native.activityResumed = true;
        expect(native.markChallengeReady(ticket), isTrue);
        expect(native.authorizePackage(ticket), isTrue);
        expect(native.authorizedPackages, <String>{_pkg});
        expect(native.pending, isNull);
      });
    }

    test(
        'SIMULATED: a notification action that opens no UI (only System UI '
        'is reported) creates no ticket and no authorization', () {
      final StaticNativeChallengeContract native = configured();
      replay(native, <String>[_launcher, _systemUi, _launcher]);
      expect(native.pending, isNull);
      expect(native.authorizedPackages, isEmpty);
    });

    test(
        'SIMULATED: repeated / rapid alternate entries keep ONE ticket '
        'generation and never authorize', () {
      final StaticNativeChallengeContract native = configured();
      native.activityResumed = false;
      replay(native, <String>[_launcher, _pkg]);
      final PendingLockChallenge first = native.pending!;
      for (int i = 0; i < 25; i++) {
        replay(native, <String>[
          _systemUi,
          _pkg, // notification tap
          _browser,
          _pkg, // deep link
          _frameworkChooser,
          _pkg, // share
          _launcher,
          _pkg, // shortcut / widget
        ]);
      }
      expect(native.pending, first, reason: 'no stacked tickets');
      expect(native.authorizedPackages, isEmpty);
      expect(native.shieldVisible, isTrue);
    });

    test(
        'SIMULATED: a late success for a challenge replaced by a different '
        'protected entry can never authorize either package', () {
      final StaticNativeChallengeContract native = configured();
      replay(native, <String>[_launcher, _pkg]);
      final PendingLockChallenge stale = native.pending!;
      expect(native.markChallengeReady(stale), isTrue);

      // A notification for ANOTHER protected app is tapped above the
      // rendered challenge.
      replay(native, <String>[_systemUi, _other]);
      expect(native.pending?.packageName, _other);
      expect(native.readyChallenge, isNull);
      expect(native.authorizePackage(stale), isFalse);
      expect(native.authorizedPackages, isEmpty);
    });

    test(
        'SIMULATED: entering protected B from authorized A (share or deep '
        'link) never inherits A\'s authorization', () {
      final StaticNativeChallengeContract native = configured();
      replay(native, <String>[_launcher, _pkg]);
      final PendingLockChallenge ticket = native.pending!;
      expect(native.markChallengeReady(ticket), isTrue);
      expect(native.authorizePackage(ticket), isTrue);
      native.onActivityPaused();
      native.reportForeground(_pkg);
      expect(native.authorizedPackages, <String>{_pkg});

      replay(native, <String>[_frameworkChooser, _other]);
      expect(native.pending?.packageName, _other);
      expect(native.authorizedPackages, isNot(contains(_other)));
      expect(native.shieldVisible, isTrue);
    });
  });

  // -------------------------------------------------------------------
  // Group B — production Dart wiring (SIMULATED platform)
  // -------------------------------------------------------------------
  group('SIMULATED B: production wiring — every entry path is challenged',
      () {
    late InMemoryLocalDatabase database;
    late InMemorySecretStore secretStore;

    setUp(() {
      database = InMemoryLocalDatabase();
      secretStore = InMemorySecretStore();
    });

    Future<AppContainer> pumpApp(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final AppContainer container = AppContainer.inMemory(
        database: database,
        secretStore: secretStore,
      );
      await tester.pumpWidget(SmartAppLockApp(container: container));
      await tester.pumpAndSettle();
      await container.auth.enrollPin('1234');
      await container.protectedApps.add(
        ProtectedApp(
          packageName: _pkg,
          label: _pkg,
          addedAt: DateTime(2026, 10, 31),
        ),
      );
      await container.protectionBootstrap.synchronize();
      return container;
    }

    Future<void> replay(
      WidgetTester tester,
      AppContainer container,
      List<String> path,
    ) async {
      final StaticAccessibilityLockService a11y =
          container.accessibility as StaticAccessibilityLockService;
      for (final String package in path) {
        a11y.emitForegroundPackage(package);
      }
      await tester.pumpAndSettle();
    }

    Future<void> enterPin(WidgetTester tester, String pin) async {
      for (final String digit in pin.split('')) {
        await tester.tap(find.byKey(Key('pin_key_$digit')));
        await tester.pumpAndSettle();
      }
    }

    Object? sessionFor(AppContainer container) =>
        (container.accessController as DefaultAccessController)
            .sessionFor(_pkg);

    StaticInstalledAppsService appsOf(AppContainer container) =>
        container.installedAppsService as StaticInstalledAppsService;

    for (final MapEntry<String, List<String>> path in _entryPaths.entries) {
      testWidgets(
          'SIMULATED: ${path.key} -> one challenge; wrong PIN never opens; '
          'correct PIN grants once', (WidgetTester tester) async {
        final AppContainer container = await pumpApp(tester);

        await replay(tester, container, path.value);
        expect(find.byType(PinUnlockScreen), findsOneWidget);
        expect(sessionFor(container), isNull);

        await enterPin(tester, '9999');
        expect(find.byType(PinUnlockScreen), findsOneWidget);
        expect(sessionFor(container), isNull);
        expect(appsOf(container).launchAppCalls, 0);

        await enterPin(tester, '1234');
        expect(find.byType(PinUnlockScreen), findsNothing);
        expect(sessionFor(container), isNotNull);
        expect(appsOf(container).launchAppCalls, 1);
      });
    }

    testWidgets(
        'SIMULATED: a storm of mixed alternate entries never stacks '
        'challenges and never opens the app', (WidgetTester tester) async {
      final AppContainer container = await pumpApp(tester);
      final StaticOverlayLockService overlay =
          container.overlay as StaticOverlayLockService;

      await replay(tester, container, <String>[_launcher, _pkg]);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      final int shows = overlay.showLockChallengeCalls;

      for (int i = 0; i < 5; i++) {
        await replay(tester, container, <String>[
          _systemUi,
          _pkg,
          _browser,
          _pkg,
          _frameworkChooser,
          _pkg,
          _launcher,
          _pkg,
        ]);
      }
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(overlay.showLockChallengeCalls, shows);
      expect(sessionFor(container), isNull);
      expect(appsOf(container).launchAppCalls, 0);

      await enterPin(tester, '1234');
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(appsOf(container).launchAppCalls, 1);
    });

    testWidgets(
        'SIMULATED: after leaving, a notification re-entry is challenged '
        'again (immediate re-lock; no session survives the leave)',
        (WidgetTester tester) async {
      final AppContainer container = await pumpApp(tester);
      await replay(tester, container, <String>[_launcher, _pkg]);
      await enterPin(tester, '1234');
      expect(sessionFor(container), isNotNull);

      await replay(tester, container, <String>[_launcher]);
      expect(sessionFor(container), isNull);
      await replay(tester, container, <String>[_systemUi, _pkg]);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(sessionFor(container), isNull);
    });
  });

  // -------------------------------------------------------------------
  // Group C — Smart App Lock's own exported Activity
  // -------------------------------------------------------------------
  group('SIMULATED C: external intents never drive this app\'s navigator',
      () {
    late InMemoryLocalDatabase database;
    late InMemorySecretStore secretStore;

    setUp(() {
      database = InMemoryLocalDatabase();
      secretStore = InMemorySecretStore();
    });

    Future<AppContainer> pumpApp(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final AppContainer container = AppContainer.inMemory(
        database: database,
        secretStore: secretStore,
      );
      await tester.pumpWidget(SmartAppLockApp(container: container));
      await tester.pumpAndSettle();
      return container;
    }

    /// What the Flutter Android embedding sends for an intent's data URI
    /// when deep linking is enabled (`onNewIntent` → pushRouteInformation).
    Future<void> pushRouteInformation(
      WidgetTester tester,
      String location,
    ) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.navigation.name,
        SystemChannels.navigation.codec.encodeMethodCall(
          MethodCall('pushRouteInformation', <String, dynamic>{
            'location': location,
            'state': null,
          }),
        ),
        (ByteData? _) {},
      );
      await tester.pumpAndSettle();
    }

    /// The legacy `pushRoute` navigation-channel message.
    Future<void> pushRoute(WidgetTester tester, String route) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.navigation.name,
        SystemChannels.navigation.codec
            .encodeMethodCall(MethodCall('pushRoute', route)),
        (ByteData? _) {},
      );
      await tester.pumpAndSettle();
    }

    for (final String injected in <String>[
      '/pin/setup',
      '/diagnostics/detection',
      '/pin/unlock',
    ]) {
      testWidgets(
          'SIMULATED: a platform initial route "$injected" (intent data or '
          'the `route` extra) is ignored at cold start',
          (WidgetTester tester) async {
        tester.platformDispatcher.defaultRouteNameTestValue = injected;
        addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
        await pumpApp(tester);

        expect(find.byType(MainShell), findsOneWidget);
        expect(find.byType(PinSetupScreen), findsNothing);
        expect(find.byType(DetectionDiagnosticsScreen), findsNothing);
        expect(find.byType(PinUnlockScreen), findsNothing);
      });
    }

    for (final String location in <String>[
      '/pin/setup',
      'smartapplock://open/pin/setup',
      'https://example.com/diagnostics/detection',
    ]) {
      testWidgets(
          'SIMULATED: a warm deep link "$location" pushes nothing',
          (WidgetTester tester) async {
        await pumpApp(tester);
        await pushRouteInformation(tester, location);
        await pushRoute(tester, location);

        expect(find.byType(MainShell), findsOneWidget);
        expect(find.byType(PinSetupScreen), findsNothing);
        expect(find.byType(DetectionDiagnosticsScreen), findsNothing);
      });
    }

    testWidgets(
        'SIMULATED: a deep link delivered while a lock challenge is on '
        'screen cannot cover or replace it; the exact challenge still grants',
        (WidgetTester tester) async {
      final AppContainer container = await pumpApp(tester);
      await container.auth.enrollPin('1234');
      await container.protectedApps.add(
        ProtectedApp(
          packageName: _pkg,
          label: _pkg,
          addedAt: DateTime(2026, 10, 31),
        ),
      );
      await container.protectionBootstrap.synchronize();
      (container.accessibility as StaticAccessibilityLockService)
          .emitForegroundPackage(_pkg);
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      await pushRouteInformation(tester, '/pin/setup');
      await pushRoute(tester, '/diagnostics/detection');
      expect(find.byType(PinSetupScreen), findsNothing);
      expect(find.byType(DetectionDiagnosticsScreen), findsNothing);
      final Route<dynamic>? top = ModalRoute.of(
        tester.element(find.byType(PinUnlockScreen)),
      );
      expect(top?.isCurrent, isTrue, reason: 'the challenge stays on top');

      for (final String digit in '1234'.split('')) {
        await tester.tap(find.byKey(Key('pin_key_$digit')));
        await tester.pumpAndSettle();
      }
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(
        (container.accessController as DefaultAccessController)
            .sessionFor(_pkg),
        isNotNull,
      );
    });

    // Phase 6 / M1 pre-commit review additions.

    Future<void> popRoute(WidgetTester tester) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.navigation.name,
        SystemChannels.navigation.codec
            .encodeMethodCall(const MethodCall('popRoute')),
        (ByteData? _) {},
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
        'SIMULATED: with the guard installed, in-app named navigation still '
        'opens every pushed screen and system Back still pops it',
        (WidgetTester tester) async {
      await pumpApp(tester);
      final Map<String, Type> internal = <String, Type>{
        RouteNames.pinSetup: PinSetupScreen,
        RouteNames.patternSetup: PatternSetupScreen,
        RouteNames.detectionDiagnostics: DetectionDiagnosticsScreen,
      };
      for (final MapEntry<String, Type> entry in internal.entries) {
        final NavigatorState navigator =
            Navigator.of(tester.element(find.byType(MainShell)));
        unawaited(navigator.pushNamed<Object?>(entry.key));
        await tester.pumpAndSettle();
        expect(find.byType(entry.value), findsOneWidget, reason: entry.key);

        await popRoute(tester);
        expect(find.byType(entry.value), findsNothing, reason: entry.key);
        expect(find.byType(MainShell), findsOneWidget, reason: entry.key);
      }
    });

    testWidgets(
        'SIMULATED: a cold-start injected route plus a challenge raised at '
        'startup leaves only the shell under the challenge',
        (WidgetTester tester) async {
      tester.platformDispatcher.defaultRouteNameTestValue = '/pin/setup';
      addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
      final AppContainer container = await pumpApp(tester);
      await container.auth.enrollPin('1234');
      await container.protectedApps.add(
        ProtectedApp(
          packageName: _pkg,
          label: _pkg,
          addedAt: DateTime(2026, 10, 31),
        ),
      );
      await container.protectionBootstrap.synchronize();
      (container.accessibility as StaticAccessibilityLockService)
          .emitForegroundPackage(_pkg);
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(find.byType(PinSetupScreen), findsNothing);

      for (final String digit in '1234'.split('')) {
        await tester.tap(find.byKey(Key('pin_key_$digit')));
        await tester.pumpAndSettle();
      }
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(find.byType(PinSetupScreen), findsNothing);
      expect(find.byType(MainShell), findsOneWidget);
      final Route<dynamic>? shell =
          ModalRoute.of(tester.element(find.byType(MainShell)));
      expect(shell?.isFirst, isTrue);
      expect(shell?.isCurrent, isTrue);
    });

    testWidgets(
        'SIMULATED: the guard is removed with the app (no leaked observer)',
        (WidgetTester tester) async {
      await pumpApp(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      // A plain app mounted afterwards receives platform route pushes again,
      // which is only possible if the disposed guard no longer consumes them.
      await tester.pumpWidget(
        MaterialApp(
          routes: <String, WidgetBuilder>{
            '/': (_) => const Text('plain-home'),
            '/next': (_) => const Text('plain-next'),
          },
        ),
      );
      await tester.pumpAndSettle();
      await pushRoute(tester, '/next');
      expect(find.text('plain-next'), findsOneWidget);
    });
  });
}
