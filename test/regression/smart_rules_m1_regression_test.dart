// Phase 10 / M1 regression: Smart Rules are configuration only.
//
// SIMULATED: production app, MainShell, router, challenge host, Phase 7
// health, Phase 8 levels and Phase 9 Security Center over the container's
// in-memory stores and static platform services, with saved Smart Rules in
// the real SmartRuleRepositoryImpl. No Android device, native watcher or
// OEM behaviour is observed; physical QA is pending (docs/regression.md,
// Phase 10 / M1).

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
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/rules/smart_rule_evaluator.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/smart/smart_screen.dart';

typedef _L = AppSecurityLevel;

const String _pin = '2468';
const String _std = 'com.example.notes';
const String _sens = 'com.example.chat';
const String _crit = 'com.example.bank';

const List<AppEntry> _installed = <AppEntry>[
  AppEntry(packageName: _std, label: 'notes'),
  AppEntry(packageName: _sens, label: 'chat'),
  AppEntry(packageName: _crit, label: 'bank'),
];

/// Counts reads of the Smart Rules key (proves nothing consumes rules).
class _Db extends InMemoryLocalDatabase {
  int ruleReads = 0;
  int ruleWrites = 0;

  @override
  Future<String?> getSetting(String key) {
    if (key == SmartRuleRepositoryImpl.storageKey) ruleReads++;
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) {
    if (key == SmartRuleRepositoryImpl.storageKey) ruleWrites++;
    return super.setSetting(key, value);
  }
}

class _Fx {
  _Fx(this.c, this.db, this.kv, this.secrets);

  final AppContainer c;
  final _Db db;
  final InMemoryKeyValueStore kv;
  final InMemorySecretStore secrets;

  StaticWatcherService get watcher => c.watcher as StaticWatcherService;
  StaticAccessibilityLockService get accessibility =>
      c.accessibility as StaticAccessibilityLockService;
  DefaultAccessController get access =>
      c.accessController as DefaultAccessController;

  static Future<_Fx> create() async {
    final _Db db = _Db();
    final InMemoryKeyValueStore kv = InMemoryKeyValueStore();
    final InMemorySecretStore secrets = InMemorySecretStore();
    final AppContainer c = _container(db, kv, secrets);
    await c.auth.enrollPin(_pin);
    for (final MapEntry<String, _L> e in <String, _L>{
      _std: _L.standard,
      _sens: _L.sensitive,
      _crit: _L.critical,
    }.entries) {
      await c.protectedApps.add(
        ProtectedApp(
          packageName: e.key,
          label: e.key.split('.').last,
          addedAt: DateTime(2026, 11, 1),
          securityLevel: e.value,
        ),
      );
    }
    await c.lockSettings.setGracePeriod(const Duration(seconds: 30));
    _healthy(c);
    return _Fx(c, db, kv, secrets);
  }

  static AppContainer _container(
    _Db db,
    InMemoryKeyValueStore kv,
    InMemorySecretStore secrets,
  ) =>
      AppContainer.inMemory(
        apps: _installed,
        database: db,
        secretStore: secrets,
        keyValueStore: kv,
        accessibilityEnabled: true,
        overlayGranted: true,
      );

  /// SIMULATED process restart over the same persisted stores.
  _Fx restart() {
    final AppContainer next = _container(db, kv, secrets);
    _healthy(next);
    return _Fx(next, db, kv, secrets);
  }

  static void _healthy(AppContainer c) {
    (c.watcher as StaticWatcherService)
      ..protectionConfigured = true
      ..running = true
      ..accessibilityServiceConnected = true
      ..shieldArmed = true
      ..challengePending = false
      ..backgroundRestricted = false
      ..powerSaveMode = false
      ..ignoringBatteryOptimizations = false
      ..sdkInt = 34;
  }

  Future<Map<String, _L>> levels() async => <String, _L>{
        for (final ProtectedApp a
            in (await c.protectedApps.getProtectedApps()).valueOrNull!)
          a.packageName: a.securityLevel,
      };

  /// An enabled rule that matches every protected app at any time, saved.
  Future<SmartRule> saveMatchingRule() async {
    final SmartRule rule = SmartRule(
      id: 'everything',
      name: 'All protected apps, always',
      targetPackages: const <String>[_std, _sens, _crit],
      days: SmartRuleDays.everyDay,
      time: const SmartRuleTime.allDay(),
    );
    expect((await c.smartRules.saveRule(rule)).isSuccess, isTrue);
    expect((await c.smartRules.getRules()).valueOrNull, <SmartRule>[rule]);
    return rule;
  }
}

Future<void> _pumpApp(WidgetTester tester, _Fx fx) async {
  tester.view.physicalSize = const Size(1080, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(fx.c.capabilityMonitor.dispose);
  await tester.pumpWidget(SmartAppLockApp(container: fx.c));
  await tester.pumpAndSettle();
  await fx.c.protectionBootstrap.synchronize();
  await tester.pumpAndSettle();
}

Future<void> _go(WidgetTester tester, String tab) async {
  await tester.tap(find.byKey(Key(tab)));
  await tester.pumpAndSettle();
}

/// The score number shown on the Security tab, or null.
int? _points(WidgetTester tester) {
  final Finder value = find.byKey(const Key('sc_score_value'));
  if (value.evaluate().isEmpty) return null;
  return int.parse(tester.widget<Text>(value).data!);
}

/// Every Security Center recommendation key on screen, sorted.
List<String> _recKeys(WidgetTester tester) => find
    .byWidgetPredicate((Widget w) {
      final Key? k = w.key;
      return k is ValueKey<String> && k.value.startsWith('sc_rec_');
    })
    .evaluate()
    .map((Element e) => (e.widget.key! as ValueKey<String>).value)
    .toSet()
    .toList()
  ..sort();

List<Object> _watcherCounters(StaticWatcherService w) => <Object>[
      w.startCalls,
      w.stopCalls,
      w.configureCalls,
      w.setGracePeriodCalls,
      w.authorizePackageCalls,
      w.revokeAllAuthorizationsCalls,
      w.gracePeriod,
    ];

void main() {
  testWidgets(
      '35. navigation intact; the Smart tab is still the non-operational '
      'placeholder; nothing reads saved rules at startup or on any tab',
      (WidgetTester tester) async {
    final _Fx fx = await _Fx.create();
    await fx.saveMatchingRule();
    final _Fx run = fx.restart();
    run.db.ruleReads = 0;
    run.db.ruleWrites = 0;
    await _pumpApp(tester, run);

    for (final String tab in <String>[
      'nav_home',
      'nav_apps',
      'nav_smart',
      'nav_security',
      'nav_settings',
      'nav_smart',
    ]) {
      await _go(tester, tab);
    }
    expect(find.byType(SmartScreen), findsOneWidget);
    expect(find.text(SmartScreen.description), findsOneWidget);
    // The saved rule is never presented, let alone as active.
    expect(find.text('All protected apps, always'), findsNothing);
    expect(find.textContaining('Active'), findsNothing);
    expect(run.db.ruleReads, 0);
    expect(run.db.ruleWrites, 0);
  });

  testWidgets(
      '36. Phase 8 Standard / Sensitive / Critical are unchanged by a saved, '
      'matching, enabled rule (stored levels and the simulated native levels)',
      (WidgetTester tester) async {
    final _Fx fx = await _Fx.create();
    await _pumpApp(tester, fx);
    final Map<String, _L> levelsBefore = await fx.levels();
    expect(levelsBefore, <String, _L>{
      _std: _L.standard,
      _sens: _L.sensitive,
      _crit: _L.critical,
    });
    final Map<String, _L> nativeBefore =
        Map<String, _L>.of(fx.watcher.securityLevels);
    final List<Object> countersBefore = _watcherCounters(fx.watcher);

    final SmartRule rule = await fx.saveMatchingRule();
    for (final String app in <String>[_std, _sens, _crit]) {
      expect(
        const SmartRuleEvaluator()
            .evaluate(rule, app, DateTime(2026, 11, 4, 12))
            .isMatch,
        isTrue,
      );
    }
    await fx.c.smartRules.setRuleEnabled(rule.id, enabled: false);
    await fx.c.smartRules.saveRule(rule);
    await tester.pumpAndSettle();

    expect(await fx.levels(), levelsBefore);
    expect(fx.watcher.securityLevels, nativeBefore);
    expect(_watcherCounters(fx.watcher), countersBefore);
    expect(fx.watcher.authorizeLevelFloors, isEmpty);

    // A full re-synchronization still sends the saved baseline levels.
    await fx.c.protectionBootstrap.synchronize();
    expect(fx.watcher.securityLevels, nativeBefore);
    expect(await fx.levels(), levelsBefore);
  });

  testWidgets(
      '37. Phase 9 score and recommendations are identical with saved rules, '
      'before and after a restart', (WidgetTester tester) async {
    final _Fx fx = await _Fx.create();
    await _pumpApp(tester, fx);
    await _go(tester, 'nav_security');
    final int? pointsBefore = _points(tester);
    final List<String> recsBefore = _recKeys(tester);
    expect(pointsBefore, isNotNull);
    expect(recsBefore, isNotEmpty);

    await fx.saveMatchingRule();
    await _go(tester, 'nav_home');
    await _go(tester, 'nav_security');
    expect(_points(tester), pointsBefore);
    expect(_recKeys(tester), recsBefore);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    final _Fx next = fx.restart();
    await _pumpApp(tester, next);
    await _go(tester, 'nav_security');
    expect(_points(tester), pointsBefore);
    expect(_recKeys(tester), recsBefore);
    expect((await next.c.smartRules.getRules()).valueOrNull, hasLength(1));
  });

  testWidgets(
      '38. a pending PIN challenge is unaffected by rule storage and '
      'evaluation; only the exact PIN grants', (WidgetTester tester) async {
    final _Fx fx = await _Fx.create();
    await _pumpApp(tester, fx);
    fx.accessibility.emitForegroundPackage(_crit);
    await tester.pumpAndSettle();
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    final SmartRule rule = await fx.saveMatchingRule();
    await fx.c.smartRules.setRuleEnabled(rule.id, enabled: false);
    const SmartRuleEvaluator().evaluate(rule, _crit, DateTime(2026, 11, 4, 12));
    await fx.c.smartRules.deleteRule(rule.id);
    await tester.pumpAndSettle();

    expect(find.byType(PinUnlockScreen), findsOneWidget);
    final Route<dynamic>? top =
        ModalRoute.of(tester.element(find.byType(PinUnlockScreen)));
    expect(top?.isCurrent, isTrue);
    expect(fx.access.sessionFor(_crit), isNull);
    expect(fx.watcher.authorizePackageCalls, 0);

    for (final String digit in '1357'.split('')) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(fx.access.sessionFor(_crit), isNull);

    for (final String digit in _pin.split('')) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(fx.access.sessionFor(_crit), isNotNull);
  });
}
