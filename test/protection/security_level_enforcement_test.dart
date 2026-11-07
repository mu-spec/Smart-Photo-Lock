// Phase 8 / M2 — security level enforcement (PRD 8C Standard, 8D Sensitive,
// 8E Critical) on the Dart side, the policy transport and the simulated
// native resolution.
//
// SIMULATED: production SecurityLevelPolicy, DefaultAccessController,
// ProtectedAppMatcher, repository, ProtectionBootstrap and
// MethodChannelWatcherService (mocked channel). Native is simulated by
// StaticWatcherService (mirrors PolicySnapshotResolver.kt) and the real
// Kotlin engine is covered by SecurityLevelEnforcementTest.kt (JVM). No
// device evidence.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/protected_apps_repository.dart';
import 'package:smart_app_lock/protection/access_controller.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/protection/lock_session.dart';
import 'package:smart_app_lock/protection/protected_app_matcher.dart';
import 'package:smart_app_lock/protection/protection_bootstrap.dart';
import 'package:smart_app_lock/protection/security_level_policy.dart';
import 'package:smart_app_lock/services/impl/method_channel_watcher_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/pending_lock_challenge.dart';
import 'package:smart_app_lock/services/watcher_service.dart';
import 'package:smart_app_lock/utilities/result.dart';

const String _app = 'com.example.app';
const String _other = 'com.example.other';
const Duration _grace = Duration(seconds: 30);

typedef _Level = AppSecurityLevel;

/// In-memory container with a controllable access clock.
class _Fx {
  _Fx._(this.c, this.clock);

  final AppContainer c;
  final _Clock clock;

  DefaultAccessController get access =>
      c.accessController as DefaultAccessController;
  StaticWatcherService get watcher => c.watcher as StaticWatcherService;

  static Future<_Fx> create(
    Map<String, AppSecurityLevel> levels, {
    Duration grace = _grace,
  }) async {
    final _Clock clock = _Clock();
    final AppContainer c = AppContainer.inMemory(accessClock: clock.call);
    await c.auth.enrollPin('1234');
    for (final MapEntry<String, AppSecurityLevel> e in levels.entries) {
      await c.protectedApps.add(
        ProtectedApp(
          packageName: e.key,
          label: e.key,
          addedAt: DateTime(2026, 11, 2),
        ),
      );
      await c.protectedApps.setSecurityLevel(e.key, e.value);
    }
    c.accessController.setGracePeriod(grace);
    return _Fx._(c, clock);
  }

  /// Unlock [pkg], then leave it (the lock trigger's revoke on departure).
  Future<void> unlockThenLeave(String pkg) async {
    await access.grantAccess(pkg);
    clock.advance(const Duration(seconds: 1));
    await access.revokeAccess(pkg);
  }
}

class _Clock {
  DateTime now = DateTime(2026, 11, 2, 10);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

class _FailingRepository implements ProtectedAppsRepository {
  @override
  Future<Result<List<ProtectedApp>>> getProtectedApps() async =>
      Result.failure(StateError('database unavailable'));
  @override
  Future<Result<void>> add(ProtectedApp app) async =>
      Result.failure(StateError('database unavailable'));
  @override
  Future<Result<void>> setSecurityLevel(String p, AppSecurityLevel l) async =>
      Result.failure(StateError('database unavailable'));
  @override
  Future<Result<void>> remove(String packageName) async =>
      Result.failure(StateError('database unavailable'));
  @override
  Future<Result<bool>> isProtected(String packageName) async =>
      Result.failure(StateError('database unavailable'));
  @override
  Future<Result<int>> count() async =>
      Result.failure(StateError('database unavailable'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SecurityLevelPolicy (production, pure)', () {
    test('grace per level never exceeds the configured grace', () {
      for (final Duration g in <Duration>[
        Duration.zero,
        const Duration(seconds: 5),
        const Duration(seconds: 15),
        const Duration(seconds: 30),
        const Duration(minutes: 5),
      ]) {
        expect(SecurityLevelPolicy.graceFor(_Level.standard, g), g);
        expect(
          SecurityLevelPolicy.graceFor(_Level.sensitive, g),
          g < const Duration(seconds: 15) ? g : const Duration(seconds: 15),
        );
        expect(SecurityLevelPolicy.graceFor(_Level.critical, g), Duration.zero);
        for (final AppSecurityLevel l in AppSecurityLevel.values) {
          expect(SecurityLevelPolicy.graceFor(l, g) <= g, isTrue);
        }
      }
      expect(
        SecurityLevelPolicy.graceFor(
          _Level.standard,
          const Duration(seconds: -3),
        ),
        Duration.zero,
      );
    });

    test('window: Standard unchanged; Sensitive/Critical capped at 1 min', () {
      const Duration two = Duration(minutes: 2);
      expect(SecurityLevelPolicy.sessionWindowFor(_Level.standard, two), two);
      expect(
        SecurityLevelPolicy.sessionWindowFor(
            _Level.standard, const Duration(minutes: 10)),
        const Duration(minutes: 10),
      );
      for (final AppSecurityLevel l in <AppSecurityLevel>[
        _Level.sensitive,
        _Level.critical,
      ]) {
        expect(SecurityLevelPolicy.sessionWindowFor(l, two),
            const Duration(minutes: 1));
        expect(
          SecurityLevelPolicy.sessionWindowFor(l, const Duration(seconds: 20)),
          const Duration(seconds: 20),
        );
      }
      expect(SecurityLevelPolicy.stricter(_Level.standard, _Level.critical),
          _Level.critical);
      expect(SecurityLevelPolicy.stricter(_Level.sensitive, _Level.standard),
          _Level.sensitive);
    });
  });

  group('Level-aware access controller (SIMULATED clock)', () {
    test('1. Standard is unchanged: configured grace and 2-minute window',
        () async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _app: _Level.standard,
      });
      // R-A: the start-up rule load (until then every protected app is
      // Critical; see smart_rules_startup_floor_m2_test.dart).
      await fx.c.protectionBootstrap.synchronize();
      final LockSession s = (await fx.access.grantAccess(_app)).valueOrNull!;
      expect(s.window, LockSession.defaultWindow);
      fx.clock.advance(const Duration(seconds: 1));
      await fx.access.revokeAccess(_app);
      fx.clock.advance(const Duration(seconds: 29));
      expect(await fx.access.evaluate(_app), AccessDecision.allow);
      await fx.access.revokeAccess(_app);
      fx.clock.advance(const Duration(seconds: 31));
      expect(await fx.access.evaluate(_app), AccessDecision.challenge);
    });

    test('2. Sensitive: grace capped at 15 s and a 1-minute window', () async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _app: _Level.sensitive,
      });
      // R-A: the start-up rule load (until then every protected app is
      // Critical; see smart_rules_startup_floor_m2_test.dart).
      await fx.c.protectionBootstrap.synchronize();
      final LockSession s = (await fx.access.grantAccess(_app)).valueOrNull!;
      expect(s.window, const Duration(minutes: 1));
      fx.clock.advance(const Duration(seconds: 1));
      await fx.access.revokeAccess(_app);
      fx.clock.advance(const Duration(seconds: 14));
      expect(await fx.access.evaluate(_app), AccessDecision.allow);
      await fx.access.revokeAccess(_app);
      fx.clock.advance(const Duration(seconds: 16));
      expect(await fx.access.evaluate(_app), AccessDecision.challenge,
          reason: 'Standard would still allow at 16 s of a 30 s grace');
    });

    test('2b. Sensitive never gets MORE grace than configured', () async {
      final _Fx fx = await _Fx.create(
        <String, AppSecurityLevel>{_app: _Level.sensitive},
        grace: const Duration(seconds: 5),
      );
      await fx.unlockThenLeave(_app);
      fx.clock.advance(const Duration(seconds: 6));
      expect(await fx.access.evaluate(_app), AccessDecision.challenge);
    });

    test('3. Critical: any re-entry after leaving re-challenges', () async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _app: _Level.critical,
      });
      await fx.unlockThenLeave(_app);
      fx.clock.advance(const Duration(milliseconds: 1));
      expect(await fx.access.evaluate(_app), AccessDecision.challenge);
      expect(fx.access.sessionFor(_app), isNull);
    });

    test(
        '4. Critical: the current authenticated interaction stays usable '
        '(no challenge loop) until it is left or idles 1 minute', () async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _app: _Level.critical,
      });
      await fx.access.grantAccess(_app);
      for (int i = 0; i < 5; i++) {
        fx.clock.advance(const Duration(seconds: 50));
        expect(await fx.access.evaluate(_app), AccessDecision.allow);
      }
      fx.clock.advance(const Duration(seconds: 61));
      expect(await fx.access.evaluate(_app), AccessDecision.challenge);
    });

    test(
        '5/6. Home, task switch and screen off: leaving through any path '
        '(revoke, blind-start revokeAllExcept, screen-off revokeAll) '
        're-challenges Critical; Standard keeps its grace on leave', () async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _app: _Level.critical,
        _other: _Level.standard,
      });
      // R-A: the start-up rule load (until then every protected app is
      // Critical; see smart_rules_startup_floor_m2_test.dart).
      await fx.c.protectionBootstrap.synchronize();
      await fx.access.grantAccess(_app);
      await fx.access.grantAccess(_other);
      await fx.access.revokeAllExcept('com.android.launcher'); // Home
      fx.clock.advance(const Duration(seconds: 2));
      expect(await fx.access.evaluate(_app), AccessDecision.challenge);
      expect(await fx.access.evaluate(_other), AccessDecision.allow);

      await fx.access.grantAccess(_app);
      await fx.access.revokeAllAccess(); // screen off
      expect(await fx.access.evaluate(_app), AccessDecision.challenge);
      expect(await fx.access.evaluate(_other), AccessDecision.challenge);
    });

    test(
        '7. grace expiry and stale state: an unreadable protection state '
        'challenges and a new unlock gets the strictest window', () async {
      final DefaultAccessController controller = DefaultAccessController(
        matcher: ProtectedAppMatcher(repository: _FailingRepository()),
        auth: AppContainer.inMemory().auth,
      );
      expect(await controller.evaluate(_app), AccessDecision.challenge);
      final LockSession s = (await controller.grantAccess(_app)).valueOrNull!;
      expect(s.window, SecurityLevelPolicy.strictSessionWindow);
      controller.setGracePeriod(_grace);
      await controller.revokeAccess(_app);
      expect(controller.sessionFor(_app), isNull, reason: 'no grace');
    });

    test(
        'the native floor wins: a Standard app that native still enforces '
        'as Critical gets no grace (downgrade not confirmed)', () async {
      final _Clock clock = _Clock();
      final AppContainer c = AppContainer.inMemory(accessClock: clock.call);
      await c.protectedApps.add(
        ProtectedApp(
          packageName: _app,
          label: _app,
          addedAt: DateTime(2026, 11, 2),
        ),
      );
      AppSecurityLevel? floor = _Level.critical;
      final DefaultAccessController controller = DefaultAccessController(
        matcher: c.protectedAppMatcher,
        auth: c.auth,
        now: clock.call,
        enforcedLevelFloor: (String p) => p == _app ? floor : null,
      )..setGracePeriod(_grace);
      await controller.grantAccess(_app);
      await controller.revokeAccess(_app);
      expect(await controller.evaluate(_app), AccessDecision.challenge);
      floor = null; // native confirmed Standard
      await controller.grantAccess(_app);
      await controller.revokeAccess(_app);
      clock.advance(const Duration(seconds: 20));
      expect(await controller.evaluate(_app), AccessDecision.allow);
    });

    test('revokeImmediately ends one package window and grace, nothing else',
        () async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _app: _Level.standard,
        _other: _Level.standard,
      });
      await fx.unlockThenLeave(_app); // grace armed
      await fx.access.grantAccess(_other);
      expect((await fx.access.revokeImmediately(_app)).isSuccess, isTrue);
      expect(await fx.access.evaluate(_app), AccessDecision.challenge);
      expect(await fx.access.evaluate(_other), AccessDecision.allow);
    });
  });

  group('Transport: snapshot and native acknowledgement', () {
    test('a snapshot carries version, levels, session, revision, downgrades',
        () {
      const ProtectionPolicySnapshot snapshot = ProtectionPolicySnapshot(
        levels: <String, AppSecurityLevel>{
          _app: _Level.critical,
          _other: _Level.standard,
        },
        session: 'abc',
        revision: 7,
        authorizedDowngrades: <String>{_other},
      );
      expect(snapshot.toChannelArguments(), <String, Object?>{
        'policyVersion': 1,
        'securityLevels': <String, String>{
          _app: 'critical',
          _other: 'standard',
        },
        'snapshotSession': 'abc',
        'snapshotRevision': 7,
        'authorizedDowngrades': <String>[_other],
      });
    });

    test('ack parsing: unreadable level → Critical; unreadable reply → unknown',
        () {
      final ProtectionPolicyAck ack =
          ProtectionPolicyAck.fromChannel(<String, Object?>{
        'applied': true,
        'policyStatus': 'applied',
        'effectiveLevels': <String, Object?>{_app: 'bogus', _other: 'standard'},
        'heldDowngrades': <Object?>[_app, 3],
      });
      expect(ack.status, ProtectionPolicyStatus.applied);
      expect(ack.effectiveLevels[_app], _Level.critical);
      expect(ack.effectiveLevels[_other], _Level.standard);
      expect(ack.heldDowngrades, <String>{_app});
      expect(ProtectionPolicyAck.fromChannel(true).status,
          ProtectionPolicyStatus.unknown);
      expect(
        ProtectionPolicyAck.fromChannel(<String, Object?>{'policyStatus': 'x'})
            .status,
        ProtectionPolicyStatus.unknown,
      );
    });

    group('MethodChannelWatcherService.configureProtection', () {
      const MethodChannel channel = MethodChannel('smart_app_lock/watcher');
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      tearDown(() => messenger.setMockMethodCallHandler(channel, null));

      Future<(Result<ProtectionPolicyAck>, Map<Object?, Object?>?)> call(
        Object? reply, {
        ProtectionPolicySnapshot? policy,
      }) async {
        Map<Object?, Object?>? args;
        messenger.setMockMethodCallHandler(channel, (MethodCall c) async {
          args = c.arguments as Map<Object?, Object?>?;
          return reply;
        });
        final Result<ProtectionPolicyAck> r =
            await MethodChannelWatcherService().configureProtection(
          enabled: true,
          protectedPackages: <String>{_app},
          policy: policy,
        );
        return (r, args);
      }

      test('applied reply → success with the native levels', () async {
        final (Result<ProtectionPolicyAck> r, Map<Object?, Object?>? args) =
            await call(
          <String, Object?>{
            'applied': true,
            'policyStatus': 'applied',
            'effectiveLevels': <String, Object?>{_app: 'critical'},
            'heldDowngrades': <Object?>[],
          },
          policy: const ProtectionPolicySnapshot(
            levels: <String, AppSecurityLevel>{_app: _Level.critical},
            session: 's',
            revision: 1,
          ),
        );
        expect(r.valueOrNull!.effectiveLevels, <String, AppSecurityLevel>{
          _app: _Level.critical,
        });
        expect(args!['policyVersion'], 1);
        expect(args['securityLevels'], <Object?, Object?>{_app: 'critical'});
      });

      test(
          'a legacy call sends no level keys; a pre-M2 `true` is accepted '
          'as unknown', () async {
        final (Result<ProtectionPolicyAck> r, Map<Object?, Object?>? args) =
            await call(true);
        expect(r.valueOrNull!.status, ProtectionPolicyStatus.unknown);
        expect(args!.containsKey('policyVersion'), isFalse);
        expect(args.containsKey('securityLevels'), isFalse);
      });

      test('11. stale, not-applied, false and null replies are failures',
          () async {
        for (final Object? reply in <Object?>[
          <String, Object?>{'applied': false, 'policyStatus': 'stale'},
          <String, Object?>{'applied': true, 'policyStatus': 'stale'},
          <String, Object?>{'applied': false, 'policyStatus': 'applied'},
          <String, Object?>{
            'applied': true,
            'persisted': false,
            'policyStatus': 'applied',
          },
          false,
          null,
        ]) {
          final (Result<ProtectionPolicyAck> r, _) = await call(reply);
          expect(r.isFailure, isTrue, reason: '$reply');
        }
      });
    });
  });

  group('Simulated native resolution (StaticWatcherService)', () {
    ProtectionPolicySnapshot snap(
      Map<String, AppSecurityLevel> levels,
      int revision, {
      Set<String> downgrades = const <String>{},
      String session = 's',
    }) =>
        ProtectionPolicySnapshot(
          levels: levels,
          session: session,
          revision: revision,
          authorizedDowngrades: downgrades,
        );

    test(
        '8/10. legacy (no level data) keeps known levels, new packages → '
        'Standard; a missing map is Standard, a malformed one is Critical',
        () async {
      final StaticWatcherService w = StaticWatcherService();
      ProtectionPolicyAck ack = (await w.configureProtection(
        enabled: true,
        protectedPackages: <String>{_app},
      ))
          .valueOrNull!;
      expect(ack.status, ProtectionPolicyStatus.legacy);
      expect(
          w.securityLevels, <String, AppSecurityLevel>{_app: _Level.standard});
      await w.configureProtection(
        enabled: true,
        protectedPackages: <String>{_app},
        policy: snap(<String, AppSecurityLevel>{_app: _Level.critical}, 1),
      );
      ack = (await w.configureProtection(
        enabled: true,
        protectedPackages: <String>{_app, _other},
      ))
          .valueOrNull!;
      expect(w.securityLevels, <String, AppSecurityLevel>{
        _app: _Level.critical,
        _other: _Level.standard,
      });
      // 9/10: keys that do not match the protected set → every app Critical.
      ack = (await w.configureProtection(
        enabled: true,
        protectedPackages: <String>{_app, _other},
        policy: snap(<String, AppSecurityLevel>{_app: _Level.standard}, 2),
      ))
          .valueOrNull!;
      expect(ack.status, ProtectionPolicyStatus.invalid);
      expect(ack.effectiveLevels.values.toSet(), <AppSecurityLevel>{
        _Level.critical,
      });
    });

    test('a lower level is held unless confirmed; a confirmed one applies',
        () async {
      final StaticWatcherService w = StaticWatcherService();
      await w.configureProtection(
        enabled: true,
        protectedPackages: <String>{_app},
        policy: snap(<String, AppSecurityLevel>{_app: _Level.critical}, 1),
      );
      ProtectionPolicyAck ack = (await w.configureProtection(
        enabled: true,
        protectedPackages: <String>{_app},
        policy: snap(<String, AppSecurityLevel>{_app: _Level.standard}, 2),
      ))
          .valueOrNull!;
      expect(ack.effectiveLevels[_app], _Level.critical);
      expect(ack.heldDowngrades, <String>{_app});
      ack = (await w.configureProtection(
        enabled: true,
        protectedPackages: <String>{_app},
        policy: snap(
          <String, AppSecurityLevel>{_app: _Level.standard},
          3,
          downgrades: <String>{_app},
        ),
      ))
          .valueOrNull!;
      expect(ack.effectiveLevels[_app], _Level.standard);
      expect(ack.heldDowngrades, isEmpty);
    });

    test('11. a stale or out-of-order snapshot changes nothing', () async {
      final StaticWatcherService w = StaticWatcherService();
      await w.configureProtection(
        enabled: true,
        protectedPackages: <String>{_app},
        policy: snap(<String, AppSecurityLevel>{_app: _Level.critical}, 5),
      );
      for (final int rev in <int>[5, 4, 1]) {
        final Result<ProtectionPolicyAck> r = await w.configureProtection(
          enabled: true,
          protectedPackages: <String>{_app},
          policy: snap(
            <String, AppSecurityLevel>{_app: _Level.standard},
            rev,
            downgrades: <String>{_app},
          ),
        );
        expect(r.isFailure, isTrue);
        expect(w.securityLevels[_app], _Level.critical);
      }
    });

    test(
        '12/13. configure never clears a ticket or grants; an upgrade '
        'revokes that package authorization only', () async {
      final StaticWatcherService w = StaticWatcherService()
        ..pendingChallenge = _other
        ..pendingChallengeGeneration = 4;
      await w.configureProtection(
        enabled: true,
        protectedPackages: <String>{_app, _other},
        policy: snap(<String, AppSecurityLevel>{
          _app: _Level.standard,
          _other: _Level.standard,
        }, 1),
      );
      w.authorizedPackages.addAll(<String>{_app, _other});
      await w.configureProtection(
        enabled: true,
        protectedPackages: <String>{_app, _other},
        policy: snap(<String, AppSecurityLevel>{
          _app: _Level.critical,
          _other: _Level.standard,
        }, 2),
      );
      expect(w.authorizedPackages, <String>{_other});
      expect(w.pendingChallenge, _other);
      expect(w.pendingChallengeGeneration, 4);
      expect(w.authorizePackageCalls, 0);
    });
  });

  group('ProtectionBootstrap snapshots (SIMULATED native)', () {
    test(
        'one snapshot per sync: same session, increasing revision, levels '
        'of exactly the protected set; the ack feeds nativeLevelFor', () async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _app: _Level.critical,
        _other: _Level.sensitive,
      });
      await fx.c.protectionBootstrap.synchronize();
      await fx.c.protectionBootstrap.synchronize(
        authorizedDowngrades: <String>{_app, 'com.not.protected'},
      );
      final List<ProtectionPolicySnapshot?> sent = fx.watcher.receivedPolicies;
      final ProtectionPolicySnapshot a = sent[sent.length - 2]!;
      final ProtectionPolicySnapshot b = sent.last!;
      expect(b.session, a.session);
      expect(b.revision, a.revision + 1);
      expect(b.levels, <String, AppSecurityLevel>{
        _app: _Level.critical,
        _other: _Level.sensitive,
      });
      expect(b.authorizedDowngrades, <String>{_app});
      expect(fx.watcher.protectedPackages, b.levels.keys.toSet());
      expect(fx.c.protectionBootstrap.nativeLevelFor(_app), _Level.critical);
    });

    test('syncs are serialized: a second waits for the first', () async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _app: _Level.standard,
      });
      final int before = fx.watcher.configureCalls;
      fx.watcher.configureGate = Completer<void>();
      final Future<Object?> first = fx.c.protectionBootstrap.synchronize();
      final Future<Object?> second = fx.c.protectionBootstrap.synchronize();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(fx.watcher.configureCalls - before, 1);
      fx.watcher.configureGate!.complete();
      await Future.wait(<Future<Object?>>[first, second]);
      expect(fx.watcher.configureCalls - before, 2);
    });

    test(
        '17. a failed sync keeps the last confirmed native level (never '
        'reported weaker) and changes no native state', () async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _app: _Level.critical,
      });
      await fx.c.protectionBootstrap.synchronize();
      await fx.c.protectedApps.setSecurityLevel(_app, _Level.standard);
      fx.watcher.configureError = StateError('native write failed');
      final bool running = fx.watcher.running;
      expect((await fx.c.protectionBootstrap.synchronize()).isFailure, isTrue);
      expect(fx.c.protectionBootstrap.nativeLevelFor(_app), _Level.critical);
      expect(fx.watcher.securityLevels[_app], _Level.critical);
      expect(fx.watcher.running, running);
    });

    test(
        '18. restart: a new bootstrap (new session) re-sends the persisted '
        'levels; an unconfirmed downgrade stays held natively', () async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _app: _Level.critical,
      });
      await fx.c.protectionBootstrap.synchronize();
      await fx.c.protectedApps.setSecurityLevel(_app, _Level.standard);
      final ProtectionBootstrap restarted = ProtectionBootstrap(
        protectedApps: fx.c.protectedApps,
        credentials: fx.c.auth,
        watcher: fx.watcher,
      );
      expect(restarted.session, isNot(fx.c.protectionBootstrap.session));
      expect((await restarted.synchronize()).isSuccess, isTrue);
      expect(restarted.nativeLevelFor(_app), _Level.critical);
      expect(restarted.lastPolicyAck!.heldDowngrades, <String>{_app});
    });

    test(
        '12. a sync never grants, clears a ticket, changes grace or stops '
        'the watcher', () async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _app: _Level.critical,
        _other: _Level.standard,
      });
      await fx.c.protectionBootstrap.synchronize();
      fx.watcher
        ..pendingChallenge = _app
        ..pendingChallengeGeneration = 3;
      final int stops = fx.watcher.stopCalls;
      final Duration grace = fx.watcher.gracePeriod;
      await fx.c.protectedApps.setSecurityLevel(_other, _Level.critical);
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.watcher.pendingChallenge, _app);
      expect(fx.watcher.pendingChallengeGeneration, 3);
      expect(fx.watcher.authorizedPackages, isEmpty);
      expect(fx.watcher.authorizePackageCalls, 0);
      expect(fx.watcher.stopCalls, stops);
      expect(fx.watcher.running, isTrue);
      expect(fx.watcher.gracePeriod, grace);
      expect(fx.access.sessionFor(_app), isNull);
    });
  });

  group('Final native gate: the grant level is a native floor', () {
    test('grantAccess records the enforced level; refresh keeps it', () async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _app: _Level.critical,
        _other: _Level.standard,
      });
      // R-A: the start-up rule load (until then every protected app is
      // Critical; see smart_rules_startup_floor_m2_test.dart).
      await fx.c.protectionBootstrap.synchronize();
      final LockSession critical =
          (await fx.access.grantAccess(_app)).valueOrNull!;
      expect(critical.securityLevel, _Level.critical);
      expect(critical.refresh(fx.clock.now).securityLevel, _Level.critical);
      expect(
        (await fx.access.grantAccess(_other)).valueOrNull!.securityLevel,
        _Level.standard,
      );
    });

    test('an unreadable level store grants with a Critical floor', () async {
      final DefaultAccessController access = DefaultAccessController(
        matcher: ProtectedAppMatcher(repository: _FailingRepository()),
        auth: AppContainer.inMemory().auth,
      );
      expect(
        (await access.grantAccess(_app)).valueOrNull?.securityLevel,
        _Level.critical,
      );
    });

    group('MethodChannelWatcherService.authorizePackage', () {
      const MethodChannel channel = MethodChannel('smart_app_lock/watcher');
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      tearDown(() => messenger.setMockMethodCallHandler(channel, null));

      Future<Map<Object?, Object?>?> args(AppSecurityLevel? level) async {
        Map<Object?, Object?>? sent;
        messenger.setMockMethodCallHandler(channel, (MethodCall c) async {
          sent = c.arguments as Map<Object?, Object?>?;
          return true;
        });
        await MethodChannelWatcherService().authorizePackage(
          const PendingLockChallenge(packageName: _app, generation: 3),
          securityLevel: level,
        );
        return sent;
      }

      test('sends the exact level id; omits it when none is given', () async {
        expect((await args(_Level.critical))!['securityLevel'], 'critical');
        expect((await args(_Level.sensitive))!['securityLevel'], 'sensitive');
        expect((await args(_Level.standard))!['securityLevel'], 'standard');
        final Map<Object?, Object?> legacy = (await args(null))!;
        expect(legacy.containsKey('securityLevel'), isFalse);
        expect(legacy['packageName'], _app);
        expect(legacy['generation'], 3);
      });
    });
  });
}
