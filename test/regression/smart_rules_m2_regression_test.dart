// Phase 10 / M2 regression: raising Smart Rules through the production app.
//
// SIMULATED: production SmartAppLockApp, MainShell, router, challenge host,
// Phase 7 health, Phase 8 levels and Phase 9 Security Center over
// AppContainer.inMemory and static platform services. The static watcher
// stands in for native (rule resolution mirrors SmartRulePolicy.kt). No
// Android device, native watcher or OEM behaviour is observed; physical QA
// is pending (docs/regression.md, Phase 10 / M2).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_key_value_store.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/watcher_service.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';

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

/// Raises every protected app to Critical, every day, all day.
final SmartRule _raiseAll = SmartRule(
  id: 'raise-all',
  name: 'Everything Critical',
  targetPackages: const <String>[_std, _sens, _crit],
  days: SmartRuleDays.everyDay,
  time: const SmartRuleTime.allDay(),
  action: SmartRuleAction.critical,
);

class _Fx {
  _Fx(this.c, this.db, this.kv, this.secrets);

  final AppContainer c;
  final InMemoryLocalDatabase db;
  final InMemoryKeyValueStore kv;
  final InMemorySecretStore secrets;

  StaticWatcherService get watcher => c.watcher as StaticWatcherService;
  StaticAccessibilityLockService get accessibility =>
      c.accessibility as StaticAccessibilityLockService;
  DefaultAccessController get access =>
      c.accessController as DefaultAccessController;

  static Future<_Fx> create() async {
    final InMemoryLocalDatabase db = InMemoryLocalDatabase();
    final InMemoryKeyValueStore kv = InMemoryKeyValueStore();
    final InMemorySecretStore secrets = InMemorySecretStore();
    final AppContainer c = _container(db, kv, secrets);
    await c.auth.enrollPin(_pin);
    for (final MapEntry<String, _L> e in <String, _L>{
      _std: _L.standard,
      _sens: _L.sensitive,
      _crit: _L.critical,
    }.entries) {
      await c.protectedApps.add(ProtectedApp(
        packageName: e.key,
        label: e.key.split('.').last,
        addedAt: DateTime(2026, 11, 1),
        securityLevel: e.value,
      ));
    }
    await c.lockSettings.setGracePeriod(const Duration(seconds: 30));
    _healthy(c);
    return _Fx(c, db, kv, secrets);
  }

  static AppContainer _container(
    InMemoryLocalDatabase db,
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

  Future<void> saveAndSync(SmartRule rule) async {
    expect((await c.smartRules.saveRule(rule)).isSuccess, isTrue);
    final result = await c.protectionBootstrap.synchronize();
    expect(
        result.valueOrNull?.policyAck.ruleStatus, SmartRuleSyncStatus.applied);
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

Future<void> _pinEntry(WidgetTester tester, String pin) async {
  for (final String digit in pin.split('')) {
    await tester.tap(find.byKey(Key('pin_key_$digit')));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

int? _points(WidgetTester tester) {
  final Finder value = find.byKey(const Key('sc_score_value'));
  if (value.evaluate().isEmpty) return null;
  return int.parse(tester.widget<Text>(value).data!);
}

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

void main() {
  testWidgets(
      'M2-R1. Phase 8: a raising rule never overwrites saved levels; native '
      'keeps the baseline levels and enforces the rule on top',
      (WidgetTester tester) async {
    final _Fx fx = await _Fx.create();
    await _pumpApp(tester, fx);
    final Map<String, _L> before = await fx.levels();
    final Map<String, _L> nativeBefore =
        Map<String, _L>.of(fx.watcher.securityLevels);

    await fx.saveAndSync(_raiseAll);
    expect(await fx.levels(), before);
    expect(fx.watcher.securityLevels, nativeBefore);
    final DateTime now = DateTime.now();
    for (final String app in <String>[_std, _sens, _crit]) {
      expect(fx.watcher.simulatedRuleLevel(app, now), _L.critical);
    }
  });

  testWidgets(
      'M2-R2. Phase 9: score and recommendations are not inflated by a '
      'raising rule, before and after a restart', (WidgetTester tester) async {
    final _Fx fx = await _Fx.create();
    await _pumpApp(tester, fx);
    await _go(tester, 'nav_security');
    final int? pointsBefore = _points(tester);
    final List<String> recsBefore = _recKeys(tester);
    expect(pointsBefore, isNotNull);

    await fx.saveAndSync(_raiseAll);
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
  });

  testWidgets(
      'M2-R3. a Standard app under a Critical rule is challenged and the '
      'unlock is granted (and sent to native) at the rule level',
      (WidgetTester tester) async {
    final _Fx fx = await _Fx.create();
    await _pumpApp(tester, fx);
    await fx.saveAndSync(_raiseAll);

    fx.accessibility.emitForegroundPackage(_std);
    await tester.pumpAndSettle();
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    await _pinEntry(tester, '1357');
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(fx.access.sessionFor(_std), isNull);

    await _pinEntry(tester, _pin);
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(fx.access.sessionFor(_std)?.securityLevel, _L.critical);
    expect(fx.watcher.authorizeLevelFloors[_std], _L.critical);
  });

  testWidgets(
      'M2-R4. a pending challenge survives a rule change; a raise during an '
      'open session ends it; only the exact PIN grants',
      (WidgetTester tester) async {
    final _Fx fx = await _Fx.create();
    await _pumpApp(tester, fx);
    await fx.access.grantAccess(_std); // an open Standard unlock
    expect(fx.access.sessionFor(_std)?.securityLevel, _L.standard);

    fx.accessibility.emitForegroundPackage(_crit);
    await tester.pumpAndSettle();
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    await fx.saveAndSync(_raiseAll);
    await fx.access.revokeImmediately(_std); // as the Smart UI does on save
    await tester.pumpAndSettle();
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    final Route<dynamic>? top =
        ModalRoute.of(tester.element(find.byType(PinUnlockScreen)));
    expect(top?.isCurrent, isTrue);
    expect(fx.access.sessionFor(_std), isNull);
    expect(fx.access.sessionFor(_crit), isNull);

    await _pinEntry(tester, _pin);
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(fx.access.sessionFor(_crit), isNotNull);
    expect(fx.access.sessionFor(_std), isNull,
        reason: 'a challenge grants only its own app');
  });

  testWidgets(
      'M2-R5. after a restart the rules are read and sent again; the Smart '
      'tab lists them; navigation stays intact', (WidgetTester tester) async {
    final _Fx fx = await _Fx.create();
    await _pumpApp(tester, fx);
    await fx.saveAndSync(_raiseAll);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    final _Fx next = fx.restart();
    await _pumpApp(tester, next);
    expect(next.watcher.receivedPolicies.last?.smartRules, hasLength(1));
    expect(next.c.protectionBootstrap.ruleCache.levelFor(_std, DateTime.now()),
        _L.critical);
    for (final String tab in <String>[
      'nav_apps',
      'nav_smart',
      'nav_security',
      'nav_settings',
      'nav_home',
      'nav_smart',
    ]) {
      await _go(tester, tab);
    }
    expect(find.text('Everything Critical'), findsOneWidget);
    expect(find.textContaining('Active'), findsNothing);
  });
}
