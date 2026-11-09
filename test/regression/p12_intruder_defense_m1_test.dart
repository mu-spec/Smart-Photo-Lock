// Phase 12 / Milestone 1 — Intruder Defense: end-to-end through the
// production AppContainer wiring and the real lock challenge host.
//
// Failed PIN / pattern verifications on a protected-app challenge become
// attributed failed-attempt events; nothing about lock behaviour changes:
// no grant on a wrong credential, the lockout cannot be bypassed, the
// cooldown progression is unchanged, profiles / rules / accessibility
// changes neither erase evidence nor fabricate failures, and a broken
// monitor cannot disable enforcement.
//
// SIMULATED: Flutter widget tests + Dart VM with in-memory platform fakes
// (StaticWatcherService, StaticAccessibilityLockService, in-memory SQLite
// stand-in and secret store). NOT device tests — no APK, no native shield,
// no biometric hardware.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/challenge_auth_recorder.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/impl/security_settings_repository_impl.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/profiles/security_profile.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/credentials/credential_state_machine.dart';
import 'package:smart_app_lock/security/credentials/impl/default_credential_manager.dart';
import 'package:smart_app_lock/security/credentials/verified_attempt.dart';
import 'package:smart_app_lock/security/intruder/failed_attempt_event.dart';
import 'package:smart_app_lock/security/intruder/intruder_failure_log_store.dart';
import 'package:smart_app_lock/security/intruder/intruder_monitor.dart';
import 'package:smart_app_lock/security/pin_hasher.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';

const String _app = 'com.whatsapp';

/// A database whose intruder-log row can neither be read nor written —
/// everything else (credentials, protected apps, rules, profiles) works.
class _BrokenIntruderDb extends InMemoryLocalDatabase {
  @override
  Future<String?> getSetting(String key) async {
    if (key.startsWith(IntruderFailureLogStore.storageKey)) {
      throw StateError('intruder storage fault');
    }
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) async {
    if (key.startsWith(IntruderFailureLogStore.storageKey)) {
      throw StateError('intruder storage fault');
    }
    return super.setSetting(key, value);
  }
}

/// PIN hasher whose verification waits on [gate] (when set), so a test can
/// close the challenge while a verification is still in flight.
class _GatedPinHasher implements PinHasher {
  final Pbkdf2PinHasher _inner = Pbkdf2PinHasher(iterations: 200);
  Completer<void>? gate;

  @override
  Future<PinHash> hash(String pin) => _inner.hash(pin);

  @override
  Future<bool> verify(String pin, PinHash stored) async {
    final Completer<void>? g = gate;
    if (g != null) {
      await g.future;
    }
    return _inner.verify(pin, stored);
  }
}

void main() {
  Future<AppContainer> pumpApp(
    WidgetTester tester, {
    AppContainer? container,
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final AppContainer c = container ?? AppContainer.inMemory();
    await tester.pumpWidget(SmartAppLockApp(container: c));
    await tester.pumpAndSettle();
    return c;
  }

  Future<void> protect(
    AppContainer c,
    String package, {
    AppSecurityLevel level = AppSecurityLevel.defaultLevel,
  }) async {
    await c.protectedApps.add(
      ProtectedApp(
        packageName: package,
        label: package,
        addedAt: DateTime(2026, 8, 21),
        securityLevel: level,
      ),
    );
    await c.protectionBootstrap.synchronize();
  }

  Future<void> openApp(WidgetTester tester, AppContainer c, String pkg) async {
    (c.accessibility as StaticAccessibilityLockService)
        .emitForegroundPackage(pkg);
    await tester.pumpAndSettle();
  }

  Future<void> typePin(WidgetTester tester, String pin) async {
    for (final String d in pin.split('')) {
      await tester.tap(find.byKey(Key('pin_key_$d')));
      await tester.pumpAndSettle();
    }
  }

  Future<void> drawPattern(WidgetTester tester, List<int> nodes) async {
    await tester.pump(const Duration(milliseconds: 450));
    final Rect bounds = tester.getRect(find.byType(DsPatternGrid));
    final double pad = bounds.width * 0.10;
    final double step = (bounds.width - 2 * pad) / 2;
    Offset center(int node) => Offset(
          bounds.left + pad + ((node - 1) % 3) * step,
          bounds.top + pad + ((node - 1) ~/ 3) * step,
        );
    final TestGesture g = await tester.startGesture(center(nodes.first));
    await tester.pump();
    await g.moveBy(const Offset(20, 0));
    await tester.pump();
    Offset current = center(nodes.first).translate(20, 0);
    for (final int node in nodes.skip(1)) {
      final Offset target = center(node);
      for (int s = 1; s <= 6; s++) {
        await g.moveTo(Offset.lerp(current, target, s / 6)!);
        await tester.pump();
      }
      current = target;
    }
    await g.up();
    await tester.pumpAndSettle();
  }

  Object? sessionFor(AppContainer c, String pkg) =>
      (c.accessController as DefaultAccessController).sessionFor(pkg);

  int launches(AppContainer c) =>
      (c.installedAppsService as StaticInstalledAppsService).launchAppCalls;

  Future<IntruderFailureLog> logOf(AppContainer c) async =>
      (await c.intruderMonitor.snapshot())!;

  group('protected-app challenge (real host, simulated platform)', () {
    testWidgets(
        'a wrong PIN creates ONE event attributed to the app, its native '
        'ticket generation and the challenge — and grants nothing',
        (WidgetTester tester) async {
      final AppContainer c = await pumpApp(tester);
      await c.auth.enrollPin('1234');
      await protect(c, _app);
      // The simulated native shield mints the ticket: next generation = 41.
      (c.overlay as StaticOverlayLockService).nextChallengeGeneration = 40;

      await openApp(tester, c, _app);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await typePin(tester, '9999');

      final IntruderFailureLog log = await logOf(c);
      final FailedAttemptEvent e = log.events.single;
      expect(e.method, FailedAttemptMethod.pin);
      expect(e.surface, AuthAttemptSurface.protectedAppChallenge);
      expect(e.packageName, _app);
      expect(e.generation, 41);
      expect(e.challengeSerial, greaterThan(0));
      expect(e.consecutiveFailures, 1);
      expect(log.consecutiveFailures, 1);

      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(sessionFor(c, _app), isNull);
      expect(launches(c), 0);
    });

    testWidgets(
        'a too-short pattern is rejected before verification (no count, no '
        'event); a full wrong pattern is recorded once',
        (WidgetTester tester) async {
      final AppContainer c = await pumpApp(tester);
      await c.auth.enrollPattern(const <int>[3, 6, 9, 8]);
      await protect(c, _app);
      await openApp(tester, c, _app);
      expect(find.byType(PatternUnlockScreen), findsOneWidget);

      await drawPattern(tester, const <int>[1, 2]);
      expect(find.text(PatternUnlockScreen.tooShortMessage), findsOneWidget);
      expect((await c.auth.status()).valueOrNull!.failedAttempts, 0);
      expect((await logOf(c)).events, isEmpty);

      await drawPattern(tester, const <int>[1, 2, 3, 5]);
      final FailedAttemptEvent e = (await logOf(c)).events.single;
      expect(e.method, FailedAttemptMethod.pattern);
      expect(e.packageName, _app);
      expect((await c.auth.status()).valueOrNull!.failedAttempts, 1);
      expect(sessionFor(c, _app), isNull);
    });

    testWidgets(
        'three wrong PINs trip the production cooldown once; attempts during '
        'the cooldown are neither counted nor recorded; the app stays '
        'blocked', (WidgetTester tester) async {
      final AppContainer c = await pumpApp(tester);
      await c.auth.enrollPin('1234');
      await protect(c, _app);
      await openApp(tester, c, _app);

      for (final String pin in <String>['1111', '2222', '3333']) {
        await typePin(tester, pin);
      }
      IntruderFailureLog log = await logOf(c);
      expect(log.events, hasLength(3));
      expect(log.events.last.lockoutTriggered, isTrue);
      expect(log.events.last.lockoutStreak, 1);
      expect(log.events.where((FailedAttemptEvent e) => e.lockoutTriggered),
          hasLength(1));

      // Even the CORRECT PIN is blocked during the cooldown — and an
      // attacker hammering the manager directly adds nothing.
      expect((await c.auth.authenticatePin('1234')).valueOrNull,
          isA<AuthLockedOut>());
      expect((await c.auth.authenticatePin('4444')).valueOrNull,
          isA<AuthLockedOut>());
      log = await logOf(c);
      expect(log.events, hasLength(3));
      expect((await c.auth.status()).valueOrNull!.lockoutStreak, 1);
      expect(sessionFor(c, _app), isNull);
      expect(launches(c), 0);
    });

    testWidgets(
        'the correct PIN after failures still grants exactly as before; the '
        'run resets and the evidence is kept', (WidgetTester tester) async {
      final AppContainer c = await pumpApp(tester);
      await c.auth.enrollPin('1234');
      await protect(c, _app);
      await openApp(tester, c, _app);

      await typePin(tester, '9999');
      await typePin(tester, '1234');

      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(sessionFor(c, _app), isNotNull);
      final IntruderFailureLog log = await logOf(c);
      expect(log.consecutiveFailures, 0);
      expect(log.events, hasLength(1));
    });

    testWidgets(
        'an accessibility disconnect after a failure neither grants access '
        'nor alters the evidence', (WidgetTester tester) async {
      final AppContainer c = await pumpApp(tester);
      await c.auth.enrollPin('1234');
      await protect(c, _app);
      await openApp(tester, c, _app);
      await typePin(tester, '9999');

      final StaticAccessibilityLockService a11y =
          c.accessibility as StaticAccessibilityLockService;
      a11y.enabled = false;
      await c.protectionBootstrap.synchronize();
      await tester.pumpAndSettle();
      a11y.enabled = true;
      await openApp(tester, c, _app);

      expect(sessionFor(c, _app), isNull);
      expect(launches(c), 0);
      expect((await logOf(c)).events, hasLength(1));
      expect((await c.auth.status()).valueOrNull!.failedAttempts, 1);
    });

    testWidgets(
        'a monitor whose storage is broken cannot disable enforcement: '
        'wrong PINs still lock out and never grant; the right PIN still '
        'unlocks', (WidgetTester tester) async {
      final AppContainer c = await pumpApp(
        tester,
        container: AppContainer.inMemory(database: _BrokenIntruderDb()),
      );
      await c.auth.enrollPin('1234');
      await protect(c, _app);
      await openApp(tester, c, _app);

      for (final String pin in <String>['1111', '2222', '3333']) {
        await typePin(tester, pin);
      }
      await c.intruderMonitor.idle();
      expect(
          c.intruderMonitor.status.health, IntruderMonitorHealth.storageError);
      expect(c.intruderMonitor.status.droppedEvents, 3);
      expect((await c.auth.status()).valueOrNull!.lockedOutUntil, isNotNull);
      expect((await c.auth.authenticatePin('1234')).valueOrNull,
          isA<AuthLockedOut>());
      expect(sessionFor(c, _app), isNull);
      expect(launches(c), 0);
    });
  });

  group('HB-1 recorder attribution (container-less)', () {
    late _GatedPinHasher hasher;
    late IntruderMonitor monitor;
    late DefaultCredentialManager manager;
    const AuthAttemptContext chatCtx = AuthAttemptContext.protectedAppChallenge(
      packageName: 'com.example.chat',
      generation: 5,
      challengeSerial: 9,
    );
    const AuthAttemptContext bankCtx = AuthAttemptContext.protectedAppChallenge(
      packageName: 'com.example.bank',
      generation: 6,
      challengeSerial: 10,
    );

    setUp(() async {
      hasher = _GatedPinHasher();
      monitor = IntruderMonitor(
        store: IntruderFailureLogStore(InMemoryLocalDatabase()),
      );
      manager = DefaultCredentialManager(
        settings: SecuritySettingsRepositoryImpl(InMemoryLocalDatabase()),
        pinHasher: hasher,
        stateMachine: CredentialStateMachine(maxFailedAttempts: 3),
        attemptObserver: monitor,
      );
      await manager.enrollPin('1234');
    });

    test(
        'a verification that finishes AFTER the challenge closed (screen '
        'off / route torn down) is recorded once, for its own challenge, and '
        'is never a grant', () async {
      final ChallengeAuthRecorder recorder = ChallengeAuthRecorder.forPinRoute(
        manager,
        attemptContext: chatCtx,
      );
      hasher.gate = Completer<void>();
      final Future<Object?> inFlight = recorder.authenticatePin('9999');
      await pumpEventQueue();
      expect(recorder.close(), isFalse); // screen-off closes the challenge
      hasher.gate!.complete();
      await inFlight;
      final FailedAttemptEvent e = (await monitor.snapshot())!.events.single;
      expect(e.packageName, 'com.example.chat');
      expect(e.generation, 5);
      expect(e.challengeSerial, 9);
      expect(recorder.close(), isFalse);
    });

    test('two overlapping challenges never mix attribution', () async {
      final ChallengeAuthRecorder chat =
          ChallengeAuthRecorder.forPinRoute(manager, attemptContext: chatCtx);
      final ChallengeAuthRecorder bank =
          ChallengeAuthRecorder.forPinRoute(manager, attemptContext: bankCtx);
      hasher.gate = Completer<void>();
      final Future<Object?> a = chat.authenticatePin('1111');
      final Future<Object?> b = bank.authenticatePin('2222');
      await pumpEventQueue();
      hasher.gate!.complete();
      await Future.wait(<Future<Object?>>[a, b]);
      final List<FailedAttemptEvent> events =
          (await monitor.snapshot())!.events;
      expect(events.map((FailedAttemptEvent e) => e.packageName),
          <String>['com.example.chat', 'com.example.bank']);
      expect(events.map((FailedAttemptEvent e) => e.consecutiveFailures),
          <int>[1, 2],
          reason: 'one global run across apps');
    });

    test(
        'a recorder without context, and every in-app surface, is '
        'attributed to Smart App Lock itself', () async {
      await ChallengeAuthRecorder.forPinRoute(manager).authenticatePin('1111');
      await manager.verifyPinForCredentialChange('2222'); // CR-3 surface
      final List<FailedAttemptEvent> events =
          (await monitor.snapshot())!.events;
      expect(events, hasLength(2));
      for (final FailedAttemptEvent e in events) {
        expect(e.surface, AuthAttemptSurface.smartAppLock);
        expect(e.packageName, isNull);
      }
    });

    test('a refused method on a challenge route is not a verification',
        () async {
      await ChallengeAuthRecorder.forPinRoute(manager, attemptContext: chatCtx)
          .authenticatePattern(const <int>[1, 2, 3, 4]);
      expect((await monitor.snapshot())!.events, isEmpty);
      expect((await manager.status()).valueOrNull!.failedAttempts, 0);
    });
  });

  group('lifecycle and independence (container level)', () {
    test(
        'evidence, the run and seq survive process recreation; ids from the '
        'new process never collide', () async {
      final InMemoryLocalDatabase db = InMemoryLocalDatabase();
      final InMemorySecretStore secrets = InMemorySecretStore();
      final AppContainer first =
          AppContainer.inMemory(database: db, secretStore: secrets);
      await first.auth.enrollPin('1234');
      await first.auth.authenticatePin('0000');
      await first.auth.authenticatePin('1111');
      await first.intruderMonitor.idle();

      final AppContainer second =
          AppContainer.inMemory(database: db, secretStore: secrets);
      await second.auth.authenticatePin('2222');
      final IntruderFailureLog log = await logOf(second);
      expect(log.events.map((FailedAttemptEvent e) => e.seq), <int>[0, 1, 2]);
      expect(log.events.last.consecutiveFailures, 3);
      expect(log.events.last.lockoutTriggered, isTrue);
      expect(
        log.events.first.verificationId.split(':').first,
        isNot(log.events.last.verificationId.split(':').first),
      );
    });

    test('switching the security profile keeps the evidence and counters',
        () async {
      final AppContainer c = AppContainer.inMemory();
      await c.auth.enrollPin('1234');
      await protect(c, _app);
      await c.auth.authenticatePin('0000');
      await c.auth.authenticatePin('1111');
      final IntruderFailureLog before = await logOf(c);

      final SecurityProfileSet current =
          (await c.securityProfiles.getProfiles()).valueOrNull!;
      expect(
        (await c.securityProfiles.saveProfiles(
          current.withActive('work'),
          expected: current,
        ))
            .isSuccess,
        isTrue,
      );
      await c.protectionBootstrap.synchronize();

      final IntruderFailureLog after = await logOf(c);
      expect(after.events.map((FailedAttemptEvent e) => e.seq),
          before.events.map((FailedAttemptEvent e) => e.seq));
      expect(after.consecutiveFailures, 2);
      expect((await c.auth.status()).valueOrNull!.failedAttempts, 2);
    });

    test('Smart Rule activity fabricates no failures and touches no counters',
        () async {
      final AppContainer c = AppContainer.inMemory();
      await c.auth.enrollPin('1234');
      await protect(c, _app);
      final SmartRule rule = SmartRule(
        id: 'p12m1-rule',
        name: 'Always critical',
        targetPackages: const <String>[_app],
        days: SmartRuleDays.everyDay,
        time: const SmartRuleTime.allDay(),
        action: SmartRuleAction.critical,
        enabled: true,
      );
      expect((await c.smartRules.saveRule(rule, mustBeNew: true)).isSuccess,
          isTrue);
      await c.protectionBootstrap.synchronize();
      expect(
          (await c.smartRules
                  .setRuleEnabled(rule.id, enabled: false, expected: rule))
              .isSuccess,
          isTrue);
      await c.protectionBootstrap.synchronize();

      final IntruderFailureLog log = await logOf(c);
      expect(log.events, isEmpty);
      expect(log.consecutiveFailures, 0);
      expect((await c.auth.status()).valueOrNull!.failedAttempts, 0);
    });

    test('critical protection is not reduced by failures or by the log',
        () async {
      final AppContainer c = AppContainer.inMemory();
      await c.auth.enrollPin('1234');
      await protect(c, _app, level: AppSecurityLevel.critical);
      final AppSecurityLevel? before =
          c.protectionBootstrap.nativeLevelFor(_app);
      for (final String pin in <String>['0000', '1111', '2222']) {
        await c.auth.authenticatePin(pin);
      }
      await c.intruderMonitor.idle();
      await c.protectionBootstrap.synchronize();
      expect(c.protectionBootstrap.nativeLevelFor(_app), before);
      expect(
        (await c.protectedApps.getProtectedApps())
            .valueOrNull!
            .singleWhere((ProtectedApp a) => a.packageName == _app)
            .securityLevel,
        AppSecurityLevel.critical,
      );
      expect(sessionFor(c, _app), isNull);
    });

    test('corrupting or deleting the log never resets an active lockout',
        () async {
      final InMemoryLocalDatabase db = InMemoryLocalDatabase();
      final AppContainer c = AppContainer.inMemory(database: db);
      await c.auth.enrollPin('1234');
      for (final String pin in <String>['0000', '1111', '2222']) {
        await c.auth.authenticatePin(pin);
      }
      await c.intruderMonitor.idle();
      await db.setSetting(IntruderFailureLogStore.storageKey, 'garbage');
      expect((await c.auth.authenticatePin('1234')).valueOrNull,
          isA<AuthLockedOut>());
      await db.removeSetting(IntruderFailureLogStore.storageKey);
      expect((await c.auth.authenticatePin('1234')).valueOrNull,
          isA<AuthLockedOut>());
    });

    test(
        'privacy: the attempted PIN, the PIN hash and the package never '
        'appear in the stored log (encrypted at rest)', () async {
      final InMemoryLocalDatabase db = InMemoryLocalDatabase();
      final AppContainer c = AppContainer.inMemory(database: db);
      await c.auth.enrollPin('2580');
      await AuthAttemptContext.protectedAppChallenge(
        packageName: _app,
        generation: 1,
        challengeSerial: 1,
      ).run(() => c.auth.authenticatePin('9137'));
      await c.intruderMonitor.idle();

      final String raw =
          (await db.getSetting(IntruderFailureLogStore.storageKey))!;
      expect(raw, startsWith('enc:v1:'));
      expect(raw, isNot(contains(_app)));
      final String plain =
          await c.settingsCipher.decryptString(raw.substring(7));
      final Map<String, dynamic> doc =
          jsonDecode(plain) as Map<String, dynamic>;
      expect(doc['v'], 1);
      expect(plain, isNot(contains('9137')));
      expect(plain, isNot(contains('2580')));
      final String settingsJson = jsonEncode(
        (await c.securitySettings.getSettings()).valueOrNull!.toJson(),
      );
      final Map<String, dynamic> pinHash = (jsonDecode(settingsJson)
          as Map<String, dynamic>)['pinHash'] as Map<String, dynamic>;
      for (final Object? v in pinHash.values) {
        if (v is String && v.length > 8) {
          expect(plain, isNot(contains(v)));
        }
      }
    });

    test(
        'the production cooldown progression is unchanged: 3 failures, then '
        '30s, 1m, 2m, 4m, 8m, 10m, 10m', () async {
      DateTime now = DateTime(2026, 10, 22, 8);
      final IntruderMonitor monitor = IntruderMonitor(
        store: IntruderFailureLogStore(InMemoryLocalDatabase()),
        now: () => now,
      );
      final DefaultCredentialManager m = DefaultCredentialManager(
        settings: SecuritySettingsRepositoryImpl(InMemoryLocalDatabase()),
        pinHasher: Pbkdf2PinHasher(iterations: 200),
        // Identical to AppContainer's production state machine.
        stateMachine: CredentialStateMachine(
          maxFailedAttempts: 3,
          lockoutDuration: const Duration(seconds: 30),
        ),
        now: () => now,
        attemptObserver: monitor,
      );
      await m.enrollPin('1234');
      final List<int> cooldowns = <int>[];
      for (int round = 0; round < 7; round++) {
        AuthAttemptResult r = const AuthSuccess(type: AuthType.pin);
        for (int i = 0; i < 3; i++) {
          r = (await m.authenticatePin('000$i')).valueOrNull!;
          expect(r is AuthLockedOut, i == 2);
        }
        final AuthLockedOut l = r as AuthLockedOut;
        cooldowns.add(l.retryAt.difference(now).inSeconds);
        now = l.retryAt.add(const Duration(seconds: 1));
      }
      expect(cooldowns, <int>[30, 60, 120, 240, 480, 600, 600]);
      final IntruderFailureLog log = (await monitor.snapshot())!;
      expect(log.events, hasLength(21));
      expect(log.consecutiveFailures, 21);
      expect(log.events.where((FailedAttemptEvent e) => e.lockoutTriggered),
          hasLength(7));
    });
  });
}
