// Phase 8 / M3 (PRD 8G) — security level QA matrix on the Dart side.
//
// SIMULATED: production DefaultAccessController, ProtectedAppMatcher,
// SecurityLevelPolicy, repository (in-memory database) and ProtectionBootstrap
// over the simulated native watcher, with a controllable clock. The native
// engine has its own matrix in SecurityLevelQaMatrixTest.kt (JVM). No device
// evidence.

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/access_controller.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';

const String _app = 'com.example.app';
const String _systemUi = 'com.android.systemui';
const String _pin = '1234';
const Duration _grace = Duration(seconds: 30);

typedef _L = AppSecurityLevel;

/// Expected grace (configured 30 s) and window (requested 2 min) per level.
Duration _graceOf(AppSecurityLevel l) => switch (l) {
      _L.standard => const Duration(seconds: 30),
      _L.sensitive => const Duration(seconds: 15),
      _L.critical => Duration.zero,
    };

Duration _windowOf(AppSecurityLevel l) => switch (l) {
      _L.standard => const Duration(minutes: 2),
      _L.sensitive || _L.critical => const Duration(minutes: 1),
    };

class _Clock {
  DateTime now = DateTime(2026, 11, 3, 10);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

class _Fx {
  _Fx(this.c, this.clock, this.db, this.secrets);

  final AppContainer c;
  final _Clock clock;
  final InMemoryLocalDatabase db;
  final InMemorySecretStore secrets;

  AccessController get access => c.accessController;

  static Future<_Fx> create(
    AppSecurityLevel level, {
    InMemoryLocalDatabase? database,
    InMemorySecretStore? secretStore,
    bool enroll = true,
  }) async {
    final _Clock clock = _Clock();
    final InMemoryLocalDatabase db = database ?? InMemoryLocalDatabase();
    // A process restart keeps the Keystore-backed secret store too.
    final InMemorySecretStore secrets = secretStore ?? InMemorySecretStore();
    final AppContainer c = AppContainer.inMemory(
      accessClock: clock.call,
      database: db,
      secretStore: secrets,
    );
    if (enroll) await c.auth.enrollPin(_pin);
    if (database == null) {
      await c.protectedApps.add(
        ProtectedApp(
          packageName: _app,
          label: 'App',
          addedAt: DateTime(2026, 11, 3),
        ),
      );
      await c.protectedApps.setSecurityLevel(_app, level);
    }
    await c.protectionBootstrap.synchronize();
    c.accessController.setGracePeriod(_grace);
    return _Fx(c, clock, db, secrets);
  }

  Future<AccessDecision> leaveAndReturn(Duration away, {String? via}) async {
    await access.grantAccess(_app);
    clock.advance(const Duration(seconds: 1));
    if (via == null) {
      await access.revokeAccess(_app);
    } else {
      await access.revokeAllExcept(via);
    }
    clock.advance(away);
    return access.evaluate(_app);
  }
}

AccessDecision _expectAfterAway(AppSecurityLevel l, Duration away) =>
    away < _graceOf(l) ? AccessDecision.allow : AccessDecision.challenge;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final AppSecurityLevel l in AppSecurityLevel.values) {
    group('8G matrix: ${l.label}', () {
      test('initial access is challenged', () async {
        final _Fx fx = await _Fx.create(l);
        expect(await fx.access.evaluate(_app), AccessDecision.challenge);
      });

      test('same foreground interaction stays usable (no challenge loop)',
          () async {
        final _Fx fx = await _Fx.create(l);
        await fx.access.grantAccess(_app);
        for (int i = 0; i < 15; i++) {
          fx.clock.advance(const Duration(seconds: 20));
          expect(await fx.access.evaluate(_app), AccessDecision.allow,
              reason: 'observation ${i + 1} (every 20 s for 5 min)');
        }
      });

      for (final Duration away in const <Duration>[
        Duration(seconds: 1),
        Duration(seconds: 10),
        Duration(seconds: 20),
        Duration(seconds: 31),
      ]) {
        test('leave and return after ${away.inSeconds}s', () async {
          final _Fx fx = await _Fx.create(l);
          expect(await fx.leaveAndReturn(away), _expectAfterAway(l, away));
        });
      }

      test('Recents / System UI is a departure like any other', () async {
        final _Fx fx = await _Fx.create(l);
        expect(
          await fx.leaveAndReturn(const Duration(seconds: 1), via: _systemUi),
          _expectAfterAway(l, const Duration(seconds: 1)),
        );
      });

      test('screen off/on revokes every session and grace', () async {
        final _Fx fx = await _Fx.create(l);
        await fx.access.grantAccess(_app);
        await fx.access.revokeAccess(_app);
        await fx.access.revokeAllAccess();
        expect(await fx.access.evaluate(_app), AccessDecision.challenge);
      });

      test('inactivity window: inside allowed, at the end challenged',
          () async {
        final _Fx fx = await _Fx.create(l);
        await fx.access.grantAccess(_app);
        fx.clock.advance(_windowOf(l) - const Duration(milliseconds: 1));
        expect(await fx.access.evaluate(_app), AccessDecision.allow);
        final _Fx fx2 = await _Fx.create(l);
        await fx2.access.grantAccess(_app);
        fx2.clock.advance(_windowOf(l));
        expect(await fx2.access.evaluate(_app), AccessDecision.challenge);
      });

      test(
          'engine restart / process death: no session survives, the level '
          'does', () async {
        final _Fx fx = await _Fx.create(l);
        await fx.access.grantAccess(_app);
        final _Fx reborn = await _Fx.create(
          l,
          database: fx.db,
          secretStore: fx.secrets,
          enroll: false,
        );
        expect(await reborn.access.evaluate(_app), AccessDecision.challenge);
        expect(
          await reborn.leaveAndReturn(const Duration(seconds: 10)),
          _expectAfterAway(l, const Duration(seconds: 10)),
        );
      });

      test('a still-held stricter native level stays effective in Dart',
          () async {
        final _Fx fx = await _Fx.create(_L.critical);
        // Saved lower without a native confirmation (failed or no sync).
        await fx.c.protectedApps.setSecurityLevel(_app, l);
        expect(fx.c.protectionBootstrap.nativeLevelFor(_app), _L.critical);
        expect(
          await fx.leaveAndReturn(const Duration(seconds: 1)),
          AccessDecision.challenge,
        );
      });

      test('a lockout denies access at every level', () async {
        final _Fx fx = await _Fx.create(l);
        // The lockout uses the wall clock; align the access clock with it.
        fx.clock.now = DateTime.now();
        await fx.access.grantAccess(_app);
        for (int i = 0; i < 5; i++) {
          await fx.c.auth.authenticatePin('9999');
        }
        expect(await fx.access.evaluate(_app), AccessDecision.deny);
      });
    });
  }
}
