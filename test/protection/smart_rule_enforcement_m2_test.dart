// Phase 10 / M2 (PRD 10F, live application): Dart-side enforcement of the
// raise-only Smart Rules — bootstrap transport, rule cache, access
// controller floor, session/grace isolation, native acknowledgement.
//
// SIMULATED: production AppContainer.inMemory (repositories, access
// controller, protection bootstrap) with the static watcher standing in for
// native (its rule resolution mirrors SmartRuleSnapshotResolver in
// SmartRulePolicy.kt). No device, no real native watcher, no OEM behaviour.

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/impl/smart_rule_repository_impl.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/access_controller.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/protection/protection_bootstrap.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/watcher_service.dart';
import 'package:smart_app_lock/utilities/result.dart';

typedef _L = AppSecurityLevel;

const String _std = 'com.example.notes';
const String _sens = 'com.example.chat';
const String _crit = 'com.example.bank';

class _Db extends InMemoryLocalDatabase {
  bool failRuleReads = false;

  @override
  Future<String?> getSetting(String key) {
    if (failRuleReads && key == SmartRuleRepositoryImpl.storageKey) {
      throw StateError('simulated rule read failure');
    }
    return super.getSetting(key);
  }
}

class _Fx {
  _Fx(this.c, this.db);

  final AppContainer c;
  final _Db db;

  /// Monday 2026-11-02, local.
  static DateTime now = DateTime(2026, 11, 2, 12);

  StaticWatcherService get watcher => c.watcher as StaticWatcherService;
  DefaultAccessController get access =>
      c.accessController as DefaultAccessController;
  ProtectionBootstrap get bootstrap => c.protectionBootstrap;

  static Future<_Fx> create() async {
    now = DateTime(2026, 11, 2, 12);
    final _Db db = _Db();
    final AppContainer c = AppContainer.inMemory(
      apps: const <AppEntry>[
        AppEntry(packageName: _std, label: 'Notes'),
        AppEntry(packageName: _sens, label: 'Chat'),
        AppEntry(packageName: _crit, label: 'Bank'),
      ],
      database: db,
      accessClock: () => now,
    );
    await c.auth.enrollPin('2468');
    for (final MapEntry<String, _L> e in <String, _L>{
      _std: _L.standard,
      _sens: _L.sensitive,
      _crit: _L.critical,
    }.entries) {
      await c.protectedApps.add(ProtectedApp(
        packageName: e.key,
        label: e.key,
        addedAt: DateTime(2026, 11, 1),
        securityLevel: e.value,
      ));
    }
    (c.watcher as StaticWatcherService).ruleClock = () => now;
    await c.protectionBootstrap.synchronize();
    return _Fx(c, db);
  }

  Future<void> save(SmartRule rule) async {
    expect((await c.smartRules.saveRule(rule)).isSuccess, isTrue);
  }

  Future<ProtectionBootstrapResult> sync({bool relax = false}) async {
    final Result<ProtectionBootstrapResult> r =
        await bootstrap.synchronize(authorizedRuleRelaxation: relax);
    expect(r.isSuccess, isTrue, reason: '${r.errorOrNull}');
    return r.valueOrNull!;
  }
}

SmartRule _rule({
  String id = 'r1',
  List<String> targets = const <String>[_std],
  SmartRuleTime time = const SmartRuleTime.allDay(),
  SmartRuleAction action = SmartRuleAction.critical,
  bool enabled = true,
}) =>
    SmartRule(
      id: id,
      name: 'Rule $id',
      targetPackages: targets,
      days: SmartRuleDays.everyDay,
      time: time,
      action: action,
      enabled: enabled,
    );

SmartRuleTime _win(int startH, int endH) =>
    SmartRuleTime.window(startMinute: startH * 60, endMinute: endH * 60);

void main() {
  group('17–19. bootstrap ↔ native (SIMULATED)', () {
    test(
        '17. the snapshot carries only enabled raising rules; the result '
        'carries THIS call\'s ack', () async {
      final _Fx fx = await _Fx.create();
      await fx.save(_rule(id: 'a'));
      await fx.save(_rule(id: 'b', action: SmartRuleAction.standard));
      await fx.save(_rule(id: 'c', enabled: false));
      final ProtectionBootstrapResult result = await fx.sync();
      final ProtectionPolicySnapshot sent = fx.watcher.receivedPolicies.last!;
      expect(sent.smartRules, hasLength(1));
      expect(sent.smartRules!.single['level'], 'critical');
      expect(sent.toChannelArguments()['smartRulesVersion'], 1);
      expect(sent.authorizedRuleRelaxation, isFalse);
      expect(result.policyAck.ruleStatus, SmartRuleSyncStatus.applied);
      expect(fx.watcher.simulatedRuleLevel(_std, _Fx.now), _L.critical);
      // The saved baseline is never overwritten by a rule.
      expect(fx.watcher.securityLevels[_std], _L.standard);
      final ProtectedApp std = (await fx.c.protectedApps.getProtectedApps())
          .valueOrNull!
          .firstWhere((ProtectedApp a) => a.packageName == _std);
      expect(std.securityLevel, _L.standard);
    });

    test(
        '18. an unreadable rule document sends NO rules: native keeps its '
        'persisted rules, the Dart cache keeps its last good copy', () async {
      final _Fx fx = await _Fx.create();
      await fx.save(_rule());
      await fx.sync();
      expect(fx.bootstrap.ruleCache.levelFor(_std, _Fx.now), _L.critical);

      fx.db.failRuleReads = true;
      final ProtectionBootstrapResult result = await fx.sync();
      final ProtectionPolicySnapshot sent = fx.watcher.receivedPolicies.last!;
      expect(sent.smartRules, isNull);
      expect(
          sent.toChannelArguments().containsKey('smartRulesVersion'), isFalse);
      expect(result.policyAck.ruleStatus, SmartRuleSyncStatus.kept);
      expect(fx.bootstrap.lastRuleReadError, isNotNull);
      expect(fx.watcher.simulatedRuleLevel(_std, _Fx.now), _L.critical);
      expect(fx.bootstrap.ruleCache.levelFor(_std, _Fx.now), _L.critical,
          reason: 'never an empty list after a failed read');
    });

    test(
        '19. a reduction without the CR-2 flag is held (stricter union); '
        'with it, applied', () async {
      final _Fx fx = await _Fx.create();
      final SmartRule rule = _rule();
      await fx.save(rule);
      await fx.sync();

      expect(
          (await fx.c.smartRules.setRuleEnabled(rule.id, enabled: false))
              .isSuccess,
          isTrue);
      final ProtectionBootstrapResult held = await fx.sync();
      expect(held.policyAck.ruleStatus, SmartRuleSyncStatus.held);
      expect(fx.watcher.simulatedRuleLevel(_std, _Fx.now), _L.critical,
          reason: 'native still enforces the stricter rule');

      final ProtectionBootstrapResult applied = await fx.sync(relax: true);
      expect(applied.policyAck.ruleStatus, SmartRuleSyncStatus.applied);
      expect(fx.watcher.simulatedRuleLevel(_std, _Fx.now), isNull);
    });
  });

  group('20–24. access controller floor and session isolation (SIMULATED)', () {
    test(
        '20. a rule raising the level ends an older, laxer session at the '
        'next decision', () async {
      final _Fx fx = await _Fx.create();
      expect((await fx.access.grantAccess(_std)).valueOrNull!.securityLevel,
          _L.standard);
      expect(await fx.access.evaluate(_std), AccessDecision.allow);

      await fx.save(_rule());
      await fx.sync();
      expect(await fx.access.evaluate(_std), AccessDecision.challenge);
      expect(fx.access.sessionFor(_std), isNull);
      // A new unlock is granted at the rule level.
      expect((await fx.access.grantAccess(_std)).valueOrNull!.securityLevel,
          _L.critical);
    });

    test('21. a rule ending creates no grace and no authorization', () async {
      final _Fx fx = await _Fx.create();
      fx.access.setGracePeriod(const Duration(seconds: 30));
      await fx.save(_rule(time: _win(9, 17)));
      await fx.sync();
      _Fx.now = DateTime(2026, 11, 2, 16, 59);
      expect(fx.access.sessionFor(_std), isNull);
      expect((await fx.access.grantAccess(_std)).valueOrNull!.securityLevel,
          _L.critical);

      _Fx.now = DateTime(2026, 11, 2, 17, 0, 5); // rule ended
      await fx.access.revokeAccess(_std); // leave
      expect(fx.access.departureAtFor(_std), isNull,
          reason: 'a Critical unlock never turns into Standard grace');
      expect(fx.access.sessionFor(_std), isNull);
      expect(await fx.access.evaluate(_std), AccessDecision.challenge);
      expect(fx.watcher.authorizedPackages, isNot(contains(_std)));
    });

    test(
        '22. the baseline floor holds: a Sensitive rule never lowers a '
        'Critical app', () async {
      final _Fx fx = await _Fx.create();
      await fx.save(_rule(
        targets: <String>[_crit, _sens],
        action: SmartRuleAction.sensitive,
      ));
      await fx.sync();
      expect((await fx.access.grantAccess(_crit)).valueOrNull!.securityLevel,
          _L.critical);
      expect((await fx.access.grantAccess(_sens)).valueOrNull!.securityLevel,
          _L.sensitive);
    });

    test('23. clock moved back or forward is evaluated at each decision',
        () async {
      final _Fx fx = await _Fx.create();
      await fx.save(_rule(time: _win(9, 17)));
      await fx.sync();
      _Fx.now = DateTime(2026, 11, 2, 18);
      expect((await fx.access.grantAccess(_std)).valueOrNull!.securityLevel,
          _L.standard);
      _Fx.now = DateTime(2026, 11, 2, 10); // clock moved back into the rule
      expect(await fx.access.evaluate(_std), AccessDecision.challenge);
      _Fx.now = DateTime(2026, 11, 3, 8); // forward past the window
      expect((await fx.access.grantAccess(_std)).valueOrNull!.securityLevel,
          _L.standard);
      // Moving the clock can only avoid the EXTRA strictness, never the
      // saved baseline.
      expect((await fx.access.grantAccess(_crit)).valueOrNull!.securityLevel,
          _L.critical);
    });

    test(
        '24. no inherited grace: a rule starting during grace forces the '
        'challenge', () async {
      final _Fx fx = await _Fx.create();
      fx.access.setGracePeriod(const Duration(seconds: 30));
      await fx.save(_rule(time: _win(9, 17)));
      await fx.sync();
      _Fx.now = DateTime(2026, 11, 2, 8, 59, 50);
      await fx.access.grantAccess(_std);
      await fx.access.revokeAccess(_std); // Standard grace armed
      expect(fx.access.departureAtFor(_std), isNotNull);
      _Fx.now = DateTime(2026, 11, 2, 9, 0, 5); // rule started, within grace
      expect(await fx.access.evaluate(_std), AccessDecision.challenge);
      expect(fx.access.departureAtFor(_std), isNull);
    });
  });

  group('25. native acknowledgement parsing', () {
    test('only an exact ruleStatus is trusted; anything else is unknown', () {
      SmartRuleSyncStatus parse(Object? raw) => ProtectionPolicyAck.fromChannel(
              <String, Object?>{'policyStatus': 'applied', 'ruleStatus': raw})
          .ruleStatus;
      expect(parse('applied'), SmartRuleSyncStatus.applied);
      expect(parse('held'), SmartRuleSyncStatus.held);
      expect(parse('kept'), SmartRuleSyncStatus.kept);
      expect(parse('invalid'), SmartRuleSyncStatus.invalid);
      for (final Object? bad in <Object?>['APPLIED', 'unknown', 1, null]) {
        expect(parse(bad), SmartRuleSyncStatus.unknown, reason: '$bad');
      }
      expect(ProtectionPolicyAck.fromChannel(true).ruleStatus,
          SmartRuleSyncStatus.unknown);
    });

    test('a failed native configure is a failed sync (no ack to claim)',
        () async {
      final _Fx fx = await _Fx.create();
      await fx.save(_rule());
      fx.watcher.configureError = StateError('bridge down');
      final Result<ProtectionBootstrapResult> r =
          await fx.bootstrap.synchronize();
      expect(r.isFailure, isTrue);
      expect(fx.watcher.simulatedRuleLevel(_std, _Fx.now), isNull,
          reason: 'native never received the rule');
    });
  });
}
