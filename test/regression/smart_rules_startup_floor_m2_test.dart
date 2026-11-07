// Phase 10 / M2 — R-A startup safety: while Smart Rules are not currently
// known (cold start before the first successful read, or after a failed
// read), every protected app is treated as Critical at the Dart
// authorization boundary, which is also the floor native receives.
//
// Promoted from the persistence-gate startup-gap probe
// (Phase10_M2/gate/startup_gap_probe_test.dart), where the two GAP cases
// failed before R-A.
//
// SIMULATED: AppContainer.inMemory over shared stores (process restart =
// a new container over the same database / secrets / key-value store);
// production DefaultAccessController, ProtectionBootstrap, LockChallengeHost
// and SmartRuleRepositoryImpl; "native" is the static watcher. No device.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/impl/smart_rule_repository_impl.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_key_value_store.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/access_controller.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/protection/lock_session.dart';
import 'package:smart_app_lock/protection/security_level_policy.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/watcher_service.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';

typedef _L = AppSecurityLevel;

const String _pin = '2468';
const String _std = 'com.example.notes'; // protected, Standard
const String _sens = 'com.example.chat'; // protected, Sensitive
const String _maps = 'com.example.maps'; // NOT protected

const List<AppEntry> _installed = <AppEntry>[
  AppEntry(packageName: _std, label: 'notes'),
  AppEntry(packageName: _sens, label: 'chat'),
  AppEntry(packageName: _maps, label: 'maps'),
];

const Duration _grace = Duration(seconds: 30);

/// A Critical rule for the CHAT app only (notes has no rule).
final SmartRule _chatCritical = SmartRule(
  id: 'chat-critical',
  name: 'Chat always Critical',
  targetPackages: const <String>[_sens],
  days: SmartRuleDays.everyDay,
  time: const SmartRuleTime.allDay(),
  action: SmartRuleAction.critical,
);

/// A Critical rule for the NOTES app (the "restored" stricter rule).
final SmartRule _notesCritical = SmartRule(
  id: 'notes-critical',
  name: 'Notes always Critical',
  targetPackages: const <String>[_std],
  days: SmartRuleDays.everyDay,
  time: const SmartRuleTime.allDay(),
  action: SmartRuleAction.critical,
);

class _Db extends InMemoryLocalDatabase {
  bool failRuleReads = false;
  Completer<void>? holdRuleReads;
  int ruleReads = 0;

  @override
  Future<String?> getSetting(String key) async {
    if (key == SmartRuleRepositoryImpl.storageKey) {
      ruleReads++;
      final Completer<void>? hold = holdRuleReads;
      if (hold != null) await hold.future;
      if (failRuleReads) throw StateError('simulated rule read failure');
    }
    return super.getSetting(key);
  }
}

class _Fx {
  _Fx(this.c, this.db, this.kv, this.secrets, this.clock);

  final AppContainer c;
  final _Db db;
  final InMemoryKeyValueStore kv;
  final InMemorySecretStore secrets;
  final _Clock clock;

  StaticWatcherService get watcher => c.watcher as StaticWatcherService;
  StaticAccessibilityLockService get accessibility =>
      c.accessibility as StaticAccessibilityLockService;
  DefaultAccessController get access =>
      c.accessController as DefaultAccessController;

  /// Enrolled PIN, notes (Standard) and chat (Sensitive) protected, maps
  /// installed but unprotected, 30 s grace. [rules] are saved to storage.
  static Future<_Fx> create({
    List<SmartRule> rules = const <SmartRule>[],
    _Clock? clock,
  }) async {
    final _Db db = _Db();
    final InMemoryKeyValueStore kv = InMemoryKeyValueStore();
    final InMemorySecretStore secrets = InMemorySecretStore();
    final _Clock k = clock ?? _Clock();
    final AppContainer c = _container(db, kv, secrets, k);
    await c.auth.enrollPin(_pin);
    await c.protectedApps.add(ProtectedApp(
      packageName: _std,
      label: 'notes',
      addedAt: DateTime(2026, 11, 1),
    ));
    await c.protectedApps.add(ProtectedApp(
      packageName: _sens,
      label: 'chat',
      addedAt: DateTime(2026, 11, 1),
      securityLevel: _L.sensitive,
    ));
    for (final SmartRule r in rules) {
      expect((await c.smartRules.saveRule(r)).isSuccess, isTrue);
    }
    await c.lockSettings.setGracePeriod(_grace);
    // Every case starts from a process restart over these stores, so no
    // rule read has happened in the container under test.
    final _Fx restarted = _Fx(c, db, kv, secrets, k).restart();
    db.ruleReads = 0;
    return restarted;
  }

  static AppContainer _container(
    _Db db,
    InMemoryKeyValueStore kv,
    InMemorySecretStore secrets,
    _Clock clock,
  ) =>
      AppContainer.inMemory(
        apps: _installed,
        database: db,
        secretStore: secrets,
        keyValueStore: kv,
        accessibilityEnabled: true,
        overlayGranted: true,
        accessClock: clock.call,
      );

  /// SIMULATED process restart over the same persisted stores.
  _Fx restart() {
    final AppContainer next = _container(db, kv, secrets, clock);
    (next.watcher as StaticWatcherService)
      ..protectionConfigured = true
      ..running = true
      ..accessibilityServiceConnected = true
      ..shieldArmed = true
      ..challengePending = false
      ..backgroundRestricted = false
      ..powerSaveMode = false
      ..ignoringBatteryOptimizations = false
      ..sdkInt = 34;
    next.accessController.setGracePeriod(_grace);
    return _Fx(next, db, kv, secrets, clock);
  }

  Future<Map<String, _L>> savedLevels() async => <String, _L>{
        for (final ProtectedApp a
            in (await c.protectedApps.getProtectedApps()).valueOrNull!)
          a.packageName: a.securityLevel,
      };

  Future<_L> grant(String pkg) async =>
      (await c.accessController.grantAccess(pkg)).valueOrNull!.securityLevel;

  /// Grant, leave, come back [after] later.
  Future<AccessDecision> leaveAndReturn(String pkg, Duration after) async {
    await c.accessController.revokeAccess(pkg);
    clock.advance(after);
    return c.accessController.evaluate(pkg);
  }
}

class _Clock {
  DateTime now = DateTime(2026, 11, 2, 12);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

final Duration _criticalWindow = SecurityLevelPolicy.sessionWindowFor(
    _L.critical, LockSession.defaultWindow);
final Duration _standardWindow = SecurityLevelPolicy.sessionWindowFor(
    _L.standard, LockSession.defaultWindow);

Future<void> _pinEntry(WidgetTester tester, String pin) async {
  for (final String digit in pin.split('')) {
    await tester.tap(find.byKey(Key('pin_key_$digit')));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// PIN entry without pumpAndSettle (spinners may be running while a rule
/// read is held).
Future<void> _pinEntryFrames(WidgetTester tester, String pin) async {
  for (final String digit in pin.split('')) {
    await tester.tap(find.byKey(Key('pin_key_$digit')));
    await tester.pump();
  }
  for (int i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _frames(WidgetTester tester, [int n = 20]) async {
  for (int i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('R-A: Critical floor while Smart Rules are not known (SIMULATED)', () {
    test(
        'RA-1. cold start, before the start-up sync read the rules: a '
        'protected app is challenged, a grant is Critical (short window, no '
        'grace) and re-entry inside the Standard grace is challenged',
        () async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_notesCritical]);
      expect(fx.c.protectionBootstrap.ruleCache.current, isFalse);
      expect(fx.db.ruleReads, 0);

      // No authorization without a credential + grant.
      expect(
          await fx.c.accessController.evaluate(_std), AccessDecision.challenge);
      expect(await fx.grant(_std), _L.critical);
      expect(fx.access.sessionFor(_std)!.window, _criticalWindow);
      expect(await fx.leaveAndReturn(_std, const Duration(seconds: 2)),
          AccessDecision.challenge);
      expect(fx.access.departureAtFor(_std), isNull);
      // Saved levels are never changed by the floor.
      expect(await fx.savedLevels(),
          <String, _L>{_std: _L.standard, _sens: _L.sensitive});
    });

    test(
        'RA-2. failed start-up rule read: grants stay Critical until a later '
        'successful read; then the actual levels (and Standard grace) apply',
        () async {
      final _Fx fx = await _Fx.create();
      fx.db.failRuleReads = true;
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.c.protectionBootstrap.ruleCache.current, isFalse);
      expect(fx.c.protectionBootstrap.lastRuleReadError, isNotNull);
      // Native was not sent a rule list (it keeps its own copy).
      expect(fx.watcher.receivedPolicies.last?.smartRules, isNull);

      expect(await fx.grant(_std), _L.critical);
      expect(await fx.leaveAndReturn(_std, const Duration(seconds: 2)),
          AccessDecision.challenge);
      expect(await fx.grant(_sens), _L.critical);

      // Reads recover: a successful, current load replaces the floor.
      fx.db.failRuleReads = false;
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.c.protectionBootstrap.ruleCache.current, isTrue);
      expect(await fx.grant(_std), _L.standard);
      expect(fx.access.sessionFor(_std)!.window, _standardWindow);
      // Phase 5L/8 Standard grace is preserved once the rules are known.
      expect(await fx.leaveAndReturn(_std, const Duration(seconds: 2)),
          AccessDecision.allow);
      expect(await fx.grant(_sens), _L.sensitive);
    });

    test(
        'RA-3. a read that fails AFTER a successful load (stale copy): an '
        'open Standard session is revoked at the next decision and new '
        'grants are Critical', () async {
      final _Fx fx = await _Fx.create();
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.c.protectionBootstrap.ruleCache.current, isTrue);
      expect(await fx.grant(_std), _L.standard);
      expect(await fx.c.accessController.evaluate(_std), AccessDecision.allow);

      fx.db.failRuleReads = true;
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.c.protectionBootstrap.ruleCache.loaded, isTrue);
      expect(fx.c.protectionBootstrap.ruleCache.current, isFalse);
      expect(
          await fx.c.accessController.evaluate(_std), AccessDecision.challenge);
      expect(fx.access.sessionFor(_std), isNull);
      expect(await fx.grant(_std), _L.critical);
    });

    test(
        'RA-4. after a successful sync the floor is lifted: rule level where '
        'a rule applies, the saved level elsewhere (control)', () async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_chatCritical]);
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.c.protectionBootstrap.ruleCache.current, isTrue);
      expect(await fx.grant(_sens), _L.critical); // rule raises chat
      expect(await fx.grant(_std), _L.standard); // no rule for notes
      expect(await fx.leaveAndReturn(_std, const Duration(seconds: 2)),
          AccessDecision.allow);
      expect(await fx.leaveAndReturn(_sens, const Duration(seconds: 2)),
          AccessDecision.challenge);
    });

    test(
        'RA-5. unprotected apps are never affected and never protected; '
        'saved levels and the protected list are unchanged', () async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_notesCritical]);
      expect(fx.c.protectionBootstrap.ruleCache.current, isFalse);
      expect(await fx.c.accessController.evaluate(_maps), AccessDecision.allow);
      expect(await fx.grant(_maps), _L.standard);

      fx.db.failRuleReads = true;
      await fx.c.protectionBootstrap.synchronize();
      expect(await fx.c.accessController.evaluate(_maps), AccessDecision.allow);
      expect(await fx.grant(_maps), _L.standard);
      expect(fx.watcher.protectedPackages, <String>{_std, _sens});
      expect(fx.watcher.securityLevels,
          <String, _L>{_std: _L.standard, _sens: _L.sensitive});
      expect(await fx.savedLevels(),
          <String, _L>{_std: _L.standard, _sens: _L.sensitive});
      expect(fx.watcher.authorizedPackages, isEmpty);
    });

    test(
        'RA-6. restart after an ambiguous failed relaxation (native disk '
        'weaker, app storage restored): grants are Critical before the '
        'sync; the sync re-applies the stricter rules natively', () async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_notesCritical]);
      // Native restarted with the WEAKER persisted set (no notes rule).
      expect(fx.watcher.smartRules, isEmpty);
      expect(fx.watcher.simulatedRuleLevel(_std, fx.clock.now), isNull);

      expect(
          await fx.c.accessController.evaluate(_std), AccessDecision.challenge);
      expect(await fx.grant(_std), _L.critical);
      expect(await fx.leaveAndReturn(_std, const Duration(seconds: 2)),
          AccessDecision.challenge);

      fx.watcher.ruleClock = fx.clock.call;
      final result = await fx.c.protectionBootstrap.synchronize();
      expect(result.valueOrNull?.policyAck.ruleStatus,
          SmartRuleSyncStatus.applied);
      expect(
          fx.watcher.receivedPolicies.last?.authorizedRuleRelaxation, isFalse);
      expect(fx.watcher.simulatedRuleLevel(_std, fx.clock.now), _L.critical);
      expect(await fx.grant(_std), _L.critical); // now from the rule itself
      expect(fx.watcher.authorizedPackages, isEmpty);
    });
  });

  group('R-A through the real lock host and native floor (SIMULATED)', () {
    Future<void> pumpApp(WidgetTester tester, _Fx fx) async {
      tester.view.physicalSize = const Size(1080, 6000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(fx.c.capabilityMonitor.dispose);
      await tester.pumpWidget(SmartAppLockApp(container: fx.c));
    }

    testWidgets(
        'RA-7. failed start-up rule read: the PIN unlock is sent to native '
        'with the Critical floor, and leaving and returning inside the '
        'Standard grace challenges again; after recovery Standard grace '
        'applies (control)', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(clock: _Clock()..now = DateTime.now());
      fx.db.failRuleReads = true;
      await pumpApp(tester, fx);
      await tester.pumpAndSettle();
      expect(fx.c.protectionBootstrap.ruleCache.current, isFalse);

      fx.accessibility.emitForegroundPackage(_std);
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(fx.watcher.authorizedPackages, isEmpty);
      await _pinEntry(tester, _pin);
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(fx.access.sessionFor(_std)?.securityLevel, _L.critical);
      expect(fx.watcher.authorizeLevelFloors[_std], _L.critical);

      fx.accessibility.emitForegroundPackage(_maps);
      await tester.pumpAndSettle();
      fx.accessibility.emitForegroundPackage(_std);
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await _pinEntry(tester, _pin);
      expect(find.byType(PinUnlockScreen), findsNothing);

      // Control: reads recover → actual level → Standard grace.
      fx.db.failRuleReads = false;
      await fx.c.protectionBootstrap.synchronize();
      await tester.pumpAndSettle();
      expect(fx.c.protectionBootstrap.ruleCache.current, isTrue);
      fx.accessibility.emitForegroundPackage(_maps);
      await tester.pumpAndSettle();
      fx.accessibility.emitForegroundPackage(_std);
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await _pinEntry(tester, _pin);
      expect(fx.access.sessionFor(_std)?.securityLevel, _L.standard);
      expect(fx.watcher.authorizeLevelFloors[_std], _L.standard);
      fx.accessibility.emitForegroundPackage(_maps);
      await tester.pumpAndSettle();
      fx.accessibility.emitForegroundPackage(_std);
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsNothing);
    });

    testWidgets(
        'RA-8. cold-start race: a PIN unlock while the start-up rule read is '
        'still in flight is Critical (Dart and native floor); the floor is '
        'in place before any authorization', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
        rules: <SmartRule>[_notesCritical],
        clock: _Clock()..now = DateTime.now(),
      );
      // Restarted native loaded its own persisted protected list.
      fx.watcher.protectedPackages = <String>{_std, _sens};
      final Completer<void> hold = Completer<void>();
      fx.db.holdRuleReads = hold;
      await pumpApp(tester, fx);
      await _frames(tester);
      expect(fx.db.ruleReads, greaterThan(0)); // the start-up read began
      expect(fx.c.protectionBootstrap.ruleCache.current, isFalse);

      fx.accessibility.emitForegroundPackage(_std);
      await _frames(tester);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await _pinEntryFrames(tester, _pin);
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(fx.access.sessionFor(_std)?.securityLevel, _L.critical);
      expect(fx.watcher.authorizeLevelFloors[_std], _L.critical);
      expect(fx.c.protectionBootstrap.ruleCache.current, isFalse);

      fx.db.holdRuleReads = null;
      hold.complete();
      await tester.pumpAndSettle();
      expect(fx.c.protectionBootstrap.ruleCache.current, isTrue);
      // The stored rule itself keeps notes Critical after the load.
      expect(await fx.grant(_std), _L.critical);
    });
  });
}
