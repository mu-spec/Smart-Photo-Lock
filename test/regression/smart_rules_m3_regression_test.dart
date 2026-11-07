// Phase 10 / M3 (PRD 10L): security regression for OVERLAPPING Smart Rules
// through the production access controller, bootstrap, native fake and the
// Smart UI's CR-2 flow. Each test names the brief's scenario (A–T) and
// automated item (1–35) it covers.
//
// SIMULATED: AppContainer.inMemory with the static watcher standing in for
// native (its rule resolution and reduction check mirror SmartRulePolicy.kt;
// the shared-vector parity tests prove that). No device, no OEM behaviour.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/impl/smart_rule_repository_impl.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_key_value_store.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/access_controller.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/protection/protection_bootstrap.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/rules/smart_rule_policy.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/watcher_service.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/smart/smart_rule_presentation.dart';
import 'package:smart_app_lock/ui/screens/smart/smart_screen.dart';
import 'package:smart_app_lock/utilities/result.dart';

typedef _L = AppSecurityLevel;
typedef _T = SmartRuleText;

const String _pin = '2468';
const String _notes = 'com.example.notes'; // protected, Standard
const String _chat = 'com.example.chat'; // protected, Sensitive
const String _bank = 'com.example.bank'; // protected, Critical
const String _game = 'com.example.game'; // installed, NOT protected

/// Mutable access + native clock. Monday 2026-11-02 local by default.
DateTime _now = DateTime(2026, 11, 2, 12);

DateTime _at(int h, [int m = 0, int s = 0, int day = 2]) =>
    DateTime(2026, 11, day, h, m, s);

SmartRuleTime _win(int sh, int sm, int eh, int em) =>
    SmartRuleTime.window(startMinute: sh * 60 + sm, endMinute: eh * 60 + em);

/// Lunch Banking: Critical 12:00–14:00 every day on Notes.
final SmartRule _lunch = SmartRule(
  id: 'a-lunch',
  name: 'Lunch Banking',
  targetPackages: const <String>[_notes],
  days: SmartRuleDays.everyDay,
  time: _win(12, 0, 14, 0),
  action: SmartRuleAction.critical,
);

/// Work Hours: Sensitive 08:00–18:00 weekdays on Notes (wider, weaker).
final SmartRule _work = SmartRule(
  id: 'b-work',
  name: 'Work Hours',
  targetPackages: const <String>[_notes, _chat, _bank],
  days: SmartRuleDays.weekdays,
  time: _win(8, 0, 18, 0),
  action: SmartRuleAction.sensitive,
);

/// Inner: Sensitive 12:30–13:30 on Notes, fully covered by Lunch Banking.
final SmartRule _inner = SmartRule(
  id: 'c-inner',
  name: 'Inner Sensitive',
  targetPackages: const <String>[_notes],
  days: SmartRuleDays.everyDay,
  time: _win(12, 30, 13, 30),
  action: SmartRuleAction.sensitive,
);

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
  _Fx(this.c, this.db, this.kv, this.secrets);

  final AppContainer c;
  final _Db db;
  final InMemoryKeyValueStore kv;
  final InMemorySecretStore secrets;

  StaticWatcherService get watcher => c.watcher as StaticWatcherService;
  DefaultAccessController get access =>
      c.accessController as DefaultAccessController;
  ProtectionBootstrap get bootstrap => c.protectionBootstrap;

  static AppContainer _container(
          _Db db, InMemoryKeyValueStore kv, InMemorySecretStore secrets) =>
      AppContainer.inMemory(
        apps: const <AppEntry>[
          AppEntry(packageName: _notes, label: 'Notes'),
          AppEntry(packageName: _chat, label: 'Chat'),
          AppEntry(packageName: _bank, label: 'Bank'),
          AppEntry(packageName: _game, label: 'Game'),
        ],
        database: db,
        secretStore: secrets,
        keyValueStore: kv,
        accessClock: () => _now,
      );

  static Future<_Fx> create({
    List<SmartRule> rules = const <SmartRule>[],
  }) async {
    _now = _at(12);
    final _Db db = _Db();
    final InMemoryKeyValueStore kv = InMemoryKeyValueStore();
    final InMemorySecretStore secrets = InMemorySecretStore();
    final AppContainer c = _container(db, kv, secrets);
    await c.auth.enrollPin(_pin);
    for (final MapEntry<String, _L> e in <String, _L>{
      _notes: _L.standard,
      _chat: _L.sensitive,
      _bank: _L.critical,
    }.entries) {
      await c.protectedApps.add(ProtectedApp(
        packageName: e.key,
        label: e.key,
        addedAt: DateTime(2026, 11, 1),
        securityLevel: e.value,
      ));
    }
    (c.watcher as StaticWatcherService).ruleClock = () => _now;
    (c.accessController as DefaultAccessController)
        .setGracePeriod(const Duration(seconds: 30));
    final _Fx fx = _Fx(c, db, kv, secrets);
    for (final SmartRule r in rules) {
      expect((await c.smartRules.saveRule(r)).isSuccess, isTrue);
    }
    await fx.sync();
    return fx;
  }

  /// SIMULATED process restart over the same persisted stores (native
  /// fake state is NOT carried over: a fresh native process).
  _Fx restart() {
    final AppContainer next = _container(db, kv, secrets);
    (next.watcher as StaticWatcherService).ruleClock = () => _now;
    return _Fx(next, db, kv, secrets);
  }

  Future<ProtectionBootstrapResult> sync({bool relax = false}) async {
    final Result<ProtectionBootstrapResult> r =
        await bootstrap.synchronize(authorizedRuleRelaxation: relax);
    expect(r.isSuccess, isTrue, reason: '${r.errorOrNull}');
    return r.valueOrNull!;
  }

  Future<_L> grant(String pkg) async =>
      (await access.grantAccess(pkg)).valueOrNull!.securityLevel;

  Future<Map<String, _L>> saved() async => <String, _L>{
        for (final ProtectedApp a
            in (await c.protectedApps.getProtectedApps()).valueOrNull!)
          a.packageName: a.securityLevel,
      };
}

const Map<String, _L> _savedLevels = <String, _L>{
  _notes: _L.standard,
  _chat: _L.sensitive,
  _bank: _L.critical,
};

void main() {
  group('M3 overlap through the access controller (SIMULATED)', () {
    test(
        'E/F/G · 1–3, 29: overlapping rules — the strictest applies at each '
        'decision, Dart and native agree, saved levels never change', () async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_work, _lunch]);
      final Map<String, _L> nativeLevels =
          Map<String, _L>.of(fx.watcher.securityLevels);
      for (final (DateTime t, _L notes, _L chat, _L bank)
          in <(DateTime, _L, _L, _L)>[
        (_at(7, 59), _L.standard, _L.sensitive, _L.critical),
        (_at(8), _L.sensitive, _L.sensitive, _L.critical),
        (_at(11, 59, 59), _L.sensitive, _L.sensitive, _L.critical),
        (_at(12), _L.critical, _L.sensitive, _L.critical),
        (_at(13, 59, 59), _L.critical, _L.sensitive, _L.critical),
        (_at(14), _L.sensitive, _L.sensitive, _L.critical),
        (_at(18), _L.standard, _L.sensitive, _L.critical),
        (_at(12, 30, 0, 7), _L.critical, _L.sensitive, _L.critical), // Sat
        (_at(10, 0, 0, 7), _L.standard, _L.sensitive, _L.critical), // Sat
      ]) {
        _now = t;
        for (final (String pkg, _L want) in <(String, _L)>[
          (_notes, notes),
          (_chat, chat),
          (_bank, bank),
        ]) {
          await fx.access.revokeImmediately(pkg);
          expect(await fx.grant(pkg), want, reason: '$pkg at $t');
          expect(
            SmartRulePolicy.effectiveLevel(
                _savedLevels[pkg]!, fx.watcher.simulatedRuleLevel(pkg, t)),
            want,
            reason: 'native fake agrees for $pkg at $t',
          );
        }
      }
      expect(await fx.saved(), _savedLevels);
      expect(fx.watcher.securityLevels, nativeLevels,
          reason: 'native baseline levels untouched by rules');
    });

    test('A/D · 33: overlapping rules survive a restart in Dart and native',
        () async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_work, _lunch]);
      final _Fx next = fx.restart();
      await next.sync();
      expect(next.watcher.receivedPolicies.last!.smartRules, hasLength(2));
      for (final (DateTime t, _L want) in <(DateTime, _L)>[
        (_at(9), _L.sensitive),
        (_at(13), _L.critical),
        (_at(19), _L.standard),
      ]) {
        _now = t;
        await next.access.revokeImmediately(_notes);
        expect(await next.grant(_notes), want, reason: '$t');
        expect(
            SmartRulePolicy.effectiveLevel(
                _L.standard, next.watcher.simulatedRuleLevel(_notes, t)),
            want);
      }
    });

    test(
        'L · 6: a stricter overlapping rule starting ends a weaker session '
        'at the next access decision', () async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_work, _lunch]);
      _now = _at(11, 59);
      expect(await fx.grant(_notes), _L.sensitive);
      expect(await fx.access.evaluate(_notes), AccessDecision.allow);
      _now = _at(12); // Lunch Banking starts (inclusive)
      expect(await fx.access.evaluate(_notes), AccessDecision.challenge);
      expect(fx.access.sessionFor(_notes), isNull);
      expect(await fx.grant(_notes), _L.critical);
    });

    test(
        'M · 7, 21: the winner ending falls back to the next strongest rule; '
        'no grace from the ended rule, Sensitive grace cap afterwards',
        () async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_work, _lunch]);
      _now = _at(13, 59);
      expect(await fx.grant(_notes), _L.critical);
      _now = _at(14, 0, 5); // Lunch Banking ended; Work Hours still applies
      await fx.access.revokeAccess(_notes); // leave
      expect(fx.access.departureAtFor(_notes), isNull,
          reason: 'a Critical unlock never turns into grace');
      expect(await fx.access.evaluate(_notes), AccessDecision.challenge);
      expect(fx.watcher.authorizedPackages, isNot(contains(_notes)));

      _now = _at(14, 1);
      expect(await fx.grant(_notes), _L.sensitive,
          reason: 'falls back to Work Hours, never to Standard');
      await fx.access.revokeAccess(_notes);
      expect(fx.access.departureAtFor(_notes), _at(14, 1, 15),
          reason: 'Sensitive grace cap (15 s), not the 30 s Standard grace');
      _now = _at(14, 1, 16);
      expect(await fx.access.evaluate(_notes), AccessDecision.challenge);
    });

    test(
        '8: no grace inheritance — a Sensitive grace never carries into a '
        'Critical overlap that starts during it', () async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_work, _lunch]);
      _now = _at(11, 59, 55);
      expect(await fx.grant(_notes), _L.sensitive);
      await fx.access.revokeAccess(_notes);
      expect(fx.access.departureAtFor(_notes), isNotNull);
      _now = _at(12, 0, 2); // within the Sensitive grace; Critical started
      expect(await fx.access.evaluate(_notes), AccessDecision.challenge);
      expect(fx.access.departureAtFor(_notes), isNull);
      expect(fx.access.sessionFor(_notes), isNull);
    });

    test(
        'N · 10, 24: deleting the winner with CR-2 confirmed falls back to the '
        'remaining overlapping rule in Dart AND native', () async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_work, _lunch]);
      expect((await fx.c.smartRules.deleteRule(_lunch.id)).isSuccess, isTrue);
      expect((await fx.sync(relax: true)).policyAck.ruleStatus,
          SmartRuleSyncStatus.applied);
      _now = _at(13);
      expect(await fx.grant(_notes), _L.sensitive);
      expect(fx.watcher.simulatedRuleLevel(_notes, _now), _L.sensitive);
      expect(await fx.saved(), _savedLevels);
    });

    test(
        'I · 23–24: deleting the winner WITHOUT CR-2 is held natively (the '
        'stricter union stays); deleting a fully covered rule is not a '
        'reduction and applies', () async {
      final _Fx fx =
          await _Fx.create(rules: <SmartRule>[_work, _lunch, _inner]);
      // Covered rule: never weaker at any minute → no CR-2 needed.
      expect(
          SmartRulePolicy.relaxedPackages(
              <SmartRule>[_work, _lunch, _inner], <SmartRule>[_work, _lunch]),
          isEmpty);
      expect((await fx.c.smartRules.deleteRule(_inner.id)).isSuccess, isTrue);
      expect(
          (await fx.sync()).policyAck.ruleStatus, SmartRuleSyncStatus.applied);

      // Winner: weaker 12:00–14:00 → a reduction.
      expect(
          SmartRulePolicy.relaxedPackages(
              <SmartRule>[_work, _lunch], <SmartRule>[_work]),
          <String>{_notes});
      expect((await fx.c.smartRules.deleteRule(_lunch.id)).isSuccess, isTrue);
      expect((await fx.sync()).policyAck.ruleStatus, SmartRuleSyncStatus.held);
      _now = _at(13);
      expect(fx.watcher.simulatedRuleLevel(_notes, _now), _L.critical,
          reason: 'native keeps enforcing the deleted winner until CR-2');
    });

    test(
        'P · 25: before the first rule read, protected apps are Critical even '
        'where overlapping rules would give less; unprotected apps unaffected',
        () async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_work, _lunch]);
      final _Fx next = fx.restart(); // no sync yet
      _now = _at(7); // no rule applies at 07:00
      expect(await next.grant(_notes), _L.critical);
      expect(await next.access.evaluate(_game), AccessDecision.allow);
      await next.access.revokeImmediately(_notes);
      await next.sync();
      expect(await next.grant(_notes), _L.standard);
      expect(await next.saved(), _savedLevels);
    });

    test(
        'Q · 26: a failed read after load keeps protected apps Critical; '
        'recovery restores the overlap result (not a stale lower level)',
        () async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_work, _lunch]);
      fx.db.failRuleReads = true;
      expect((await fx.sync()).policyAck.ruleStatus, SmartRuleSyncStatus.kept,
          reason:
              'levels still sync; no rules sent; the read is marked failed');
      expect(fx.bootstrap.lastRuleReadError, isNotNull);
      _now = _at(7);
      expect(await fx.grant(_notes), _L.critical);
      fx.db.failRuleReads = false;
      await fx.access.revokeImmediately(_notes);
      await fx.sync();
      expect(await fx.grant(_notes), _L.standard);
      _now = _at(10);
      await fx.access.revokeImmediately(_notes);
      expect(await fx.grant(_notes), _L.sensitive);
    });

    test(
        'J · 27: PIN lockout holds through overlapping rule changes; rules '
        'never reset it', () async {
      final _Fx fx = await _Fx.create();
      AuthAttemptResult? last;
      for (int i = 0; i < 5; i++) {
        last = (await fx.c.auth.authenticatePin('1357')).valueOrNull;
      }
      expect(last, isA<AuthLockedOut>());
      for (final SmartRule r in <SmartRule>[_work, _lunch]) {
        expect((await fx.c.smartRules.saveRule(r)).isSuccess, isTrue);
      }
      await fx.sync();
      expect(await fx.access.evaluate(_notes), AccessDecision.deny);
      expect((await fx.c.auth.authenticatePin(_pin)).valueOrNull,
          isA<AuthLockedOut>());
      expect(fx.access.sessionFor(_notes), isNull);
    });
  });

  group('M3 CR-2 through the Smart UI with overlapping rules (SIMULATED)', () {
    Future<void> pump(WidgetTester tester, _Fx fx) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(AppScope(
        container: fx.c,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(body: SmartScreen(clock: () => _now)),
        ),
      ));
      await tester.pumpAndSettle();
    }

    Future<void> tap(WidgetTester tester, Finder f) async {
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    Future<void> enterPin(WidgetTester tester) async {
      for (final String d in _pin.split('')) {
        await tester.tap(find.byKey(Key('pin_key_$d')));
        await tester.pumpAndSettle();
      }
    }

    Future<List<String>> ids(_Fx fx) async => (await fx.c.smartRules.getRules())
        .valueOrNull!
        .map((SmartRule r) => r.id)
        .toList()
      ..sort();

    testWidgets(
        'I/N · 9–10, 23: deleting the winner while another rule overlaps '
        'needs the PIN; cancel keeps both; PIN applies the fallback',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_work, _lunch]);
      _now = _at(13);
      await pump(tester, fx);
      await tap(tester, find.byKey(Key('smart_rule_${_lunch.id}')));
      await tap(tester, find.byKey(const Key('smart_delete')));
      await tap(tester, find.byKey(const Key('smart_delete_confirm')));
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(await ids(fx), <String>[_lunch.id, _work.id]);
      expect(fx.watcher.simulatedRuleLevel(_notes, _now), _L.critical);

      final Finder delete = find.byKey(const Key('smart_delete'));
      if (delete.evaluate().isEmpty) {
        await tap(tester, find.byKey(Key('smart_rule_${_lunch.id}')));
      }
      await tap(tester, find.byKey(const Key('smart_delete')));
      await tap(tester, find.byKey(const Key('smart_delete_confirm')));
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await enterPin(tester);
      expect(await ids(fx), <String>[_work.id]);
      expect(
          fx.watcher.receivedPolicies.last!.authorizedRuleRelaxation, isTrue);
      expect(fx.watcher.simulatedRuleLevel(_notes, _now), _L.sensitive,
          reason: 'next strongest, never Standard');
      expect(find.text(_T.deleted), findsOneWidget);
      await fx.access.revokeImmediately(_notes);
      expect(await fx.grant(_notes), _L.sensitive);
    });

    testWidgets(
        '9: deleting a rule fully covered by a stricter overlapping rule needs '
        'no PIN and is confirmed', (WidgetTester tester) async {
      final _Fx fx =
          await _Fx.create(rules: <SmartRule>[_work, _lunch, _inner]);
      _now = _at(13);
      await pump(tester, fx);
      await tap(tester, find.byKey(Key('smart_rule_${_inner.id}')));
      await tap(tester, find.byKey(const Key('smart_delete')));
      await tap(tester, find.byKey(const Key('smart_delete_confirm')));
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(await ids(fx), <String>[_lunch.id, _work.id]);
      expect(
          fx.watcher.receivedPolicies.last!.authorizedRuleRelaxation, isFalse);
      expect(fx.watcher.lastRuleStatus, SmartRuleSyncStatus.applied);
      expect(fx.watcher.simulatedRuleLevel(_notes, _now), _L.critical);
    });

    testWidgets(
        'K/M · 9: switching off the winner needs the PIN; Work Hours keeps '
        'applying afterwards', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_work, _lunch]);
      _now = _at(13);
      await pump(tester, fx);
      final Finder toggle = find.byKey(Key('smart_toggle_${_lunch.id}'));
      await tap(tester, toggle);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await enterPin(tester);
      expect(tester.widget<Switch>(toggle).value, isFalse);
      expect(fx.watcher.simulatedRuleLevel(_notes, _now), _L.sensitive);
      expect(find.text(_T.savedEnforced), findsOneWidget);
    });
  });

  group('M3 native authorization through the real app (SIMULATED)', () {
    testWidgets(
        'one PIN unlock under two overlapping rules sends exactly ONE native '
        'authorization, at the strictest level; a wrong PIN sends none',
        (WidgetTester tester) async {
      _now = _at(12, 30);
      final _Db db = _Db();
      final AppContainer c = AppContainer.inMemory(
        apps: const <AppEntry>[
          AppEntry(packageName: _notes, label: 'Notes'),
          AppEntry(packageName: _bank, label: 'Bank'),
        ],
        database: db,
        secretStore: InMemorySecretStore(),
        keyValueStore: InMemoryKeyValueStore(),
        accessibilityEnabled: true,
        overlayGranted: true,
        accessClock: () => _now,
      );
      await c.auth.enrollPin(_pin);
      for (final MapEntry<String, _L> e in <String, _L>{
        _notes: _L.standard,
        _bank: _L.critical,
      }.entries) {
        await c.protectedApps.add(ProtectedApp(
          packageName: e.key,
          label: e.key,
          addedAt: DateTime(2026, 11, 1),
          securityLevel: e.value,
        ));
      }
      await c.lockSettings.setGracePeriod(const Duration(seconds: 30));
      for (final SmartRule r in <SmartRule>[_work, _lunch]) {
        expect((await c.smartRules.saveRule(r)).isSuccess, isTrue);
      }
      final StaticWatcherService watcher = c.watcher as StaticWatcherService;
      watcher.ruleClock = () => _now;
      watcher
        ..protectionConfigured = true
        ..running = true
        ..accessibilityServiceConnected = true
        ..shieldArmed = true
        ..challengePending = false
        ..backgroundRestricted = false
        ..powerSaveMode = false
        ..ignoringBatteryOptimizations = false
        ..sdkInt = 34;
      tester.view.physicalSize = const Size(1080, 6000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(c.capabilityMonitor.dispose);
      await tester.pumpWidget(SmartAppLockApp(container: c));
      await tester.pumpAndSettle();
      await c.protectionBootstrap.synchronize();
      await tester.pumpAndSettle();
      watcher.authorizePackageCalls = 0;
      watcher.authorizeLevelFloors.clear();

      Future<void> pin(String digits) async {
        for (final String d in digits.split('')) {
          await tester.tap(find.byKey(Key('pin_key_$d')));
          await tester.pump();
        }
        await tester.pumpAndSettle();
      }

      (c.accessibility as StaticAccessibilityLockService)
          .emitForegroundPackage(_notes);
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await pin('1357');
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(watcher.authorizePackageCalls, 0,
          reason: 'a wrong PIN never reaches native authorization');

      await pin(_pin);
      expect(find.byType(PinUnlockScreen), findsNothing);
      await tester.pumpAndSettle();
      expect(watcher.authorizePackageCalls, 1,
          reason: 'two matching rules never mean two authorizations');
      expect(watcher.authorizeLevelFloors, <String, _L?>{_notes: _L.critical});
      expect(
          (c.accessController as DefaultAccessController)
              .sessionFor(_notes)
              ?.securityLevel,
          _L.critical);
    });
  });

  group('T / R · 30–31: one engine, read-only diagnostics (static)', () {
    String read(String path) => File(path).readAsStringSync();

    test('the legacy LockRule/RuleEngine is not a second Smart Rule engine',
        () {
      final List<String> users = <String>[
        for (final FileSystemEntity f
            in Directory('lib').listSync(recursive: true))
          if (f is File &&
              f.path.endsWith('.dart') &&
              read(f.path).contains('rule_engine.dart'))
            f.path,
      ];
      expect(users, isEmpty, reason: 'nothing in lib/ uses RuleEngine');
      for (final String path in <String>[
        'lib/protection/impl/default_access_controller.dart',
        'lib/protection/protection_bootstrap.dart',
        'lib/rules/smart_rule_policy.dart',
        'lib/rules/smart_rule_conflict.dart',
        'lib/rules/smart_rule_diagnostics.dart',
        'lib/ui/screens/smart/smart_rule_details.dart',
        'lib/ui/screens/smart/smart_screen.dart',
      ]) {
        final String src = read(path);
        expect(src.contains('lock_rule.dart'), isFalse, reason: path);
        expect(src.contains('rule_engine.dart'), isFalse, reason: path);
      }
    });

    test(
        'diagnostics code reaches no credentials, sessions, secrets or '
        'native authorization', () {
      for (final String path in <String>[
        'lib/rules/smart_rule_conflict.dart',
        'lib/rules/smart_rule_diagnostics.dart',
        'lib/ui/screens/smart/smart_rule_details.dart',
      ]) {
        final String src = read(path);
        for (final String banned in <String>[
          'security/credentials',
          'security/storage',
          'secret_store',
          'lock_session',
          'authorizePackage',
          'grantAccess',
          'revoke',
          'configureProtection',
          'synchronize(',
          'saveRule',
          'deleteRule',
          'setRuleEnabled',
          'replaceRules',
          'Timer',
          'Stream.periodic',
        ]) {
          expect(src.contains(banned), isFalse, reason: '$path uses $banned');
        }
      }
    });
  });
}
