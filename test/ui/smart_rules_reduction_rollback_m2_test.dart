// Phase 10 / M2 — native persistence gate, Option A: a PIN-confirmed rule
// reduction that native does not durably acknowledge is rolled back in app
// storage and the previous (stricter) rules are re-sent.
//
// SIMULATED: production SmartScreen / SmartRuleEditorScreen, the change flow,
// the CR-2 gate, SmartRuleRepositoryImpl, access controller and protection
// bootstrap over AppContainer.inMemory. "Native" is the static watcher with
// per-call storage faults (failBeforeApply / failAfterApply mirror the
// native failed-commit paths of ProtectionStateStore.kt). No device.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/impl/smart_rule_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/smart_rule_repository.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/watcher_service.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/smart/smart_rule_editor_screen.dart';
import 'package:smart_app_lock/ui/screens/smart/smart_rule_presentation.dart';
import 'package:smart_app_lock/ui/screens/smart/smart_screen.dart';

typedef _L = AppSecurityLevel;
typedef _T = SmartRuleText;

const String _pin = '2468';
const String _notes = 'com.example.notes'; // protected, Standard
const String _bank = 'com.example.bank'; // protected, Critical

/// Monday 2026-11-02 12:00 local.
final DateTime _now = DateTime(2026, 11, 2, 12);

class _Db extends InMemoryLocalDatabase {
  bool failRuleWrites = false;
  int ruleWrites = 0;

  @override
  Future<void> setSetting(String key, String value) {
    if (key == SmartRuleRepositoryImpl.storageKey) {
      ruleWrites++;
      if (failRuleWrites) throw StateError('simulated rule write failure');
    }
    return super.setSetting(key, value);
  }
}

class _Fx {
  _Fx(this.c, this.db);

  final AppContainer c;
  final _Db db;

  StaticWatcherService get watcher => c.watcher as StaticWatcherService;
  DefaultAccessController get access =>
      c.accessController as DefaultAccessController;

  static Future<_Fx> create() async {
    final _Db db = _Db();
    final AppContainer c = AppContainer.inMemory(
      apps: const <AppEntry>[
        AppEntry(packageName: _notes, label: 'Notes'),
        AppEntry(packageName: _bank, label: 'Bank'),
      ],
      database: db,
      accessClock: () => _now,
    );
    await c.auth.enrollPin(_pin);
    await c.protectedApps.add(ProtectedApp(
      packageName: _notes,
      label: 'Notes',
      addedAt: DateTime(2026, 11, 1),
    ));
    await c.protectedApps.add(ProtectedApp(
      packageName: _bank,
      label: 'Bank',
      addedAt: DateTime(2026, 11, 1),
      securityLevel: _L.critical,
    ));
    (c.watcher as StaticWatcherService).ruleClock = () => _now;
    await c.protectionBootstrap.synchronize();
    return _Fx(c, db);
  }

  Future<List<SmartRule>> rules() async =>
      (await c.smartRules.getRules()).valueOrNull!;

  Future<void> seed(List<SmartRule> rules) async {
    for (final SmartRule r in rules) {
      expect((await c.smartRules.saveRule(r)).isSuccess, isTrue);
    }
    final ack = (await c.protectionBootstrap.synchronize()).valueOrNull!;
    expect(ack.policyAck.ruleStatus, SmartRuleSyncStatus.applied);
    db.ruleWrites = 0;
  }

  /// Faults only the snapshot that carries the CR-2 relaxation flag.
  void failReduction(StaticConfigureFault fault, {void Function()? also}) {
    watcher.configureFault = (ProtectionPolicySnapshot? p) {
      if (p?.authorizedRuleRelaxation != true) return null;
      also?.call();
      return fault;
    };
  }

  /// Flagged snapshots sent so far.
  int get flaggedSnapshots => watcher.receivedPolicies
      .where(
          (ProtectionPolicySnapshot? p) => p?.authorizedRuleRelaxation == true)
      .length;
}

SmartRule _rule({
  String id = 'r1',
  String name = 'Work',
  List<String> targets = const <String>[_notes],
  List<int> days = SmartRuleDays.everyDay,
  SmartRuleTime time = const SmartRuleTime.allDay(),
  SmartRuleAction action = SmartRuleAction.critical,
}) =>
    SmartRule(
      id: id,
      name: name,
      targetPackages: targets,
      days: days,
      time: time,
      action: action,
    );

Future<void> _pump(WidgetTester tester, _Fx fx) async {
  tester.view.physicalSize = const Size(800, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    AppScope(
      container: fx.c,
      child: MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(body: SmartScreen(clock: () => _now)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _enterPin(WidgetTester tester) async {
  expect(find.byType(PinUnlockScreen), findsOneWidget);
  for (final String d in _pin.split('')) {
    await tester.tap(find.byKey(Key('pin_key_$d')));
    await tester.pumpAndSettle();
  }
}

/// No success or "nothing changed" wording of any kind is on screen.
void _expectNoSuccessClaim() {
  for (final String s in <String>[
    _T.savedEnforced,
    _T.savedUnchanged,
    _T.savedHeld,
    _T.savedUnconfirmed,
    _T.deleted,
    _T.saveFailed, // "… Nothing was changed. …"
  ]) {
    expect(find.text(s), findsNothing, reason: s);
  }
  expect(find.textContaining('Nothing was changed'), findsNothing);
}

void main() {
  group('Option A: failed reduction rollback (SIMULATED)', () {
    testWidgets(
        'A. a PIN-confirmed reduction that native durably acknowledges is '
        'saved and confirmed', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await fx.seed(<SmartRule>[_rule()]);
      await _pump(tester, fx);
      await _tap(tester, find.byKey(const Key('smart_toggle_r1')));
      await _enterPin(tester);
      expect((await fx.rules()).single.enabled, isFalse);
      expect(fx.flaggedSnapshots, 1);
      expect(fx.watcher.simulatedRuleLevel(_notes, _now), isNull);
      expect(find.text(_T.savedEnforced), findsOneWidget);
    });

    for (final StaticConfigureFault fault in StaticConfigureFault.values) {
      testWidgets(
          '${fault == StaticConfigureFault.failBeforeApply ? 'B' : 'C'}/E/H/I. '
          'disable: native $fault → previous rules restored in app storage, '
          're-sent WITHOUT the flag, never reported as saved',
          (WidgetTester tester) async {
        final _Fx fx = await _Fx.create();
        final SmartRule rule = _rule();
        await fx.seed(<SmartRule>[rule]);
        await _pump(tester, fx);
        fx.failReduction(fault);

        await _tap(tester, find.byKey(const Key('smart_toggle_r1')));
        await _enterPin(tester);

        // E: the previous configuration is back in app storage.
        expect(await fx.rules(), <SmartRule>[rule]);
        expect(fx.db.ruleWrites, 2, reason: 'reduction, then the restore');
        expect(
          tester.widget<Switch>(find.byKey(const Key('smart_toggle_r1'))).value,
          isTrue,
        );
        // F (Dart side): the stricter rules were re-sent, without the flag.
        final ProtectionPolicySnapshot last = fx.watcher.receivedPolicies.last!;
        expect(last.authorizedRuleRelaxation, isFalse);
        expect(last.smartRules, hasLength(1));
        expect(fx.flaggedSnapshots, 1);
        // Native (simulated) keeps the rule in force.
        expect(fx.watcher.simulatedRuleLevel(_notes, _now), _L.critical);
        expect(fx.watcher.lastRuleStatus, SmartRuleSyncStatus.applied);
        // I: accurate feedback, no success claim.
        expect(find.text(_T.reductionRolledBack), findsOneWidget);
        expect(find.text(_T.reductionRollbackFailed), findsNothing);
        _expectNoSuccessClaim();
        // Never grants a session or grace.
        expect(fx.access.sessionFor(_notes), isNull);
        expect(fx.watcher.authorizedPackages, isEmpty);
      });
    }

    testWidgets(
        'D/J. the restore itself fails → explicit rollback failure; never '
        '"will be restored", "Saved" or "Nothing was changed"',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await fx.seed(<SmartRule>[_rule()]);
      await _pump(tester, fx);
      fx.failReduction(
        StaticConfigureFault.failAfterApply,
        also: () => fx.db.failRuleWrites = true,
      );

      await _tap(tester, find.byKey(const Key('smart_toggle_r1')));
      await _enterPin(tester);

      expect(find.text(_T.reductionRollbackFailed), findsOneWidget);
      expect(find.text(_T.reductionRolledBack), findsNothing);
      _expectNoSuccessClaim();
      // Honest state: app storage still holds the reduced rule (shown as
      // off); native (simulated) keeps the stricter union in force.
      expect((await fx.rules()).single.enabled, isFalse);
      expect(fx.watcher.simulatedRuleLevel(_notes, _now), _L.critical);
      expect(fx.flaggedSnapshots, 1);
      expect(fx.watcher.receivedPolicies.last!.authorizedRuleRelaxation, isTrue,
          reason: 'no further (unflagged) snapshot after a failed restore');
    });

    testWidgets(
        'E. deleting the middle of three rules: the exact previous list and '
        'order are restored; the editor stays open with its message',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      final List<SmartRule> seeded = <SmartRule>[
        _rule(id: 'a', name: 'First'),
        _rule(id: 'b', name: 'Second', targets: const <String>[_bank]),
        _rule(id: 'c', name: 'Third', action: SmartRuleAction.sensitive),
      ];
      await fx.seed(seeded);
      await _pump(tester, fx);
      fx.failReduction(StaticConfigureFault.failBeforeApply);

      await _tap(tester, find.byKey(const Key('smart_rule_a')));
      await _tap(tester, find.byKey(const Key('smart_delete')));
      await _tap(tester, find.byKey(const Key('smart_delete_confirm')));
      await _enterPin(tester);

      expect(await fx.rules(), seeded);
      expect(find.byType(SmartRuleEditorScreen), findsOneWidget);
      expect(find.text(_T.reductionRolledBack), findsOneWidget);
      _expectNoSuccessClaim();
      expect(fx.watcher.simulatedRuleLevel(_notes, _now), _L.critical);
    });

    testWidgets(
        'draft kept for retry: a rolled-back edit keeps the form; a retry '
        'asks for the PIN again and is confirmed only on a durable ack',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      final SmartRule rule = _rule();
      await fx.seed(<SmartRule>[rule]);
      await _pump(tester, fx);
      fx.failReduction(StaticConfigureFault.failAfterApply);

      await _tap(tester, find.byKey(const Key('smart_rule_r1')));
      await _tap(tester, find.byKey(const Key('smart_day_7'))); // Sun off
      await _tap(tester, find.byKey(const Key('smart_save')));
      await _enterPin(tester);

      expect(find.byType(SmartRuleEditorScreen), findsOneWidget);
      expect(find.text(_T.reductionRolledBack), findsOneWidget);
      expect(await fx.rules(), <SmartRule>[rule]);
      // The draft (Sunday unselected) is still in the form.
      expect(
        tester
            .widget<FilterChip>(find.byKey(const Key('smart_day_7')))
            .selected,
        isFalse,
      );

      fx.watcher.configureFault = null;
      await _tap(tester, find.byKey(const Key('smart_save')));
      await _enterPin(tester);
      expect(find.byType(SmartRuleEditorScreen), findsNothing);
      expect((await fx.rules()).single.days, <int>[1, 2, 3, 4, 5, 6]);
      expect(fx.flaggedSnapshots, 2);
      expect(find.text(_T.savedEnforced), findsOneWidget);
    });

    testWidgets(
        'H. without the PIN nothing is relaxed: cancel writes nothing and '
        'sends no flagged snapshot', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await fx.seed(<SmartRule>[_rule()]);
      await _pump(tester, fx);
      fx.failReduction(StaticConfigureFault.failAfterApply);
      await _tap(tester, find.byKey(const Key('smart_toggle_r1')));
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(fx.db.ruleWrites, 0);
      expect(fx.flaggedSnapshots, 0);
      expect((await fx.rules()).single.enabled, isTrue);
      expect(fx.watcher.simulatedRuleLevel(_notes, _now), _L.critical);
    });
  });

  group('replaceRules (whole-list compare-and-swap)', () {
    test('restores the exact list and order; identical list writes nothing',
        () async {
      final _Db db = _Db();
      final SmartRuleRepository repo = SmartRuleRepositoryImpl(db);
      final List<SmartRule> a = <SmartRule>[
        _rule(id: 'x'),
        _rule(id: 'y', name: 'Y'),
      ];
      for (final SmartRule r in a) {
        await repo.saveRule(r);
      }
      final List<SmartRule> reduced = <SmartRule>[a[1]];
      expect((await repo.deleteRule('x')).isSuccess, isTrue);
      expect((await repo.replaceRules(a, expected: reduced)).isSuccess, isTrue);
      expect((await repo.getRules()).valueOrNull, a);
      final int writes = db.ruleWrites;
      expect((await repo.replaceRules(a, expected: a)).isSuccess, isTrue);
      expect(db.ruleWrites, writes);
    });

    test('a changed list is a conflict and writes nothing', () async {
      final _Db db = _Db();
      final SmartRuleRepository repo = SmartRuleRepositoryImpl(db);
      await repo.saveRule(_rule(id: 'x'));
      final int writes = db.ruleWrites;
      final result = await repo.replaceRules(
        <SmartRule>[_rule(id: 'x'), _rule(id: 'y')],
        expected: const <SmartRule>[],
      );
      expect(result.isFailure, isTrue);
      expect((result.errorOrNull! as SmartRuleStoreException).kind,
          SmartRuleStoreErrorKind.conflict);
      expect(db.ruleWrites, writes);
      expect((await repo.getRules()).valueOrNull, <SmartRule>[_rule(id: 'x')]);
    });

    test('a failed write is reported and never saved', () async {
      final _Db db = _Db();
      final SmartRuleRepository repo = SmartRuleRepositoryImpl(db);
      await repo.saveRule(_rule(id: 'x'));
      db.failRuleWrites = true;
      final result = await repo.replaceRules(
        const <SmartRule>[],
        expected: <SmartRule>[_rule(id: 'x')],
      );
      expect(result.isFailure, isTrue);
      expect((result.errorOrNull! as SmartRuleStoreException).kind,
          SmartRuleStoreErrorKind.writeFailed);
      db.failRuleWrites = false;
      expect((await repo.getRules()).valueOrNull, <SmartRule>[_rule(id: 'x')]);
    });
  });

  group('confirmHeldRuleRelaxation durability (SIMULATED)', () {
    /// Native holds the earlier, stricter rule (r1 enabled) while app
    /// storage has the unconfirmed reduction (r1 disabled).
    Future<_Fx> held(WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await fx.seed(<SmartRule>[_rule()]);
      expect(
          (await fx.c.smartRules.setRuleEnabled('r1', enabled: false))
              .isSuccess,
          isTrue);
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.watcher.lastRuleStatus, SmartRuleSyncStatus.held);
      await _pump(tester, fx);
      expect(find.byKey(const Key('smart_rules_held')), findsOneWidget);
      return fx;
    }

    void expectNoConfirmation() {
      expect(find.text(_T.heldConfirmed), findsNothing);
      expect(find.textContaining('Nothing was changed'), findsNothing);
    }

    testWidgets(
        'CH-1. a confirmation write that lands but reports failure is not '
        'confirmed; the unflagged re-sync makes native re-hold the stricter '
        'rules before "still apply" is shown', (WidgetTester tester) async {
      final _Fx fx = await held(tester);
      fx.failReduction(StaticConfigureFault.failAfterApply);
      await _tap(tester, find.byKey(const Key('smart_rules_held_confirm')));
      await _enterPin(tester);

      expect(fx.flaggedSnapshots, 1);
      final ProtectionPolicySnapshot? last = fx.watcher.receivedPolicies.last;
      expect(last?.authorizedRuleRelaxation, isFalse);
      expect(fx.watcher.lastRuleStatus, SmartRuleSyncStatus.held);
      expect(fx.watcher.simulatedRuleLevel(_notes, _now), _L.critical);
      expect(find.text(_T.heldNotConfirmed), findsOneWidget);
      expectNoConfirmation();
      expect(find.byKey(const Key('smart_rules_held')), findsOneWidget);
      expect(fx.access.sessionFor(_notes), isNull);
      expect(fx.watcher.authorizedPackages, isEmpty);
      // App storage keeps the user's saved rules (no silent change).
      expect((await fx.rules()).single.enabled, isFalse);
    });

    testWidgets(
        'CH-2. confirmation AND re-sync both fail: neither the current nor '
        'the earlier rules are claimed to apply', (WidgetTester tester) async {
      final _Fx fx = await held(tester);
      fx.watcher.configureFault =
          (ProtectionPolicySnapshot? p) => StaticConfigureFault.failBeforeApply;
      await _tap(tester, find.byKey(const Key('smart_rules_held_confirm')));
      await _enterPin(tester);

      expect(fx.flaggedSnapshots, 1);
      expect(find.text(_T.heldUnknown), findsOneWidget);
      expect(find.text(_T.heldNotConfirmed), findsNothing);
      expectNoConfirmation();
      expect(fx.watcher.simulatedRuleLevel(_notes, _now), _L.critical);
      expect(fx.access.sessionFor(_notes), isNull);
      expect(fx.watcher.authorizedPackages, isEmpty);
    });

    testWidgets(
        'CH-3. without the PIN nothing is confirmed: cancel sends no flagged '
        'snapshot and native keeps the stricter rules',
        (WidgetTester tester) async {
      final _Fx fx = await held(tester);
      await _tap(tester, find.byKey(const Key('smart_rules_held_confirm')));
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(fx.flaggedSnapshots, 0);
      expectNoConfirmation();
      expect(fx.watcher.simulatedRuleLevel(_notes, _now), _L.critical);
      expect(find.byKey(const Key('smart_rules_held')), findsOneWidget);
    });
  });
}
