// Phase 12 / M3 — Intruder QA (PRD: "Test failures without accidentally
// locking legitimate owners out permanently").
//
// SIMULATED: Dart VM with an injected clock and in-memory storage; the
// real challenge host is exercised with a fake camera/alarm platform and a
// fault-injecting database. No device, camera, audio or biometric hardware.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/impl/security_settings_repository_impl.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/credential_state.dart';
import 'package:smart_app_lock/security/credentials/impl/default_credential_manager.dart';
import 'package:smart_app_lock/security/credentials/pattern_hasher.dart';
import 'package:smart_app_lock/security/intruder/intruder_defense_settings.dart';
import 'package:smart_app_lock/security/pin_hasher.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';

import '../support/intruder_fixtures.dart';

const String _pin = '482916';
const String _app = 'com.bank.app';

/// Every intruder-evidence row read/write throws (evidence DB broken),
/// while the credential document and everything else work.
class _BrokenEvidenceDb extends InMemoryLocalDatabase {
  @override
  Future<String?> getSetting(String key) async {
    if (key.startsWith('intruder_evidence')) throw StateError('db fault');
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) async {
    if (key.startsWith('intruder_evidence')) throw StateError('db fault');
    return super.setSetting(key, value);
  }
}

void main() {
  group('bounded cooldown (injected clock, real credential manager)', () {
    late DateTime t;
    late DefaultCredentialManager auth;

    setUp(() async {
      t = DateTime(2026, 10, 22, 12);
      auth = DefaultCredentialManager(
        settings: SecuritySettingsRepositoryImpl(InMemoryLocalDatabase()),
        pinHasher: Pbkdf2PinHasher(iterations: 200),
        patternHasher: Pbkdf2PatternHasher(iterations: 200),
        now: () => t,
      );
      await auth.enrollPin(_pin);
    });

    Future<CredentialState> state() async => (await auth.status()).valueOrNull!;

    test(
        '60 lockouts (300 wrong PINs): every cooldown is <= 10 minutes, '
        'escalates 30s,1m,2m,4m,8m then caps; the correct PIN always works '
        'after expiry and resets the streak', () async {
      final List<Duration> cooldowns = <Duration>[];
      for (int lockout = 0; lockout < 60; lockout++) {
        for (int i = 0; i < 5; i++) {
          await auth.authenticatePin('000000');
        }
        final DateTime until = (await state()).lockedOutUntil!;
        final Duration d = until.difference(t);
        expect(d, lessThanOrEqualTo(const Duration(minutes: 10)));
        expect(d, greaterThan(Duration.zero));
        cooldowns.add(d);
        // During the cooldown even the correct PIN is refused (unchanged
        // policy) — but the lockout is always finite.
        expect((await auth.authenticatePin(_pin)).valueOrNull,
            isA<AuthLockedOut>());
        t = until.add(const Duration(milliseconds: 1));
      }
      expect(cooldowns.take(6).toList(), const <Duration>[
        Duration(seconds: 30),
        Duration(minutes: 1),
        Duration(minutes: 2),
        Duration(minutes: 4),
        Duration(minutes: 8),
        Duration(minutes: 10),
      ]);
      expect(
          cooldowns
              .skip(5)
              .every((Duration d) => d == const Duration(minutes: 10)),
          isTrue);

      expect(
          (await auth.authenticatePin(_pin)).valueOrNull, isA<AuthSuccess>());
      final CredentialState s = await state();
      expect(s.failedAttempts, 0);
      expect(s.lockoutStreak, 0);
      expect(s.lockedOutUntil, isNull);
    });

    test(
        'intruder settings writes and evidence deletes never touch attempt '
        'counters, streak or cooldown (same container / same database)',
        () async {
      final AppContainer c = AppContainer.inMemory();
      await c.auth.enrollPin(_pin);
      for (int i = 0; i < 5; i++) {
        await c.auth.authenticatePin('000000');
      }
      final CredentialState before = (await c.auth.status()).valueOrNull!;
      expect(before.lockedOutUntil, isNotNull);
      expect(before.lockoutStreak, 1);

      await c.intruderDefenseSettings.update((IntruderDefenseSettings s) =>
          s.copyWith(threshold: 1, alarmEnabled: true));
      await c.intruderEvidence.save(seq: 1, jpeg: jpegWithMetadata());
      await c.intruderEvidence.delete(1);
      await c.intruderEvidence.save(seq: 2, jpeg: jpegWithMetadata());
      c.intruderDefense.onEvidenceCleared();
      await c.intruderEvidence.clearAll(floorSeq: 2);
      await c.intruderEvidence.enforceRetention();
      await c.intruderEvidence.sweepOrphans();
      await c.intruderDefense.idle();

      final CredentialState after = (await c.auth.status()).valueOrNull!;
      expect(after.failedAttempts, before.failedAttempts);
      expect(after.lockoutStreak, before.lockoutStreak);
      expect(after.lockedOutUntil, before.lockedOutUntil);
    });
  });

  group('real challenge host: intruder failures never block the owner', () {
    Future<AppContainer> pumpApp(WidgetTester tester, AppContainer c) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(SmartAppLockApp(container: c));
      await tester.pumpAndSettle();
      return c;
    }

    Future<void> typePin(WidgetTester tester, String pin) async {
      await tester.pump(const Duration(milliseconds: 250));
      for (final String d in pin.split('')) {
        await tester.tap(find.byKey(Key('pin_key_$d')));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
    }

    Future<void> settle(WidgetTester tester, AppContainer c) async {
      await tester.pumpAndSettle();
      await c.intruderMonitor.idle();
      await c.intruderDefense.idle();
      await tester.pumpAndSettle();
    }

    testWidgets(
        'threshold 1, photo+alarm on, throwing camera/alarm platform AND a '
        'broken evidence database: the correct PIN still unlocks',
        (WidgetTester tester) async {
      final AppContainer c = await pumpApp(
        tester,
        AppContainer.inMemory(
          database: _BrokenEvidenceDb(),
          intruderEvidence: ThrowingEvidenceService(),
        ),
      );
      await c.auth.enrollPin(_pin);
      await c.intruderDefenseSettings.write(const IntruderDefenseSettings(
          evidenceEnabled: true, alarmEnabled: true, threshold: 1));
      await c.protectedApps.add(ProtectedApp(
        packageName: _app,
        label: _app,
        addedAt: DateTime(2026, 10, 22),
        securityLevel: AppSecurityLevel.defaultLevel,
      ));
      await c.protectionBootstrap.synchronize();
      (c.accessibility as StaticAccessibilityLockService)
          .emitForegroundPackage(_app);
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      for (final String p in <String>['111111', '222222']) {
        await typePin(tester, p);
        await settle(tester, c);
      }
      expect(c.intruderDefense.status.errors, greaterThan(0),
          reason: 'the faults really happened');
      expect((c.accessController as DefaultAccessController).sessionFor(_app),
          isNull);

      await typePin(tester, _pin);
      await settle(tester, c);
      expect((c.accessController as DefaultAccessController).sessionFor(_app),
          isNotNull,
          reason: 'intruder faults never change the verdict');
      final CredentialState s = (await c.auth.status()).valueOrNull!;
      expect(s.failedAttempts, 0);
      expect(s.lockedOutUntil, isNull);
    });
  });
}
