// Phase 5 / M2: challenge host authentication binding (HB-1) and Home
// dismissal by route identity (HB-2).
//
// SIMULATED widget tests: the real LockChallengeHost, real credential
// manager (in memory) and StaticNativeChallengeContract, the test double of
// the Kotlin exact-ticket handoff contract. Nothing here runs on Android.
//
// HB-1: the host granted on ANY `true` that completed its challenge route.
// A grant now also needs an AuthSuccess recorded by that challenge's own
// recorder. A bare `navigator.pop(true)` stands in for any producer of a
// stray `true` (a regression, a foreign screen, a future change).
//
// HB-2: Home dismissal used an untargeted `navigator.pop()`. It now removes
// exactly the active challenge route, and nothing else.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/security/credentials/biometric_options.dart';
import 'package:smart_app_lock/services/biometric_service.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_native_challenge_contract.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_screen_state_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/pending_lock_challenge.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/utilities/result.dart';

const String _pin = '1234';
const String _wrongPin = '0000';
const List<int> _pattern = <int>[1, 2, 3, 6, 9];
const String _pkgA = 'com.whatsapp';
const String _pkgB = 'com.instagram.android';
const String _foreignText = 'foreign-flow-route';

// -- fakes --------------------------------------------------------------------

/// Holds `security_settings` writes while armed: the gap between a matched
/// credential and the verification result reaching the screen.
class _GatedDb extends InMemoryLocalDatabase {
  Completer<void>? _gate;
  int held = 0;

  void arm() => _gate = Completer<void>();

  void release() {
    final Completer<void>? gate = _gate;
    _gate = null;
    gate?.complete();
  }

  @override
  Future<void> setSetting(String key, String value) async {
    final Completer<void>? gate = _gate;
    if (gate != null && key == 'security_settings') {
      held++;
      await gate.future;
    }
    await super.setSetting(key, value);
  }
}

/// Biometric prompt double: passes, or is cancelled by the user.
class _Biometrics implements BiometricService {
  _Biometrics({this.cancel = false});
  bool cancel;
  int prompts = 0;

  @override
  Future<Result<bool>> isSupported() async => Result.success(true);

  @override
  Future<Result<Set<BiometricKind>>> availableKinds() async =>
      Result.success(const <BiometricKind>{BiometricKind.strong});

  @override
  Future<Result<bool>> authenticate({
    required String reason,
    BiometricOptions? options,
  }) async {
    prompts++;
    if (cancel) {
      return Result.failure(const BiometricAuthException(
        code: 'userCanceled',
        message: 'cancelled',
      ));
    }
    return Result.success(true);
  }
}

/// Native double that can run a callback INSIDE `authorizePackage`, i.e.
/// while the host is between the challenge route's completion and the end
/// of its grant (in production that is a platform-channel round trip).
class _HookedNative extends StaticNativeChallengeContract {
  void Function()? duringAuthorize;

  @override
  bool authorizePackage(PendingLockChallenge challenge) {
    final void Function()? hook = duringAuthorize;
    duringAuthorize = null;
    hook?.call();
    return super.authorizePackage(challenge);
  }
}

// -- harness ------------------------------------------------------------------

class _App {
  _App(this.tester, this.c, this.native, this.db);

  final WidgetTester tester;
  final AppContainer c;
  final StaticNativeChallengeContract native;
  final _GatedDb db;

  StaticWatcherService get watcher => c.watcher as StaticWatcherService;
  StaticOverlayLockService get overlay => c.overlay as StaticOverlayLockService;
  StaticInstalledAppsService get apps =>
      c.installedAppsService as StaticInstalledAppsService;

  Object? session(String pkg) =>
      (c.accessController as DefaultAccessController).sessionFor(pkg);

  NavigatorState get navigator =>
      tester.state<NavigatorState>(find.byType(Navigator).first);

  /// Production order: Accessibility reports to native first, then Dart.
  Future<void> open(String pkg) async {
    native.reportForeground(pkg);
    (c.accessibility as StaticAccessibilityLockService)
        .emitForegroundPackage(pkg);
    await tester.pumpAndSettle();
  }

  /// Dart-side requirement only (no settle): used for rapid switching.
  void requireDartOnly(String pkg) =>
      (c.accessibility as StaticAccessibilityLockService)
          .emitForegroundPackage(pkg);

  /// A bare, credential-less `true` onto whatever route is on top.
  Future<void> barePopTrue() async {
    navigator.pop(true);
    await tester.pumpAndSettle();
  }

  void expectNothingAuthorized() {
    expect(native.authorizedPackages, isEmpty);
    expect(watcher.authorizePackageCalls, 0);
    expect(session(_pkgA), isNull);
    expect(session(_pkgB), isNull);
    expect(overlay.hideLockChallengeCalls, 0);
    expect(apps.launchAppCalls, 0);
  }

  void expectGrantedOnce(String pkg) {
    expect(native.authorizedPackages, contains(pkg));
    expect(watcher.authorizePackageCalls, 1);
    expect(native.authorizeRejections, 0);
    expect(session(pkg), isNotNull);
    expect(apps.launchedPackages, <String>[pkg]);
    expect(native.pending, isNull, reason: 'the exact ticket was consumed');
  }
}

Future<_App> _launch(
  WidgetTester tester, {
  bool pattern = false,
  BiometricService? biometrics,
  bool biometricEnabled = false,
  Set<String> protect = const <String>{_pkgA},
  StaticNativeChallengeContract? nativeModel,
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final _GatedDb db = _GatedDb();
  final AppContainer c =
      AppContainer.inMemory(database: db, biometrics: biometrics);
  final StaticNativeChallengeContract native =
      _bindNative(c, nativeModel ?? StaticNativeChallengeContract());
  await tester.pumpWidget(SmartAppLockApp(container: c));
  await tester.pumpAndSettle();
  if (pattern) {
    await c.auth.enrollPattern(_pattern);
  } else {
    await c.auth.enrollPin(_pin);
  }
  if (biometricEnabled) {
    await c.auth.updateBiometricOptions(const BiometricOptions());
  }
  for (final String pkg in protect) {
    await c.protectedApps.add(ProtectedApp(
      packageName: pkg,
      label: pkg,
      addedAt: DateTime(2026, 10, 29),
    ));
  }
  await c.protectionBootstrap.synchronize();
  return _App(tester, c, native, db);
}

/// Same wiring as [StaticNativeChallengeContract.bind], for any model.
StaticNativeChallengeContract _bindNative(
  AppContainer c,
  StaticNativeChallengeContract contract,
) {
  final StaticOverlayLockService overlay = c.overlay as StaticOverlayLockService;
  final StaticWatcherService watcher = c.watcher as StaticWatcherService;
  overlay.nativeContract = contract;
  watcher.nativeContract = contract;
  contract.configure(
    enabled: watcher.protectionConfigured,
    packages: Set<String>.of(watcher.protectedPackages),
  );
  return contract;
}

Future<void> _typePin(WidgetTester tester, String pin) async {
  for (final String digit in pin.split('')) {
    await tester.tap(find.byKey(Key('pin_key_$digit')));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _drawPattern(WidgetTester tester, List<int> nodes) async {
  await tester.pump(const Duration(milliseconds: 450));
  final Finder grid = find.byType(DsPatternGrid);
  expect(grid, findsOneWidget);
  final Rect bounds = tester.getRect(grid);
  final double pad = bounds.width * 0.10;
  final double step = (bounds.width - 2 * pad) / 2;
  Offset center(int node) {
    final int i = node - 1;
    return Offset(
      bounds.left + pad + (i % 3) * step,
      bounds.top + pad + (i ~/ 3) * step,
    );
  }

  final TestGesture gesture = await tester.startGesture(center(nodes.first));
  await tester.pump();
  await gesture.moveBy(const Offset(20, 0));
  await tester.pump();
  Offset current = center(nodes.first).translate(20, 0);
  for (final int node in nodes.skip(1)) {
    final Offset target = center(node);
    for (int s = 1; s <= 6; s++) {
      await gesture.moveTo(Offset(
        current.dx + (target.dx - current.dx) * s / 6,
        current.dy + (target.dy - current.dy) * s / 6,
      ));
      await tester.pump();
    }
    current = target;
  }
  await gesture.up();
  await tester.pump();
}

/// A real Home press: Flutter goes inactive, hidden, paused.
Future<void> _home(WidgetTester tester) async {
  for (final AppLifecycleState s in <AppLifecycleState>[
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
    await tester.pump();
  }
}

/// Returning to the app (Recents or the launcher icon).
Future<void> _resume(WidgetTester tester) async {
  for (final AppLifecycleState s in <AppLifecycleState>[
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// Pushes a foreign route (for example, a settings flow resuming after an
/// await) and tracks how its future completes.
class _Foreign {
  bool completed = false;
  Object? result;
}

_Foreign _pushForeign(_App app) {
  final _Foreign f = _Foreign();
  app.navigator
      .push<Object?>(MaterialPageRoute<Object?>(
        builder: (_) => const Scaffold(body: Center(child: Text(_foreignText))),
      ))
      .then((Object? v) {
    f.completed = true;
    f.result = v;
  });
  return f;
}

Finder get _foreignAnywhere => find.text(_foreignText, skipOffstage: false);

void main() {
  // ---------------------------------------------------------------------------
  group('HB-1: a bare route result never grants', () {
    testWidgets(
        'PIN challenge: programmatic pop(true) without authentication is '
        'rejected, the challenge returns, then the real PIN grants once',
        (WidgetTester tester) async {
      final _App app = await _launch(tester);
      await app.open(_pkgA);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      final int generation = app.native.pending!.generation;

      await app.barePopTrue();

      app.expectNothingAuthorized();
      expect(app.native.pending?.generation, generation,
          reason: 'the unresolved ticket stays pending');
      expect(find.byType(PinUnlockScreen), findsOneWidget,
          reason: 'the challenge is re-presented');

      await _typePin(tester, _pin);
      await tester.pumpAndSettle();
      app.expectGrantedOnce(_pkgA);
    });

    testWidgets(
        'pattern challenge: programmatic pop(true) is rejected; the real '
        'pattern grants once', (WidgetTester tester) async {
      final _App app = await _launch(tester, pattern: true);
      await app.open(_pkgA);
      expect(find.byType(PatternUnlockScreen), findsOneWidget);

      await app.barePopTrue();
      app.expectNothingAuthorized();
      expect(find.byType(PatternUnlockScreen), findsOneWidget);

      await _drawPattern(tester, _pattern);
      await tester.pumpAndSettle();
      app.expectGrantedOnce(_pkgA);
    });

    testWidgets(
        'wrong PIN x3 reaches lockout without a grant; a bare pop(true) '
        'during lockout is still rejected', (WidgetTester tester) async {
      final _App app = await _launch(tester);
      await app.open(_pkgA);
      for (int i = 0; i < 3; i++) {
        await _typePin(tester, _wrongPin);
        await tester.pumpAndSettle();
      }
      expect(find.text(PinUnlockScreen.lockedOutTitle), findsOneWidget);
      app.expectNothingAuthorized();

      await app.barePopTrue();
      app.expectNothingAuthorized();
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(find.text(PinUnlockScreen.lockedOutTitle), findsOneWidget,
          reason: 'the re-presented challenge still shows the lockout');
    });

    testWidgets(
        'cancelled biometric never grants and is not counted; a bare '
        'pop(true) afterwards is rejected; the PIN still grants once',
        (WidgetTester tester) async {
      final _Biometrics bio = _Biometrics(cancel: true);
      final _App app =
          await _launch(tester, biometrics: bio, biometricEnabled: true);
      await app.open(_pkgA);
      await tester.tap(find.byKey(const Key('pin_key_biometric')));
      await tester.pumpAndSettle();
      expect(bio.prompts, greaterThanOrEqualTo(1));
      app.expectNothingAuthorized();

      await app.barePopTrue();
      app.expectNothingAuthorized();

      await _typePin(tester, _pin);
      await tester.pumpAndSettle();
      app.expectGrantedOnce(_pkgA);
    });

    testWidgets(
        'a new challenge cannot consume an earlier challenge\'s result: a late '
        'success of a dismissed challenge and a bare pop(true) on the new one '
        'both fail; the new challenge\'s own PIN grants once',
        (WidgetTester tester) async {
      final _App app = await _launch(tester);
      await app.open(_pkgA);
      final int showsBefore = app.overlay.showLockChallengeCalls;

      app.db.arm();
      await _typePin(tester, _pin); // verification #1 held in flight
      expect(app.db.held, 1);
      await _home(tester); // challenge #1 dismissed
      await _resume(tester); // challenge #2 presented from the native ticket
      expect(app.overlay.showLockChallengeCalls, showsBefore + 1);
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      app.db.release(); // challenge #1's success lands late
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      app.expectNothingAuthorized();
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      await app.barePopTrue(); // nothing was recorded for challenge #2
      app.expectNothingAuthorized();

      await _typePin(tester, _pin);
      await tester.pumpAndSettle();
      app.expectGrantedOnce(_pkgA);
    });
  });

  // ---------------------------------------------------------------------------
  group('legitimate authentication still grants exactly once', () {
    testWidgets('PIN', (WidgetTester tester) async {
      final _App app = await _launch(tester);
      await app.open(_pkgA);
      await _typePin(tester, _pin);
      await tester.pumpAndSettle();
      app.expectGrantedOnce(_pkgA);
      expect(find.byType(PinUnlockScreen), findsNothing);
    });

    testWidgets('pattern', (WidgetTester tester) async {
      final _App app = await _launch(tester, pattern: true);
      await app.open(_pkgA);
      await _drawPattern(tester, _pattern);
      await tester.pumpAndSettle();
      app.expectGrantedOnce(_pkgA);
      expect(find.byType(PatternUnlockScreen), findsNothing);
    });

    testWidgets('permitted biometric (enabled, enrolled)',
        (WidgetTester tester) async {
      final _Biometrics bio = _Biometrics();
      final _App app =
          await _launch(tester, biometrics: bio, biometricEnabled: true);
      await app.open(_pkgA);
      await tester.tap(find.byKey(const Key('pin_key_biometric')));
      await tester.pumpAndSettle();
      app.expectGrantedOnce(_pkgA);
    });
  });

  // ---------------------------------------------------------------------------
  group('rapid package switching keeps challenges isolated', () {
    testWidgets(
        'A on screen, B queued: a bare pop(true) on A authorizes nothing; '
        'B is challenged next and its own PIN authorizes B only',
        (WidgetTester tester) async {
      final _App app =
          await _launch(tester, protect: const <String>{_pkgA, _pkgB});
      await app.open(_pkgA);
      app.requireDartOnly(_pkgB); // B arrives while A's challenge is up
      await tester.pump();

      await app.barePopTrue();
      app.expectNothingAuthorized();
      expect(app.native.pending?.packageName, _pkgB,
          reason: 'the queued requirement is challenged next');
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      await _typePin(tester, _pin);
      await tester.pumpAndSettle();
      expect(app.native.authorizedPackages, <String>{_pkgB});
      expect(app.session(_pkgA), isNull);
      expect(app.session(_pkgB), isNotNull);
      expect(app.apps.launchedPackages, <String>[_pkgB]);
      expect(app.watcher.authorizePackageCalls, 1);
    });

    testWidgets(
        'A on screen, B queued: A\'s PIN authorizes A only; a bare pop(true) '
        'on B\'s challenge is rejected; B\'s own PIN authorizes B',
        (WidgetTester tester) async {
      final _App app =
          await _launch(tester, protect: const <String>{_pkgA, _pkgB});
      await app.open(_pkgA);
      app.requireDartOnly(_pkgB);
      await tester.pump();

      await _typePin(tester, _pin);
      await tester.pumpAndSettle();
      expect(app.native.authorizedPackages, <String>{_pkgA});
      expect(app.session(_pkgB), isNull);
      expect(app.native.pending?.packageName, _pkgB);
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      await app.barePopTrue();
      expect(app.native.authorizedPackages.contains(_pkgB), isFalse);
      expect(app.session(_pkgB), isNull);
      expect(app.watcher.authorizePackageCalls, 1);
      expect(app.apps.launchedPackages, <String>[_pkgA]);

      await _typePin(tester, _pin);
      await tester.pumpAndSettle();
      expect(app.native.authorizedPackages, contains(_pkgB));
      expect(app.session(_pkgB), isNotNull);
      expect(app.watcher.authorizePackageCalls, 2);
      expect(app.native.authorizeRejections, 0);
      expect(app.apps.launchedPackages, <String>[_pkgA, _pkgB]);
    });
  });

  // ---------------------------------------------------------------------------
  group('HB-2: Home dismisses exactly the challenge route', () {
    testWidgets(
        'Home with a foreign route above the challenge dismisses only the '
        'challenge; the foreign route is untouched; resume re-presents',
        (WidgetTester tester) async {
      final _App app = await _launch(tester);
      await app.open(_pkgA);
      final _Foreign foreign = _pushForeign(app);
      await tester.pumpAndSettle();
      expect(find.text(_foreignText), findsOneWidget);
      final int shows = app.overlay.showLockChallengeCalls;

      await _home(tester);
      expect(foreign.completed, isFalse,
          reason: 'Home must never pop a foreign route');
      app.expectNothingAuthorized();

      await _resume(tester);
      expect(app.overlay.showLockChallengeCalls, shows + 1,
          reason: 'the dismissed challenge is re-presented on resume');
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(_foreignAnywhere, findsOneWidget);
      expect(foreign.completed, isFalse);
      app.expectNothingAuthorized();
    });

    testWidgets(
        'Home / resume / Home / resume stays consistent with a foreign route '
        'present; the PIN then grants once and the foreign route survives',
        (WidgetTester tester) async {
      final _App app = await _launch(tester);
      await app.open(_pkgA);
      final _Foreign foreign = _pushForeign(app);
      await tester.pumpAndSettle();
      final int shows = app.overlay.showLockChallengeCalls;

      await _home(tester);
      await _resume(tester);
      expect(app.overlay.showLockChallengeCalls, shows + 1);
      await _home(tester);
      await _resume(tester);
      expect(app.overlay.showLockChallengeCalls, shows + 2,
          reason: 'the second Home dismissed the challenge again (no latch)');
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(foreign.completed, isFalse);
      app.expectNothingAuthorized();

      await _typePin(tester, _pin);
      await tester.pumpAndSettle();
      app.expectGrantedOnce(_pkgA);
      expect(foreign.completed, isFalse);
      expect(_foreignAnywhere, findsOneWidget);
    });

    testWidgets(
        'control: Home / resume / Home / resume with the challenge on top '
        're-presents each time and still requires the PIN',
        (WidgetTester tester) async {
      final _App app = await _launch(tester);
      await app.open(_pkgA);
      final int shows = app.overlay.showLockChallengeCalls;
      await _home(tester);
      await _resume(tester);
      await _home(tester);
      await _resume(tester);
      expect(app.overlay.showLockChallengeCalls, shows + 2);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      app.expectNothingAuthorized();
      await _typePin(tester, _pin);
      await tester.pumpAndSettle();
      app.expectGrantedOnce(_pkgA);
    });

    testWidgets(
        'Home while the challenge route is already completing (grant in '
        'flight) dismisses nothing else: the route beneath survives, the '
        'grant happens once and the next resume stays consistent',
        (WidgetTester tester) async {
      final _HookedNative hooked = _HookedNative();
      final _App app = await _launch(tester, nativeModel: hooked);
      final _Foreign below = _pushForeign(app); // e.g. a screen in the app
      await tester.pumpAndSettle();
      await app.open(_pkgA);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      final int shows = app.overlay.showLockChallengeCalls;

      bool homeFired = false;
      hooked.duringAuthorize = () {
        homeFired = true;
        for (final AppLifecycleState s in <AppLifecycleState>[
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(s);
        }
      };
      await _typePin(tester, _pin);
      await tester.pump();
      expect(homeFired, isTrue);
      expect(below.completed, isFalse,
          reason: 'Home during the grant must not pop the route beneath');

      await _resume(tester);
      app.expectGrantedOnce(_pkgA);
      expect(below.completed, isFalse);
      expect(_foreignAnywhere, findsOneWidget);
      expect(app.overlay.showLockChallengeCalls, shows,
          reason: 'the granted session is not re-challenged on resume');
    });

    testWidgets(
        'Home in the same turn the challenge route completes (before the '
        'host resumes) is safe: the inactive route is not dismissed again, '
        'the route beneath survives, nothing is granted, resume re-challenges',
        (WidgetTester tester) async {
      final _App app = await _launch(tester);
      final _Foreign below = _pushForeign(app);
      await tester.pumpAndSettle();
      await app.open(_pkgA);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      final int shows = app.overlay.showLockChallengeCalls;

      // Back completes the challenge route (null) and, in the SAME
      // synchronous turn, the Activity leaves — no microtask runs between.
      app.navigator.pop();
      for (final AppLifecycleState s in <AppLifecycleState>[
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
      expect(below.completed, isFalse,
          reason: 'the already-completing challenge route must not cause '
              'a second pop of the route beneath');
      app.expectNothingAuthorized();

      await _resume(tester);
      expect(below.completed, isFalse);
      expect(app.overlay.showLockChallengeCalls, shows + 1);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      app.expectNothingAuthorized();
      await _typePin(tester, _pin);
      await tester.pumpAndSettle();
      app.expectGrantedOnce(_pkgA);
      expect(below.completed, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  group('screen-off and process recreation fail closed', () {
    testWidgets(
        'screen-off during verification: the late success grants nothing; '
        'the wake challenge has a new ticket, rejects a bare pop(true) and '
        'grants once on its own PIN', (WidgetTester tester) async {
      final _App app = await _launch(tester);
      await app.open(_pkgA);
      final int sleepGeneration = app.native.pending!.generation;

      app.db.arm();
      await _typePin(tester, _pin);
      expect(app.db.held, 1);
      // Power button: Activity pauses/stops, native issues a wake ticket.
      app.native.onActivityPaused();
      await _home(tester);
      app.native.screenOff();
      (app.c.screenState as StaticScreenStateService).emitScreenOff();
      await tester.pump();
      app.db.release(); // the pre-sleep verification completes while off
      await tester.pump();
      await tester.pump();
      app.expectNothingAuthorized();

      app.native.screenOn();
      (app.c.screenState as StaticScreenStateService).emitScreenOn();
      app.native.onActivityResumed();
      await _resume(tester);
      app.expectNothingAuthorized();
      expect(app.native.pending, isNotNull);
      expect(app.native.pending!.generation, isNot(sleepGeneration),
          reason: 'SCREEN_OFF replaced the ticket');
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      await app.barePopTrue();
      app.expectNothingAuthorized();

      await _typePin(tester, _pin);
      await tester.pumpAndSettle();
      app.expectGrantedOnce(_pkgA);
    });

    testWidgets(
        'process recreation during verification: nothing is granted; the '
        'new process re-presents the persisted ticket, rejects a bare '
        'pop(true) and grants once on a fresh PIN',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final _GatedDb disk = _GatedDb();
      final InMemorySecretStore secrets = InMemorySecretStore();

      // First process.
      final AppContainer c1 =
          AppContainer.inMemory(database: disk, secretStore: secrets);
      final StaticNativeChallengeContract n1 =
          _bindNative(c1, StaticNativeChallengeContract());
      await c1.auth.enrollPin(_pin);
      await c1.protectedApps.add(ProtectedApp(
        packageName: _pkgA,
        label: _pkgA,
        addedAt: DateTime(2026, 10, 29),
      ));
      await c1.protectionBootstrap.synchronize();
      await tester.pumpWidget(SmartAppLockApp(container: c1));
      await tester.pumpAndSettle();
      final _App p1 = _App(tester, c1, n1, disk);
      await p1.open(_pkgA);
      final PendingLockChallenge ticket = n1.pending!;

      disk.arm();
      await _typePin(tester, _pin); // verification in flight
      expect(disk.held, 1);

      // SIMULATED death: tree torn down; native keeps only persisted state.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      disk.release(); // the dead process's verification completes
      await tester.pump();
      p1.expectNothingAuthorized();
      final bool enabled = n1.enabled;
      final Set<String> packages = Set<String>.of(n1.protectedPackages);
      final String? wake = n1.wakeReauthPackage;

      // Second process from persisted state (see process_death_recovery_test).
      final AppContainer c2 =
          AppContainer.inMemory(database: disk, secretStore: secrets);
      final StaticNativeChallengeContract n2 =
          _bindNative(c2, StaticNativeChallengeContract());
      n2.enabled = enabled;
      n2.protectedPackages = packages;
      while (n2.replacePendingChallenge('__counter__').generation <
          ticket.generation) {}
      n2.pending = ticket;
      n2.wakeReauthPackage = wake;
      n2.readyChallenge = null;
      n2.activityResumed = false;
      n2.shieldVisible = false;
      n2.authorizedPackages.clear();
      n2.currentForegroundPackage = null;
      n2.recoveryRetryTick(); // sticky service restart
      n2.onActivityResumed();
      await tester.pumpWidget(SmartAppLockApp(container: c2));
      await tester.pumpAndSettle();
      final _App p2 = _App(tester, c2, n2, disk);

      expect(find.byType(PinUnlockScreen), findsOneWidget);
      p2.expectNothingAuthorized();
      expect(n2.pending, ticket, reason: 'the persisted ticket is restored');

      await p2.barePopTrue();
      p2.expectNothingAuthorized();

      await _typePin(tester, _pin);
      await tester.pumpAndSettle();
      p2.expectGrantedOnce(_pkgA);
    });
  });
}
