// Phase 5 / Milestone 2: late Navigator.pop authentication race.
//
// A PIN, pattern or biometric verification that completes AFTER its unlock
// screen was dismissed, replaced, removed or covered must never complete a
// different route. Before the fix, the screens called
// `Navigator.of(context).pop(true)` guarded only by `mounted`; `pop` pops
// whichever route is on top, so a stale success could close an unrelated
// route (even the root) or authorize a different protected-app challenge.
//
// The race is reproduced deterministically: [_GatedDb] holds the
// post-verification counter write (`security_settings`), the real async gap
// between "credential matched" and the screen's completion in production.
//
// SIMULATED: Flutter widget-test harness (in-memory stores, Static* platform
// services, StaticNativeChallengeContract for the native exact-ticket rules).
// No device, Gradle or APK verification.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/biometric_options.dart';
import 'package:smart_app_lock/services/biometric_service.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_native_challenge_contract.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/ui/screens/apps/unprotect_gate.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_change_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/security/app_credential_verification.dart';
import 'package:smart_app_lock/utilities/result.dart';

const String _pin = '1234';
const List<int> _pattern = <int>[1, 2, 3, 6, 9];
const String _protected = 'com.whatsapp';
const String _interrupted = 'Verification was interrupted. Please try again.';

/// Holds `security_settings` writes while armed: the persist gap between a
/// matched credential and the screen's completion.
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

class _PassingBiometrics implements BiometricService {
  const _PassingBiometrics();

  @override
  Future<Result<bool>> isSupported() async => Result.success(true);

  @override
  Future<Result<Set<BiometricKind>>> availableKinds() async =>
      Result.success(const <BiometricKind>{BiometricKind.strong});

  @override
  Future<Result<bool>> authenticate({
    required String reason,
    BiometricOptions? options,
  }) async =>
      Result.success(true);
}

/// Records how (and whether) a route's future completed.
class _Completion {
  bool done = false;
  Object? result;

  void track(Future<Object?> future) => future.then((Object? r) {
        done = true;
        result = r;
      });
}

/// ROOT -> UNDER (optional) -> route under test.
class _Stack {
  _Stack(this.key);

  final GlobalKey<NavigatorState> key;
  final _Completion under = _Completion();
  final _Completion screen = _Completion();
  Route<bool>? screenRoute;

  NavigatorState get nav => key.currentState!;

  Future<void> pushScreen(WidgetTester tester, Widget screen) async {
    final Route<bool> route = MaterialPageRoute<bool>(builder: (_) => screen);
    screenRoute = route;
    this.screen.track(nav.push<bool>(route));
    await tester.pumpAndSettle();
  }
}

Future<_Stack> _pumpStack(WidgetTester tester, {bool under = true}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final _Stack stack = _Stack(GlobalKey<NavigatorState>());
  await tester.pumpWidget(MaterialApp(
    navigatorKey: stack.key,
    home: const Scaffold(body: Center(child: Text('ROOT'))),
  ));
  if (under) {
    stack.under.track(stack.nav.push<bool>(MaterialPageRoute<bool>(
      builder: (_) => const Scaffold(body: Center(child: Text('UNDER'))),
    )));
    await tester.pumpAndSettle();
  }
  return stack;
}

Future<void> _typePin(WidgetTester tester, String pin) async {
  for (final String digit in pin.split('')) {
    await tester.tap(find.byKey(Key('pin_key_$digit')));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Bounds-derived, device-like pattern stroke (same approach as the
/// lock-challenge suite).
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

/// System Back, then ONE frame: the dismissed route is popping but its
/// screen is still mounted (reverse transition in progress).
Future<void> _systemBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pump();
}

/// Lets the held verification finish and its continuation run while the
/// dismissed screen is still mounted.
Future<void> _releaseLateSuccess(WidgetTester tester, _GatedDb db) async {
  db.release();
  await tester.pump();
  await tester.pump();
}

Future<void> _frames(WidgetTester tester, int n) async {
  for (int i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  // ===================================================================
  group('Back before success', () {
    testWidgets(
        'PIN: the original route closes with false; the underlying route '
        'remains', (WidgetTester tester) async {
      final _GatedDb db = _GatedDb();
      final AppContainer c = AppContainer.inMemory(database: db);
      await c.auth.enrollPin(_pin);
      final _Stack stack = await _pumpStack(tester);
      await stack.pushScreen(tester, PinUnlockScreen(credentialManager: c.auth));

      db.arm();
      await _typePin(tester, _pin);
      expect(db.held, 1, reason: 'the correct PIN reached the persist gap');
      await _systemBack(tester);
      expect(stack.screen.result, false);
      expect(find.byType(PinUnlockScreen), findsOneWidget,
          reason: 'still mounted during the exit transition');

      await _releaseLateSuccess(tester, db);
      await tester.pumpAndSettle();

      expect(stack.under.done, isFalse);
      expect(find.text('UNDER'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('pattern: no stray success reaches the underlying route',
        (WidgetTester tester) async {
      final _GatedDb db = _GatedDb();
      final AppContainer c = AppContainer.inMemory(database: db);
      await c.auth.enrollPattern(_pattern);
      final _Stack stack = await _pumpStack(tester);
      await stack.pushScreen(
          tester, PatternUnlockScreen(credentialManager: c.auth));

      db.arm();
      await _drawPattern(tester, _pattern);
      expect(db.held, 1);
      await _systemBack(tester);
      await _releaseLateSuccess(tester, db);
      await tester.pumpAndSettle();

      // PatternUnlockScreen has no PopScope: Back resolves null, never true.
      expect(stack.screen.result, isNot(true));
      expect(stack.under.done, isFalse);
      expect(find.text('UNDER'), findsOneWidget);
    });

    testWidgets('PIN over the root route: the root cannot be popped',
        (WidgetTester tester) async {
      final _GatedDb db = _GatedDb();
      final AppContainer c = AppContainer.inMemory(database: db);
      await c.auth.enrollPin(_pin);
      final _Stack stack = await _pumpStack(tester, under: false);
      await stack.pushScreen(tester, PinUnlockScreen(credentialManager: c.auth));

      db.arm();
      await _typePin(tester, _pin);
      await _systemBack(tester);
      await _releaseLateSuccess(tester, db);
      await tester.pumpAndSettle();

      expect(find.text('ROOT'), findsOneWidget,
          reason: 'popping the root would leave an empty navigator');
    });

    testWidgets('pattern over the root route: the root cannot be popped',
        (WidgetTester tester) async {
      final _GatedDb db = _GatedDb();
      final AppContainer c = AppContainer.inMemory(database: db);
      await c.auth.enrollPattern(_pattern);
      final _Stack stack = await _pumpStack(tester, under: false);
      await stack.pushScreen(
          tester, PatternUnlockScreen(credentialManager: c.auth));

      db.arm();
      await _drawPattern(tester, _pattern);
      await _systemBack(tester);
      await _releaseLateSuccess(tester, db);
      await tester.pumpAndSettle();

      expect(find.text('ROOT'), findsOneWidget);
    });

    testWidgets('biometric: a late biometric success after Back is discarded',
        (WidgetTester tester) async {
      final _GatedDb db = _GatedDb();
      final AppContainer c = AppContainer.inMemory(
        database: db,
        biometrics: const _PassingBiometrics(),
      );
      await c.auth.enrollPin(_pin);
      await c.auth.updateBiometricOptions(const BiometricOptions());
      final _Stack stack = await _pumpStack(tester);
      await stack.pushScreen(tester, PinUnlockScreen(credentialManager: c.auth));

      db.arm();
      await tester.tap(find.byKey(const Key('pin_key_biometric')));
      await tester.pump(const Duration(milliseconds: 20));
      expect(db.held, 1, reason: 'the biometric success reached persist');
      await _systemBack(tester);
      await _releaseLateSuccess(tester, db);
      await tester.pumpAndSettle();

      expect(stack.screen.result, false);
      expect(stack.under.done, isFalse);
      expect(find.text('UNDER'), findsOneWidget);
    });

    testWidgets(
        'control: a success after the dismissed screen is disposed changes '
        'nothing', (WidgetTester tester) async {
      final _GatedDb db = _GatedDb();
      final AppContainer c = AppContainer.inMemory(database: db);
      await c.auth.enrollPin(_pin);
      final _Stack stack = await _pumpStack(tester);
      await stack.pushScreen(tester, PinUnlockScreen(credentialManager: c.auth));

      db.arm();
      await _typePin(tester, _pin);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      db.release();
      await tester.pumpAndSettle();

      expect(stack.screen.result, false);
      expect(stack.under.done, isFalse);
    });
  });

  // ===================================================================
  group('route replacement and removal', () {
    testWidgets('pushReplacement: the replacement never receives the result',
        (WidgetTester tester) async {
      final _GatedDb db = _GatedDb();
      final AppContainer c = AppContainer.inMemory(database: db);
      await c.auth.enrollPin(_pin);
      final _Stack stack = await _pumpStack(tester);
      await stack.pushScreen(tester, PinUnlockScreen(credentialManager: c.auth));

      db.arm();
      await _typePin(tester, _pin);
      final _Completion next = _Completion();
      next.track(stack.nav.pushReplacement<bool, bool>(MaterialPageRoute<bool>(
        builder: (_) => const Scaffold(body: Center(child: Text('NEXT'))),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await _releaseLateSuccess(tester, db);
      await tester.pumpAndSettle();

      expect(next.done, isFalse);
      expect(find.text('NEXT'), findsOneWidget);
      expect(stack.under.done, isFalse);
      expect(stack.screen.result, isNot(true));
    });

    testWidgets('removeRoute: nothing else is popped',
        (WidgetTester tester) async {
      final _GatedDb db = _GatedDb();
      final AppContainer c = AppContainer.inMemory(database: db);
      await c.auth.enrollPin(_pin);
      final _Stack stack = await _pumpStack(tester);
      await stack.pushScreen(tester, PinUnlockScreen(credentialManager: c.auth));

      db.arm();
      await _typePin(tester, _pin);
      stack.nav.removeRoute(stack.screenRoute!);
      await tester.pump();
      await _releaseLateSuccess(tester, db);
      await tester.pumpAndSettle();

      expect(stack.under.done, isFalse);
      expect(find.text('UNDER'), findsOneWidget);
      expect(stack.screen.result, isNot(true));
    });
  });

  // ===================================================================
  group('covered screen', () {
    testWidgets('PIN: a covered screen never completes the covering route',
        (WidgetTester tester) async {
      final _GatedDb db = _GatedDb();
      final AppContainer c = AppContainer.inMemory(database: db);
      await c.auth.enrollPin(_pin);
      final _Stack stack = await _pumpStack(tester);
      await stack.pushScreen(tester, PinUnlockScreen(credentialManager: c.auth));

      db.arm();
      await _typePin(tester, _pin);
      final _Completion cover = _Completion();
      cover.track(stack.nav.push<bool>(MaterialPageRoute<bool>(
        builder: (_) => const Scaffold(body: Center(child: Text('COVER'))),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await _releaseLateSuccess(tester, db);
      await tester.pumpAndSettle();

      expect(cover.done, isFalse);
      expect(find.text('COVER'), findsOneWidget);
      expect(stack.screen.done, isFalse);
    });

    testWidgets('pattern: a covered screen never completes the covering route',
        (WidgetTester tester) async {
      final _GatedDb db = _GatedDb();
      final AppContainer c = AppContainer.inMemory(database: db);
      await c.auth.enrollPattern(_pattern);
      final _Stack stack = await _pumpStack(tester);
      await stack.pushScreen(
          tester, PatternUnlockScreen(credentialManager: c.auth));

      db.arm();
      await _drawPattern(tester, _pattern);
      final _Completion cover = _Completion();
      cover.track(stack.nav.push<bool>(MaterialPageRoute<bool>(
        builder: (_) => const Scaffold(body: Center(child: Text('COVER'))),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await _releaseLateSuccess(tester, db);
      await tester.pumpAndSettle();

      expect(cover.done, isFalse);
      expect(stack.screen.done, isFalse);
    });

    testWidgets(
        'covered then uncovered: the old success is discarded and the user '
        're-verifies; the own route then completes exactly once',
        (WidgetTester tester) async {
      final _GatedDb db = _GatedDb();
      final AppContainer c = AppContainer.inMemory(database: db);
      await c.auth.enrollPin(_pin);
      final _Stack stack = await _pumpStack(tester);
      await stack.pushScreen(tester, PinUnlockScreen(credentialManager: c.auth));

      db.arm();
      await _typePin(tester, _pin);
      final _Completion cover = _Completion();
      cover.track(stack.nav.push<bool>(MaterialPageRoute<bool>(
        builder: (_) => const Scaffold(body: Center(child: Text('COVER'))),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await _releaseLateSuccess(tester, db);
      await tester.pumpAndSettle();
      stack.nav.pop(); // the cover leaves normally
      await tester.pumpAndSettle();

      expect(cover.result, isNull, reason: 'the cover closed normally');
      expect(stack.screen.done, isFalse,
          reason: 'the old success is never reused');
      expect(find.text(_interrupted), findsOneWidget);

      await _typePin(tester, _pin);
      await tester.pumpAndSettle();
      expect(stack.screen.result, true);
      expect(stack.under.done, isFalse);
      expect(find.text('UNDER'), findsOneWidget);
    });
  });

  // ===================================================================
  group('duplicate completion and rapid navigation', () {
    testWidgets(
        'duplicate submit: input while verifying starts no second attempt and '
        'the route completes once', (WidgetTester tester) async {
      final _GatedDb db = _GatedDb();
      final AppContainer c = AppContainer.inMemory(database: db);
      await c.auth.enrollPin(_pin);
      final _Stack stack = await _pumpStack(tester);
      await stack.pushScreen(tester, PinUnlockScreen(credentialManager: c.auth));

      db.arm();
      await _typePin(tester, _pin);
      await _typePin(tester, _pin); // pad is disabled while verifying
      await tester.pump();
      expect(db.held, 1);
      db.release();
      await tester.pumpAndSettle();

      expect(stack.screen.result, true);
      expect(stack.under.done, isFalse);
      expect(find.text('UNDER'), findsOneWidget);
    });

    testWidgets(
        'rapid reopen: a newer screen is never completed by the older '
        'cancelled screen and still succeeds on its own',
        (WidgetTester tester) async {
      final _GatedDb db = _GatedDb();
      final AppContainer c = AppContainer.inMemory(database: db);
      await c.auth.enrollPin(_pin);
      final _Stack stack = await _pumpStack(tester);
      await stack.pushScreen(tester, PinUnlockScreen(credentialManager: c.auth));

      db.arm();
      await _typePin(tester, _pin);
      await _systemBack(tester);
      final _Completion second = _Completion();
      second.track(stack.nav.push<bool>(MaterialPageRoute<bool>(
        builder: (_) => PinUnlockScreen(credentialManager: c.auth),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await _releaseLateSuccess(tester, db);

      expect(second.done, isFalse);
      await tester.pumpAndSettle();
      expect(second.done, isFalse);

      await _typePin(tester, _pin);
      await tester.pumpAndSettle();
      expect(second.result, true);
      expect(stack.screen.result, false);
      expect(stack.under.done, isFalse);
    });
  });

  // ===================================================================
  group('legitimate success', () {
    testWidgets('PIN pops only its own route with true',
        (WidgetTester tester) async {
      final AppContainer c = AppContainer.inMemory();
      await c.auth.enrollPin(_pin);
      final _Stack stack = await _pumpStack(tester);
      await stack.pushScreen(tester, PinUnlockScreen(credentialManager: c.auth));

      await _typePin(tester, _pin);
      await tester.pumpAndSettle();

      expect(stack.screen.result, true);
      expect(stack.under.done, isFalse);
      expect(find.text('UNDER'), findsOneWidget);
    });

    testWidgets('pattern pops only its own route with true',
        (WidgetTester tester) async {
      final AppContainer c = AppContainer.inMemory();
      await c.auth.enrollPattern(_pattern);
      final _Stack stack = await _pumpStack(tester);
      await stack.pushScreen(
          tester, PatternUnlockScreen(credentialManager: c.auth));

      await _drawPattern(tester, _pattern);
      await tester.pumpAndSettle();

      expect(stack.screen.result, true);
      expect(stack.under.done, isFalse);
    });

    testWidgets('biometric pops only its own route with true',
        (WidgetTester tester) async {
      final AppContainer c =
          AppContainer.inMemory(biometrics: const _PassingBiometrics());
      await c.auth.enrollPin(_pin);
      await c.auth.updateBiometricOptions(const BiometricOptions());
      final _Stack stack = await _pumpStack(tester);
      await stack.pushScreen(tester, PinUnlockScreen(credentialManager: c.auth));

      await tester.tap(find.byKey(const Key('pin_key_biometric')));
      await tester.pumpAndSettle();

      expect(stack.screen.result, true);
      expect(stack.under.done, isFalse);
    });

    testWidgets('a wrong PIN still counts and does not complete the route',
        (WidgetTester tester) async {
      final AppContainer c = AppContainer.inMemory();
      await c.auth.enrollPin(_pin);
      final _Stack stack = await _pumpStack(tester);
      await stack.pushScreen(tester, PinUnlockScreen(credentialManager: c.auth));

      await _typePin(tester, '9999');
      await tester.pumpAndSettle();

      expect(stack.screen.done, isFalse);
      expect(find.textContaining(PinUnlockScreen.wrongPinPrefix),
          findsOneWidget);
      expect((await c.auth.status()).valueOrNull!.failedAttempts, 1);
    });
  });

  // ===================================================================
  group('CR-2, CR-3 and H-3 F4 verification flows stay fail-closed', () {
    testWidgets(
        'CR-3 change PIN: Back during verification writes nothing, issues no '
        'usable grant and keeps the root', (WidgetTester tester) async {
      final _GatedDb db = _GatedDb();
      final AppContainer c = AppContainer.inMemory(database: db);
      await c.auth.enrollPin(_pin);
      final _Stack stack = await _pumpStack(tester, under: false);
      await stack.pushScreen(tester, PinChangeScreen(credentialManager: c.auth));
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      db.arm();
      await _typePin(tester, _pin);
      await _systemBack(tester);
      await _releaseLateSuccess(tester, db);
      await tester.pumpAndSettle();

      expect(stack.screen.result, false);
      expect(find.text('ROOT'), findsOneWidget);
      expect((await c.auth.enrollPin('9999')).isFailure, isTrue,
          reason: 'CR-3 write gate: no grant, no write');
      expect((await c.auth.authenticatePin(_pin)).valueOrNull,
          isA<AuthSuccess>());
    });

    testWidgets('H-3 F4 verification: Back race stays denied; root kept',
        (WidgetTester tester) async {
      final _GatedDb db = _GatedDb();
      final AppContainer c = AppContainer.inMemory(database: db);
      await c.auth.enrollPin(_pin);
      final _Stack stack = await _pumpStack(tester, under: false);
      AppCredentialVerificationResult? result;
      unawaited(verifyPrimaryAppCredential(stack.nav, c.auth)
          .then((AppCredentialVerificationResult r) => result = r));
      await tester.pumpAndSettle();

      db.arm();
      await _typePin(tester, _pin);
      await _systemBack(tester);
      await _releaseLateSuccess(tester, db);
      await tester.pumpAndSettle();

      expect(result?.outcome, AppCredentialVerificationOutcome.denied);
      expect(find.text('ROOT'), findsOneWidget);
    });

    testWidgets('CR-2 unprotect: Back race stays unauthorized; root kept',
        (WidgetTester tester) async {
      final _GatedDb db = _GatedDb();
      final AppContainer c = AppContainer.inMemory(database: db);
      await c.auth.enrollPin(_pin);
      final _Stack stack = await _pumpStack(tester, under: false);
      UnprotectRequestResult? result;
      unawaited(requestUnprotectAuthorization(
        navigator: stack.nav,
        credentials: c.auth,
        packages: <String>{_protected},
      ).then((UnprotectRequestResult r) => result = r));
      await tester.pumpAndSettle();

      db.arm();
      await _typePin(tester, _pin);
      await _systemBack(tester);
      await _releaseLateSuccess(tester, db);
      await tester.pumpAndSettle();

      expect(result?.isAuthorized, isFalse);
      expect(find.text('ROOT'), findsOneWidget);
    });
  });

  // ===================================================================
  group('protected-app lock challenge (native exact-ticket contract bound)',
      () {
    late StaticNativeChallengeContract native;

    Future<AppContainer> launch(WidgetTester tester, _GatedDb db) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final AppContainer c = AppContainer.inMemory(database: db);
      native = StaticNativeChallengeContract.bind(
        overlay: c.overlay as StaticOverlayLockService,
        watcher: c.watcher as StaticWatcherService,
      );
      await tester.pumpWidget(SmartAppLockApp(container: c));
      await tester.pumpAndSettle();
      return c;
    }

    Future<void> protect(AppContainer c) async {
      await c.protectedApps.add(ProtectedApp(
        packageName: _protected,
        label: _protected,
        addedAt: DateTime(2026, 8, 21),
      ));
      await c.protectionBootstrap.synchronize();
    }

    void openProtectedApp(AppContainer c) =>
        (c.accessibility as StaticAccessibilityLockService)
            .emitForegroundPackage(_protected);

    Object? session(AppContainer c) =>
        (c.accessController as DefaultAccessController).sessionFor(_protected);

    void expectNotAuthorized(AppContainer c) {
      expect(native.authorizedPackages, isEmpty);
      expect((c.watcher as StaticWatcherService).authorizePackageCalls, 0);
      expect(session(c), isNull);
      expect((c.overlay as StaticOverlayLockService).hideLockChallengeCalls, 0);
      expect(
        (c.installedAppsService as StaticInstalledAppsService).launchAppCalls,
        0,
      );
    }

    testWidgets(
        'PIN: a newer challenge cannot be authorized by an older cancelled '
        'challenge; its own PIN then authorizes the exact current ticket once',
        (WidgetTester tester) async {
      final _GatedDb db = _GatedDb();
      final AppContainer c = await launch(tester, db);
      await c.auth.enrollPin(_pin);
      await protect(c);
      openProtectedApp(c);
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      final int firstGeneration = native.pending!.generation;

      db.arm();
      await _typePin(tester, _pin);
      await tester.binding.handlePopRoute(); // Back on the first challenge
      await _frames(tester, 4); // re-presented while the first still exits
      expect(find.byType(PinUnlockScreen), findsNWidgets(2));
      final int currentGeneration = native.pending!.generation;

      db.release(); // late success of the cancelled challenge
      await _frames(tester, 3);
      await tester.pumpAndSettle();

      expectNotAuthorized(c);
      expect(find.byType(PinUnlockScreen), findsOneWidget,
          reason: 'the newer challenge stays until its own success');
      expect(native.pending?.generation, currentGeneration);

      // Legitimate success on the newer challenge: exact ticket, once.
      await _typePin(tester, _pin);
      await tester.pumpAndSettle();
      expect(native.authorizeRejections, 0);
      expect(native.authorizedPackages, <String>{_protected});
      expect((c.watcher as StaticWatcherService).authorizePackageCalls, 1);
      expect(native.pending, isNull, reason: 'the exact ticket was consumed');
      expect(session(c), isNotNull);
      expect(
        (c.installedAppsService as StaticInstalledAppsService).launchedPackages,
        <String>[_protected],
      );
      // Native semantics (ProtectionStateStore.ensurePendingChallenge): the
      // re-presented challenge for the same package keeps the SAME unresolved
      // ticket. Native cannot distinguish the cancelled challenge from the
      // newer one, so the route binding in the unlock screen is what prevents
      // the stale success from authorizing it.
      expect(currentGeneration, firstGeneration);
    });

    testWidgets(
        'pattern: a newer challenge cannot be authorized by an older '
        'cancelled challenge', (WidgetTester tester) async {
      final _GatedDb db = _GatedDb();
      final AppContainer c = await launch(tester, db);
      await c.auth.enrollPattern(_pattern);
      await protect(c);
      openProtectedApp(c);
      await tester.pumpAndSettle();
      expect(find.byType(PatternUnlockScreen), findsOneWidget);

      db.arm();
      await _drawPattern(tester, _pattern);
      await tester.binding.handlePopRoute();
      await _frames(tester, 4);
      expect(find.byType(PatternUnlockScreen), findsNWidgets(2));
      db.release();
      await _frames(tester, 3);
      await tester.pumpAndSettle();

      expectNotAuthorized(c);
      expect(find.byType(PatternUnlockScreen), findsOneWidget);
    });

    testWidgets(
        'settings PIN verification (CR-2 confirm) cannot authorize a covering '
        'protected-app challenge', (WidgetTester tester) async {
      final _GatedDb db = _GatedDb();
      final AppContainer c = await launch(tester, db);
      await c.auth.enrollPin(_pin);
      await protect(c);
      final NavigatorState nav =
          tester.state<NavigatorState>(find.byType(Navigator).first);
      UnprotectRequestResult? result;
      unawaited(requestUnprotectAuthorization(
        navigator: nav,
        credentials: c.auth,
        packages: <String>{'com.example.other'},
      ).then((UnprotectRequestResult r) => result = r));
      await tester.pumpAndSettle();
      expect(find.text(unprotectConfirmTitle), findsOneWidget);

      db.arm();
      await _typePin(tester, _pin); // settings confirmation, persist pending
      openProtectedApp(c); // the lock challenge is pushed on top
      await _frames(tester, 4);
      expect(find.byType(PinUnlockScreen), findsNWidgets(2));
      db.release();
      await _frames(tester, 30);

      expectNotAuthorized(c);
      expect(result, isNull, reason: 'the CR-2 request is still unresolved');

      // The challenge is resolved by ITS OWN PIN (exact ticket, once); the
      // settings screen then requires re-verification.
      await _typePin(tester, _pin);
      await tester.pumpAndSettle();
      expect(native.authorizedPackages, <String>{_protected});
      expect((c.watcher as StaticWatcherService).authorizePackageCalls, 1);
      expect(find.text(unprotectConfirmTitle), findsOneWidget);
      expect(find.text(_interrupted), findsOneWidget);
      expect(result, isNull);
    });

    testWidgets(
        'H-3 F4 verification cannot authorize a covering protected-app '
        'challenge', (WidgetTester tester) async {
      final _GatedDb db = _GatedDb();
      final AppContainer c = await launch(tester, db);
      await c.auth.enrollPin(_pin);
      await protect(c);
      final NavigatorState nav =
          tester.state<NavigatorState>(find.byType(Navigator).first);
      AppCredentialVerificationResult? result;
      unawaited(verifyPrimaryAppCredential(nav, c.auth)
          .then((AppCredentialVerificationResult r) => result = r));
      await tester.pumpAndSettle();

      db.arm();
      await _typePin(tester, _pin);
      openProtectedApp(c);
      await _frames(tester, 4);
      db.release();
      await _frames(tester, 30);

      expectNotAuthorized(c);
      expect(result, isNull);
    });
  });
}
