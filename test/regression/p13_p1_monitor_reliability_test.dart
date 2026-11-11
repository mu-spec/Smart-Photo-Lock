// Phase 13 / P-1 regression — IntruderMonitor reliability against the REAL
// consumers: P1-T08 (real IntruderDefenseCoordinator, threshold 3), P1-T18
// (real AppContainer, 4 configurations) and P1-T19 (real SmartAppLockApp +
// LockChallengeHost with stalled monitor storage).
//
// This file deliberately uses ONLY the Phase 12 / M1 monitor API, so it can
// also be run against the baseline monitor (db568de) as a characterization
// run: on the baseline, the T08 cases show the premature trigger at the 3rd
// failure and the missed trigger at the real 3rd failure after the owner's
// success (R-P13M1-1 / R-P13M1-9). See Phase13/P1_IMPLEMENTATION_REPORT.md.
//
// SIMULATED: Flutter test VM, in-memory storage, static platform fakes. No
// device, APK, camera, alarm hardware or biometric hardware involved.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/credentials/credential_state.dart';
import 'package:smart_app_lock/security/credentials/verified_attempt.dart';
import 'package:smart_app_lock/security/encryption/settings_cipher_impl.dart';
import 'package:smart_app_lock/security/intruder/failed_attempt_event.dart';
import 'package:smart_app_lock/security/intruder/intruder_defense_coordinator.dart';
import 'package:smart_app_lock/security/intruder/intruder_defense_settings.dart';
import 'package:smart_app_lock/security/intruder/intruder_evidence_service.dart';
import 'package:smart_app_lock/security/intruder/intruder_evidence_store.dart';
import 'package:smart_app_lock/security/intruder/intruder_failure_log_store.dart';
import 'package:smart_app_lock/security/intruder/intruder_monitor.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_intruder_evidence_service.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';

import '../support/intruder_fixtures.dart';

const String _logKey = IntruderFailureLogStore.storageKey;
const String _app = 'com.whatsapp';

/// Intruder-log row faults: one-shot write failures and gated reads/writes.
class _LogFaultDb extends InMemoryLocalDatabase {
  /// Fails exactly this many upcoming log writes (one-shot faults).
  int failNextWrites = 0;
  Completer<void>? readGate;
  Completer<void>? writeGate;

  @override
  Future<String?> getSetting(String key) async {
    if (key == _logKey) {
      final Completer<void>? g = readGate;
      if (g != null) await g.future;
    }
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) async {
    if (key == _logKey) {
      final Completer<void>? g = writeGate;
      if (g != null) await g.future;
      if (failNextWrites > 0) {
        failNextWrites--;
        throw StateError('log write fault');
      }
    }
    return super.setSetting(key, value);
  }
}

int _vid = 0;

VerifiedAttempt _fail() => VerifiedAttempt(
      verificationId: 'p1r:${++_vid}',
      type: AuthType.pin,
      matched: false,
      result: const AuthFailure(
        reason: AuthFailureReason.wrongCredential,
        remainingAttempts: 2,
      ),
      counterPersisted: true,
      lockoutStreak: 0,
      // The coordinator acts on protected-app challenge failures only.
      context: const AuthAttemptContext.protectedAppChallenge(
        packageName: 'com.bank',
        generation: 4,
        challengeSerial: 2,
      ),
      at: DateTime(2026, 10, 22, 12),
    );

VerifiedAttempt _ok() => VerifiedAttempt(
      verificationId: 'p1r:${++_vid}',
      type: AuthType.pin,
      matched: true,
      result: const AuthSuccess(type: AuthType.pin),
      counterPersisted: true,
      lockoutStreak: 0,
      context: AuthAttemptContext.smartAppLock,
      at: DateTime(2026, 10, 22, 12),
    );

void main() {
  group('P1-T08 real IntruderDefenseCoordinator (threshold 3, alarm only)', () {
    late _LogFaultDb db;
    late GatedEvidenceService platform;
    late IntruderDefenseCoordinator coordinator;

    setUp(() async {
      db = _LogFaultDb();
      final AesGcmSettingsCipher cipher =
          AesGcmSettingsCipher(InMemorySecretStore());
      platform = GatedEvidenceService()
        ..permission = CameraPermissionState.granted;
      final IntruderDefenseSettingsStore settings =
          IntruderDefenseSettingsStore(db, cipher);
      coordinator = IntruderDefenseCoordinator(
        settings: settings,
        evidence: IntruderEvidenceStore(db, cipher),
        service: platform,
      );
      await settings.write(const IntruderDefenseSettings(
          evidenceEnabled: false, alarmEnabled: true, threshold: 3));
    });

    IntruderMonitor monitorWith({int maxPending = 64}) => IntruderMonitor(
          store: IntruderFailureLogStore(db),
          now: () => DateTime(2026, 10, 22, 12),
          maxPending: maxPending,
        )..listener = coordinator;

    Future<void> settle(IntruderMonitor m) async {
      await m.idle();
      await coordinator.idle();
    }

    /// Delivers one failure, waits, and returns the alarm-start count.
    Future<int> failAndCount(IntruderMonitor m) async {
      m.onVerifiedAttempt(_fail());
      await settle(m);
      return platform.alarmStarts;
    }

    test(
        '(a) F1, F2, owner success whose reset write fails, then F3..F5: no '
        'trigger at F3 (run 1); exactly one trigger at F5 (run 3)', () async {
      final IntruderMonitor m = monitorWith();
      expect(await failAndCount(m), 0);
      expect(await failAndCount(m), 0);
      db.failNextWrites = 1;
      m.onVerifiedAttempt(_ok());
      await settle(m);
      expect(await failAndCount(m), 0, reason: 'F3 after the owner: run 1');
      expect(await failAndCount(m), 0);
      expect(await failAndCount(m), 1, reason: 'F5 is the 3rd since owner');
      expect(coordinator.status.triggers, 1);
      final IntruderFailureLog log = (await m.snapshot())!;
      expect(
        log.events.map((FailedAttemptEvent e) => e.consecutiveFailures),
        <int>[1, 2, 1, 2, 3],
      );
      expect(m.status.droppedEvents, 0,
          reason: 'a failed reset is not a dropped failure record');
    });

    test(
        '(b) maxPending 2 occupied by snapshots when the owner succeeds: the '
        'reset is not lost; no trigger at F3; one trigger at F5', () async {
      await failAndCount(monitorWith()); // F1 persisted
      await failAndCount(monitorWith()); // F2 persisted (run 2)
      final IntruderMonitor m = monitorWith(maxPending: 2); // cold cache
      db.readGate = Completer<void>();
      final Future<IntruderFailureLog?> r1 = m.snapshot(); // running, held
      final Future<IntruderFailureLog?> r2 = m.snapshot();
      m.onVerifiedAttempt(_ok());
      final Completer<void> g = db.readGate!;
      db.readGate = null;
      g.complete();
      await r1;
      await r2;
      await settle(m);
      expect(await failAndCount(m), 0, reason: 'F3 after the owner: run 1');
      expect(await failAndCount(m), 0);
      expect(await failAndCount(m), 1);
      expect(coordinator.status.triggers, 1);
      expect(m.status.droppedEvents, 0);
    });

    test('control: without faults F, F, S, F, F, F triggers exactly once',
        () async {
      final IntruderMonitor m = monitorWith();
      await failAndCount(m);
      await failAndCount(m);
      m.onVerifiedAttempt(_ok());
      await settle(m);
      expect(await failAndCount(m), 0);
      expect(await failAndCount(m), 0);
      expect(await failAndCount(m), 1);
    });
  });

  group('P1-T18 real container: auth outcomes identical in 4 configurations',
      () {
    const String pin = '482916';

    String describe(AuthAttemptResult? r) => switch (r) {
          AuthSuccess() => 'success',
          AuthFailure(
            :final AuthFailureReason reason,
            :final int? remainingAttempts
          ) =>
            'failure:${reason.name}:$remainingAttempts',
          AuthLockedOut(:final int? attemptsMade) => 'locked:$attemptsMade',
          _ => 'other:${r.runtimeType}',
        };

    Future<List<String>> run({
      required bool stall,
      required bool reads,
    }) async {
      final _LogFaultDb db = _LogFaultDb();
      final AppContainer c = AppContainer.inMemory(
        intruderEvidence: StaticIntruderEvidenceService(),
        database: db,
      );
      await c.intruderStartup;
      await c.securityJournalStartup;
      await c.auth.enrollPin(pin);
      if (stall) {
        db.writeGate = Completer<void>();
      }
      final List<String> out = <String>[];
      final List<Future<Object?>> pending = <Future<Object?>>[];
      for (final String attempt in <String>[
        '000000',
        '000000',
        pin,
        '000000',
        '000000',
        '000000',
        pin,
      ]) {
        if (reads) {
          for (int i = 0; i < 20; i++) {
            pending.add(c.intruderMonitor.snapshot());
          }
          pending.add(c.securityTimeline.load());
        }
        out.add(describe((await c.auth.authenticatePin(attempt)).valueOrNull));
      }
      final CredentialState s = (await c.auth.status()).valueOrNull!;
      out.add('failed=${s.failedAttempts} streak=${s.lockoutStreak} '
          'locked=${s.lockedOutUntil != null}');
      final Completer<void>? g = db.writeGate;
      db.writeGate = null;
      g?.complete();
      await Future.wait(pending);
      await c.intruderMonitor.idle();
      final IntruderFailureLog log = (await c.intruderMonitor.snapshot())!;
      out.add(
          'runs=${log.events.map((FailedAttemptEvent e) => e.consecutiveFailures).toList()} '
          'run=${log.consecutiveFailures} '
          'dropped=${c.intruderMonitor.status.droppedEvents}');
      return out;
    }

    test(
        'wrong, wrong, correct, wrong x3 (lockout), correct (blocked): same '
        'decisions and same persisted runs — plain / stalled log / '
        'concurrent reads / both', () async {
      final List<String> plain = await run(stall: false, reads: false);
      expect(plain.first, startsWith('failure:'));
      expect(plain[2], 'success');
      expect(plain[5], startsWith('locked:'));
      expect(plain[6], startsWith('locked:'), reason: 'correct PIN blocked');
      expect(plain.last, 'runs=[1, 2, 1, 2, 3] run=3 dropped=0');
      expect(await run(stall: true, reads: false), plain);
      expect(await run(stall: false, reads: true), plain);
      expect(await run(stall: true, reads: true), plain);
    });
  });

  group('P1-T19 real host: stalled monitor storage never blocks the owner', () {
    Future<AppContainer> pumpApp(WidgetTester tester, AppContainer c) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(SmartAppLockApp(container: c));
      await tester.pumpAndSettle();
      return c;
    }

    Future<void> protect(AppContainer c) async {
      await c.protectedApps.add(
        ProtectedApp(
          packageName: _app,
          label: _app,
          addedAt: DateTime(2026, 8, 21),
          securityLevel: AppSecurityLevel.defaultLevel,
        ),
      );
      await c.protectionBootstrap.synchronize();
    }

    Future<void> openApp(WidgetTester tester, AppContainer c) async {
      (c.accessibility as StaticAccessibilityLockService)
          .emitForegroundPackage(_app);
      await tester.pumpAndSettle();
    }

    Future<void> typePin(WidgetTester tester, String pin) async {
      for (final String d in pin.split('')) {
        await tester.tap(find.byKey(Key('pin_key_$d')));
        await tester.pumpAndSettle();
      }
    }

    Object? sessionFor(AppContainer c) =>
        (c.accessController as DefaultAccessController).sessionFor(_app);

    int launches(AppContainer c) =>
        (c.installedAppsService as StaticInstalledAppsService).launchAppCalls;

    /// A container whose failure-log storage hangs forever (reads + writes)
    /// once [stall] is called.
    (AppContainer, void Function()) stalledContainer() {
      final _LogFaultDb db = _LogFaultDb();
      final AppContainer c = AppContainer.inMemory(database: db);
      return (
        c,
        () {
          db.readGate = Completer<void>();
          db.writeGate = Completer<void>();
        },
      );
    }

    testWidgets(
        'after a wrong PIN with the log stalled, the correct PIN grants on '
        'the challenge immediately', (WidgetTester tester) async {
      final (AppContainer c, void Function() stall) = stalledContainer();
      await pumpApp(tester, c);
      await c.auth.enrollPin('1234');
      await protect(c);
      stall();
      for (int i = 0; i < 10; i++) {
        unawaited(c.intruderMonitor.snapshot()); // waiters pile up, held
      }
      await openApp(tester, c);
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      await typePin(tester, '9999');
      await typePin(tester, '1234');

      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(sessionFor(c), isNotNull);
      expect(launches(c), 1);
    });

    testWidgets(
        'with the log stalled, three wrong PINs still lock out and grant '
        'nothing; the correct PIN is then refused (lockout unchanged)',
        (WidgetTester tester) async {
      final (AppContainer c, void Function() stall) = stalledContainer();
      await pumpApp(tester, c);
      await c.auth.enrollPin('1234');
      await protect(c);
      stall();
      await openApp(tester, c);

      for (final String p in <String>['1111', '2222', '3333']) {
        await typePin(tester, p);
      }
      expect((await c.auth.status()).valueOrNull!.lockedOutUntil, isNotNull);
      expect((await c.auth.authenticatePin('1234')).valueOrNull,
          isA<AuthLockedOut>());
      expect(sessionFor(c), isNull);
      expect(launches(c), 0);
    });
  });
}
