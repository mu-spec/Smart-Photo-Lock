// Phase 10 / M2 (PRD 10G–10I): the Smart Rules list and editor, the
// unsaved-draft guard, enable/disable, CR-2 for reductions, stale forms,
// held-rule confirmation, accessibility and layout.
//
// SIMULATED: production SmartScreen / SmartRuleEditorScreen, the CR-2 gate,
// SmartRuleRepositoryImpl, credential manager, access controller and
// protection bootstrap over AppContainer.inMemory. "Native" is the static
// watcher (rule resolution mirrors SmartRulePolicy.kt). No device.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/impl/smart_rule_repository_impl.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/access_controller.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/watcher_service.dart';
import 'package:smart_app_lock/ui/screens/apps/unprotect_gate.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/smart/smart_rule_editor_screen.dart';
import 'package:smart_app_lock/ui/screens/smart/smart_rule_presentation.dart';
import 'package:smart_app_lock/ui/screens/smart/smart_screen.dart';
import 'package:smart_app_lock/utilities/result.dart';

typedef _L = AppSecurityLevel;
typedef _T = SmartRuleText;

const String _pin = '2468';
const String _notes = 'com.example.notes'; // protected, Standard
const String _bank = 'com.example.bank'; // protected, Critical
const String _game = 'com.example.game'; // installed, NOT protected

/// Monday 2026-11-02 12:00 local.
final DateTime _now = DateTime(2026, 11, 2, 12);

class _Db extends InMemoryLocalDatabase {
  bool failRuleReads = false;
  bool failRuleWrites = false;
  int ruleWrites = 0;

  @override
  Future<String?> getSetting(String key) {
    if (failRuleReads && key == SmartRuleRepositoryImpl.storageKey) {
      throw StateError('simulated rule read failure');
    }
    return super.getSetting(key);
  }

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

  static Future<_Fx> create({String? rawRules}) async {
    final _Db db = _Db();
    if (rawRules != null) {
      await db.setSetting(SmartRuleRepositoryImpl.storageKey, rawRules);
      db.ruleWrites = 0;
    }
    final AppContainer c = AppContainer.inMemory(
      apps: const <AppEntry>[
        AppEntry(packageName: _notes, label: 'Notes'),
        AppEntry(packageName: _bank, label: 'Bank'),
        AppEntry(packageName: _game, label: 'Game'),
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
    if (rawRules == null) await c.protectionBootstrap.synchronize();
    return _Fx(c, db);
  }

  Future<List<SmartRule>> rules() async =>
      (await c.smartRules.getRules()).valueOrNull!;

  /// Saves [rule] and syncs it to native (as a prior session would have).
  Future<void> seed(SmartRule rule) async {
    expect((await c.smartRules.saveRule(rule)).isSuccess, isTrue);
    final ack = (await c.protectionBootstrap.synchronize()).valueOrNull!;
    expect(ack.policyAck.ruleStatus, SmartRuleSyncStatus.applied);
    db.ruleWrites = 0;
  }
}

SmartRule _rule({
  String id = 'r1',
  String name = 'Work',
  List<String> targets = const <String>[_notes],
  List<int> days = SmartRuleDays.weekdays,
  SmartRuleTime? time,
  SmartRuleAction action = SmartRuleAction.critical,
  bool enabled = true,
}) =>
    SmartRule(
      id: id,
      name: name,
      targetPackages: targets,
      days: days,
      time: time ?? SmartRuleTime.window(startMinute: 540, endMinute: 1020),
      action: action,
      enabled: enabled,
    );

final List<TimeOfDay> _times = <TimeOfDay>[];

Future<TimeOfDay?> _pickTime(BuildContext _, TimeOfDay initial) async =>
    _times.isEmpty ? null : _times.removeAt(0);

Future<void> _pump(
  WidgetTester tester,
  _Fx fx, {
  Size size = const Size(800, 2600),
  double textScale = 1,
  ThemeData? theme,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  _times.clear();
  await tester.pumpWidget(
    AppScope(
      container: fx.c,
      child: MaterialApp(
        theme: theme ?? AppTheme.dark,
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: SmartScreen(pickTime: _pickTime, clock: () => _now),
        ),
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

Future<void> _enterPin(WidgetTester tester, String pin) async {
  for (final String d in pin.split('')) {
    await tester.tap(find.byKey(Key('pin_key_$d')));
    await tester.pumpAndSettle();
  }
}

Future<void> _openCreate(WidgetTester tester) async {
  await _tap(tester, find.byKey(const Key('smart_create')));
  expect(find.byType(SmartRuleEditorScreen), findsOneWidget);
}

Future<void> _fill(
  WidgetTester tester, {
  String? name,
  List<String> apps = const <String>[],
  List<int> days = const <int>[],
  SmartRuleAction? level,
}) async {
  if (name != null) {
    await tester.enterText(find.byKey(const Key('smart_name')), name);
    await tester.pumpAndSettle();
  }
  for (final String a in apps) {
    await _tap(tester, find.byKey(Key('smart_app_$a')));
  }
  for (final int d in days) {
    await _tap(tester, find.byKey(Key('smart_day_$d')));
  }
  if (level != null) {
    await _tap(tester, find.byKey(Key('smart_level_${level.storageId}')));
  }
}

Future<void> _systemBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

void main() {
  group('33. list states (SIMULATED)', () {
    testWidgets('empty: heading, intro, empty card, Create enabled',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pump(tester, fx);
      expect(find.text(_T.heading), findsOneWidget);
      expect(find.text(SmartScreen.description), findsOneWidget);
      expect(find.byKey(const Key('smart_rules_empty')), findsOneWidget);
      expect(find.text(_T.emptyTitle), findsOneWidget);
      expect(find.text(_T.create), findsOneWidget);
    });

    testWidgets('a read failure is an error with Retry, never an empty list',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await fx.seed(_rule());
      fx.db.failRuleReads = true;
      await _pump(tester, fx);
      expect(find.byKey(const Key('smart_rules_error_storageUnavailable')),
          findsOneWidget);
      expect(find.text(_T.loadFailed), findsOneWidget);
      expect(find.byKey(const Key('smart_rules_empty')), findsNothing);
      await _tap(tester, find.byKey(const Key('smart_create')));
      expect(find.byType(SmartRuleEditorScreen), findsNothing,
          reason: 'nothing can be created over an unread document');

      fx.db.failRuleReads = false;
      await _tap(tester, find.byKey(const Key('smart_rules_retry')));
      expect(find.byKey(const Key('smart_rule_r1')), findsOneWidget);
    });

    testWidgets('corrupt and newer-version data stay visible as such',
        (WidgetTester tester) async {
      for (final (String raw, String key, String text)
          in <(String, String, String)>[
        ('{"schema":"smart_rules","vers', 'corrupt', _T.corrupt),
        (
          '{"schema":"smart_rules","version":4,"rules":[]}',
          'unsupportedVersion',
          _T.unsupported
        ),
      ]) {
        final _Fx fx = await _Fx.create(rawRules: raw);
        await _pump(tester, fx);
        expect(find.byKey(Key('smart_rules_error_$key')), findsOneWidget);
        expect(find.text(text), findsOneWidget);
        expect(find.byKey(const Key('smart_rules_empty')), findsNothing);
        expect(fx.db.ruleWrites, 0);
        expect(
          await fx.db.getSetting(SmartRuleRepositoryImpl.storageKey),
          raw,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('a row shows enabled state, apps, days, time and level',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await fx.seed(_rule(targets: <String>[_notes, _bank]));
      await fx.seed(_rule(
        id: 'r2',
        name: 'Night',
        days: SmartRuleDays.everyDay,
        time: SmartRuleTime.window(startMinute: 1320, endMinute: 360),
        action: SmartRuleAction.sensitive,
        enabled: false,
      ));
      await _pump(tester, fx);
      final Finder r1 = find.byKey(const Key('smart_rule_r1'));
      expect(
          find.descendant(of: r1, matching: find.text('Work')), findsOneWidget);
      expect(find.descendant(of: r1, matching: find.text('Bank, Notes')),
          findsOneWidget);
      expect(
          find.descendant(
              of: r1, matching: find.text('Weekdays · 09:00–17:00')),
          findsOneWidget);
      expect(find.descendant(of: r1, matching: find.text('Critical')),
          findsOneWidget);
      expect(
          find.descendant(of: r1, matching: find.text('On')), findsOneWidget);
      final Finder r2 = find.byKey(const Key('smart_rule_r2'));
      expect(
        find.descendant(
            of: r2, matching: find.text('Every day · 22:00–06:00 (next day)')),
        findsOneWidget,
      );
      expect(find.descendant(of: r2, matching: find.text('At least Sensitive')),
          findsOneWidget);
      expect(
          find.descendant(of: r2, matching: find.text('Off')), findsOneWidget);
      // No "active now" claims anywhere.
      expect(find.textContaining('Active'), findsNothing);
    });
  });

  group('34–37. create flow and validation (SIMULATED)', () {
    testWidgets(
        '34. create: name → apps → days → time → level → review → '
        'save; stored, sent to native, "Saved" only after the ack',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pump(tester, fx);
      await _openCreate(tester);
      await _fill(tester,
          name: '  Night banking ',
          apps: <String>[_notes],
          days: <int>[1, 7],
          level: SmartRuleAction.critical);
      _times.addAll(const <TimeOfDay>[
        TimeOfDay(hour: 22, minute: 0),
        TimeOfDay(hour: 6, minute: 30),
      ]);
      await _tap(tester, find.byKey(const Key('smart_start')));
      await _tap(tester, find.byKey(const Key('smart_end')));
      expect(find.text('06:30 (next day)'), findsOneWidget);
      final Finder review = find.byKey(const Key('smart_review'));
      expect(find.descendant(of: review, matching: find.text('Night banking')),
          findsOneWidget);
      expect(
        find.descendant(
            of: review,
            matching: find.text('When: Mon, Sun · 22:00–06:30 (next day)')),
        findsOneWidget,
      );

      await _tap(tester, find.byKey(const Key('smart_save')));
      expect(find.byType(PinUnlockScreen), findsNothing,
          reason: 'adding protection needs no confirmation');
      expect(find.byType(SmartRuleEditorScreen), findsNothing);
      final SmartRule saved = (await fx.rules()).single;
      expect(saved.name, 'Night banking');
      expect(saved.targetPackages, <String>[_notes]);
      expect(saved.days, <int>[1, 7]);
      expect(
          saved.time, SmartRuleTime.window(startMinute: 1320, endMinute: 390));
      expect(saved.action, SmartRuleAction.critical);
      expect(saved.enabled, isTrue);
      expect(fx.watcher.lastRuleStatus, SmartRuleSyncStatus.applied);
      expect(
          fx.watcher.receivedPolicies.last!.authorizedRuleRelaxation, isFalse,
          reason: 'adding protection never carries relaxation authority');
      expect(fx.watcher.smartRules.single['level'], 'critical');
      expect(find.text(_T.savedEnforced), findsOneWidget);
      expect(find.byKey(Key('smart_rule_${saved.id}')), findsOneWidget);
    });

    testWidgets('34b. native not confirming → "Saved, but…", never enforced',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pump(tester, fx);
      fx.watcher.configureError = StateError('bridge down');
      await _openCreate(tester);
      await _fill(tester,
          name: 'Bank',
          apps: <String>[_notes],
          days: <int>[1],
          level: SmartRuleAction.sensitive);
      await _tap(tester, find.byKey(const Key('smart_save')));
      expect((await fx.rules()), hasLength(1));
      expect(find.text(_T.savedUnconfirmed), findsOneWidget);
      expect(find.text(_T.savedEnforced), findsNothing);
      expect(fx.watcher.smartRules, isEmpty);
    });

    testWidgets(
        '35. validation: blank name, no apps, no days, zero-length '
        'window, no level — nothing saved or sent',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pump(tester, fx);
      final int configures = fx.watcher.configureCalls;
      await _openCreate(tester);
      await tester.enterText(find.byKey(const Key('smart_name')), '   ');
      _times.addAll(const <TimeOfDay>[TimeOfDay(hour: 17, minute: 0)]);
      await _tap(tester, find.byKey(const Key('smart_start'))); // 17:00–17:00
      await _tap(tester, find.byKey(const Key('smart_save')));
      expect(find.text(_T.nameRequired), findsOneWidget);
      expect(find.byKey(const Key('smart_apps_error')), findsOneWidget);
      expect(find.byKey(const Key('smart_days_error')), findsOneWidget);
      expect(find.byKey(const Key('smart_time_error')), findsOneWidget);
      expect(find.byKey(const Key('smart_level_error')), findsOneWidget);
      expect(find.byType(SmartRuleEditorScreen), findsOneWidget);
      expect(fx.db.ruleWrites, 0);
      expect(fx.watcher.configureCalls, configures);

      // All day clears the window error; the rest still block.
      await _tap(tester, find.byKey(const Key('smart_all_day')));
      expect(find.byKey(const Key('smart_time_error')), findsNothing);
      await tester.enterText(find.byKey(const Key('smart_name')),
          'x' * (SmartRule.maxNameLength + 1));
      await tester.pumpAndSettle();
      expect(find.text(_T.nameTooLong), findsOneWidget);
      expect(fx.db.ruleWrites, 0);
    });

    testWidgets(
        '36. only protected apps can be chosen; an old target that is '
        'no longer protected stays visible with a note',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await fx.seed(_rule(targets: <String>[_notes, _game]));
      await _pump(tester, fx);
      await _openCreate(tester);
      expect(find.byKey(const Key('smart_app_$_notes')), findsOneWidget);
      expect(find.byKey(const Key('smart_app_$_bank')), findsOneWidget);
      expect(find.byKey(const Key('smart_app_$_game')), findsNothing);
      await _systemBack(tester);

      await _tap(tester, find.byKey(const Key('smart_rule_r1')));
      expect(find.byKey(const Key('smart_app_$_game')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('smart_app_$_game')),
          matching: find.text(_T.notProtectedNote),
        ),
        findsOneWidget,
      );
    });

    testWidgets(
        '37. Unlocked is shown as not available and cannot be chosen; '
        'weaker-than-baseline requests are explained',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pump(tester, fx);
      await _openCreate(tester);
      final Finder unlocked = find.byKey(const Key('smart_level_unlocked'));
      expect(tester.widget<ListTile>(unlocked).enabled, isFalse);
      expect(find.text(_T.actionDescription(SmartRuleAction.unlocked)),
          findsOneWidget);
      await _fill(tester, name: 'X', apps: <String>[_bank], days: <int>[1]);
      await _tap(tester, unlocked);
      await _tap(tester, find.byKey(const Key('smart_save')));
      expect(find.byKey(const Key('smart_level_error')), findsOneWidget,
          reason: 'tapping Unlocked selected nothing');
      expect(fx.db.ruleWrites, 0);

      await _tap(tester, find.byKey(const Key('smart_level_sensitive')));
      expect(find.text('Bank: already Critical, no change'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('smart_level_standard')));
      expect(find.text('Bank: no change (stays Critical)'), findsOneWidget);
      expect(find.text(_T.actionDescription(SmartRuleAction.standard)),
          findsOneWidget);
    });
  });

  group('38. enable / disable (SIMULATED)', () {
    testWidgets(
        'disabling a raising rule needs the PIN; cancel changes '
        'nothing; the switch follows storage', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await fx.seed(_rule(
          time: const SmartRuleTime.allDay(), days: SmartRuleDays.everyDay));
      await _pump(tester, fx);
      final Finder toggle = find.byKey(const Key('smart_toggle_r1'));

      await _tap(tester, toggle);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(find.text(relaxRuleConfirmTitle), findsOneWidget);
      expect(fx.db.ruleWrites, 0, reason: 'nothing saved before the PIN');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect((await fx.rules()).single.enabled, isTrue);
      expect(tester.widget<Switch>(toggle).value, isTrue);
      expect(fx.watcher.simulatedRuleLevel(_notes, _now), _L.critical);
      expect(find.text(_T.denied(UnprotectDenial.notAuthenticated)),
          findsOneWidget);

      await _tap(tester, toggle);
      await _enterPin(tester, _pin);
      expect((await fx.rules()).single.enabled, isFalse);
      expect(tester.widget<Switch>(toggle).value, isFalse);
      expect(
          fx.watcher.receivedPolicies.last!.authorizedRuleRelaxation, isTrue);
      expect(fx.watcher.simulatedRuleLevel(_notes, _now), isNull);
      expect(find.text(_T.savedEnforced), findsOneWidget);

      // Enabling adds protection: no PIN; an older laxer session ends now.
      await fx.access.grantAccess(_notes);
      await _tap(tester, toggle);
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect((await fx.rules()).single.enabled, isTrue);
      expect(
          fx.watcher.receivedPolicies.last!.authorizedRuleRelaxation, isFalse);
      expect(fx.access.sessionFor(_notes), isNull);
      expect(await fx.access.evaluate(_notes), AccessDecision.challenge);
      expect(fx.watcher.simulatedRuleLevel(_notes, _now), _L.critical);
    });

    testWidgets('a failed write keeps the switch and reports the failure',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await fx.seed(_rule(enabled: false));
      await _pump(tester, fx);
      fx.db.failRuleWrites = true;
      final Finder toggle = find.byKey(const Key('smart_toggle_r1'));
      await _tap(tester, toggle);
      expect(tester.widget<Switch>(toggle).value, isFalse);
      expect((await fx.rules()).single.enabled, isFalse);
      expect(find.text(_T.saveFailed), findsOneWidget);
    });

    testWidgets('enabled state survives a restart',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await fx.seed(_rule(enabled: false));
      await _pump(tester, fx);
      await _tap(tester, find.byKey(const Key('smart_toggle_r1')));
      expect((await fx.rules()).single.enabled, isTrue);
      final SmartRuleRepositoryImpl fresh = SmartRuleRepositoryImpl(fx.db);
      expect((await fresh.getRules()).valueOrNull!.single.enabled, isTrue);
    });
  });

  group('39. unsaved-draft guard (SIMULATED)', () {
    testWidgets('unchanged new form leaves without a prompt',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pump(tester, fx);
      await _openCreate(tester);
      await _systemBack(tester);
      expect(find.text(_T.discardTitle), findsNothing);
      expect(find.byType(SmartRuleEditorScreen), findsNothing);
    });

    testWidgets(
        'dirty: Keep editing keeps the draft; Discard leaves and '
        'saves nothing', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pump(tester, fx);
      await _openCreate(tester);
      await _fill(tester, name: 'Draft', days: <int>[2]);
      await _systemBack(tester);
      expect(find.text(_T.discardTitle), findsOneWidget);
      await _tap(tester, find.byKey(const Key('smart_keep_editing')));
      expect(find.byType(SmartRuleEditorScreen), findsOneWidget);
      expect(find.text('Draft'), findsWidgets);

      await tester.pageBack(); // AppBar back follows the same guard
      await tester.pumpAndSettle();
      expect(find.text(_T.discardTitle), findsOneWidget);
      await _tap(tester, find.byKey(const Key('smart_discard')));
      expect(find.byType(SmartRuleEditorScreen), findsNothing);
      expect(await fx.rules(), isEmpty);
      expect(fx.db.ruleWrites, 0);
    });

    testWidgets(
        'edit: unchanged leaves; reverting a change counts as '
        'unchanged; a real change prompts', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await fx.seed(_rule());
      await _pump(tester, fx);
      await _tap(tester, find.byKey(const Key('smart_rule_r1')));
      await _systemBack(tester);
      expect(find.byType(SmartRuleEditorScreen), findsNothing);

      await _tap(tester, find.byKey(const Key('smart_rule_r1')));
      await _tap(tester, find.byKey(const Key('smart_day_6')));
      await _tap(tester, find.byKey(const Key('smart_day_6')));
      await _systemBack(tester);
      expect(find.byType(SmartRuleEditorScreen), findsNothing);

      await _tap(tester, find.byKey(const Key('smart_rule_r1')));
      await _tap(tester, find.byKey(const Key('smart_day_6')));
      await _systemBack(tester);
      expect(find.text(_T.discardTitle), findsOneWidget);
      await _tap(tester, find.byKey(const Key('smart_discard')));
      expect((await fx.rules()).single, _rule());
    });

    testWidgets('save success leaves without a prompt; the id is kept',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await fx.seed(_rule());
      await _pump(tester, fx);
      await _tap(tester, find.byKey(const Key('smart_rule_r1')));
      await _fill(tester, name: 'Work hours', days: <int>[6]);
      await _tap(tester, find.byKey(const Key('smart_save')));
      expect(find.text(_T.discardTitle), findsNothing);
      expect(find.byType(SmartRuleEditorScreen), findsNothing);
      final SmartRule saved = (await fx.rules()).single;
      expect(saved.id, 'r1');
      expect(saved.name, 'Work hours');
      expect(saved.days, <int>[1, 2, 3, 4, 5, 6]);
    });

    testWidgets('save failure keeps the draft for retry; Back still prompts',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pump(tester, fx);
      await _openCreate(tester);
      await _fill(tester,
          name: 'Retry me',
          apps: <String>[_notes],
          days: <int>[3],
          level: SmartRuleAction.sensitive);
      fx.db.failRuleWrites = true;
      await _tap(tester, find.byKey(const Key('smart_save')));
      expect(find.byType(SmartRuleEditorScreen), findsOneWidget);
      expect(find.text(_T.saveFailed), findsOneWidget);
      expect(find.text('Retry me'), findsWidgets);
      expect(await fx.rules(), isEmpty);

      fx.db.failRuleWrites = false;
      await _tap(tester, find.byKey(const Key('smart_save')));
      expect(find.byType(SmartRuleEditorScreen), findsNothing);
      expect((await fx.rules()).single.name, 'Retry me');
    });

    testWidgets(
        'routes on top (CR-2 confirmation, a lock challenge) are never '
        'intercepted by the guard', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await fx.seed(_rule());
      await _pump(tester, fx);
      await _tap(tester, find.byKey(const Key('smart_rule_r1')));
      await _fill(tester, level: SmartRuleAction.sensitive); // a reduction
      expect(find.byKey(const Key('smart_review_reduces')), findsOneWidget);
      await _tap(tester, find.byKey(const Key('smart_save')));
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await _systemBack(tester); // dismisses the confirmation only
      expect(find.text(_T.discardTitle), findsNothing);
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(find.byType(SmartRuleEditorScreen), findsOneWidget);
      expect(find.text(_T.denied(UnprotectDenial.notAuthenticated)),
          findsOneWidget);
      expect((await fx.rules()).single.action, SmartRuleAction.critical);

      // A challenge-like route pushed over the dirty editor pops normally.
      final NavigatorState nav =
          tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.push(MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/lock/challenge'),
        builder: (_) => const Scaffold(body: Text('challenge')),
      ));
      await tester.pumpAndSettle();
      await _systemBack(tester);
      expect(find.text('challenge'), findsNothing);
      expect(find.text(_T.discardTitle), findsNothing);
      expect(find.byType(SmartRuleEditorScreen), findsOneWidget);

      // With the PIN the reduction is saved and native applies it.
      await _tap(tester, find.byKey(const Key('smart_save')));
      await _enterPin(tester, _pin);
      expect(find.byType(SmartRuleEditorScreen), findsNothing);
      expect((await fx.rules()).single.action, SmartRuleAction.sensitive);
      expect(fx.watcher.simulatedRuleLevel(_notes, _now), _L.sensitive);
    });

    testWidgets('a stale form never overwrites a newer change',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await fx.seed(_rule());
      await _pump(tester, fx);
      await _tap(tester, find.byKey(const Key('smart_rule_r1')));
      final SmartRule newer = _rule(name: 'Changed elsewhere');
      expect((await fx.c.smartRules.saveRule(newer)).isSuccess, isTrue);
      await _fill(tester, name: 'My edit');
      await _tap(tester, find.byKey(const Key('smart_save')));
      expect(find.text(_T.conflict), findsOneWidget);
      expect(find.byType(SmartRuleEditorScreen), findsOneWidget);
      expect((await fx.rules()).single, newer);
    });
  });

  group('delete and held confirmation (SIMULATED)', () {
    testWidgets('deleting a raising rule needs the PIN',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await fx.seed(_rule());
      await _pump(tester, fx);
      await _tap(tester, find.byKey(const Key('smart_rule_r1')));
      await _tap(tester, find.byKey(const Key('smart_delete')));
      await _tap(tester, find.byKey(const Key('smart_delete_confirm')));
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await _enterPin(tester, _pin);
      expect(await fx.rules(), isEmpty);
      expect(find.byKey(const Key('smart_rules_empty')), findsOneWidget);
      expect(find.text(_T.deleted), findsOneWidget);
      expect(fx.watcher.smartRules, isEmpty);
    });

    testWidgets('a held reduction is shown and can be confirmed with the PIN',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await fx.seed(_rule(
          time: const SmartRuleTime.allDay(), days: SmartRuleDays.everyDay));
      // A reduction saved without confirmation (e.g. an interrupted flow):
      await fx.c.smartRules.setRuleEnabled('r1', enabled: false);
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.watcher.lastRuleStatus, SmartRuleSyncStatus.held);
      await _pump(tester, fx);
      expect(find.byKey(const Key('smart_rules_held')), findsOneWidget);
      expect(fx.watcher.simulatedRuleLevel(_notes, _now), _L.critical);

      await _tap(tester, find.byKey(const Key('smart_rules_held_confirm')));
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await _enterPin(tester, _pin);
      expect(fx.watcher.lastRuleStatus, SmartRuleSyncStatus.applied);
      expect(fx.watcher.simulatedRuleLevel(_notes, _now), isNull);
      expect(find.text(_T.heldConfirmed), findsOneWidget);
      expect(find.byKey(const Key('smart_rules_held')), findsNothing);
    });
  });

  group('40. accessibility and layout (SIMULATED)', () {
    for (final (String label, ThemeData theme) in <(String, ThemeData)>[
      ('dark', AppTheme.dark),
      ('light', AppTheme.light),
    ]) {
      testWidgets(
          '320 dp at 2× text ($label): list and editor lay out '
          'without overflow', (WidgetTester tester) async {
        final _Fx fx = await _Fx.create();
        await fx.seed(_rule(
          name: 'A long rule name for small screens and large text',
          targets: <String>[_notes, _bank],
          time: SmartRuleTime.window(startMinute: 1320, endMinute: 360),
        ));
        await _pump(tester, fx,
            size: const Size(320, 640), textScale: 2, theme: theme);
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          find.byKey(const Key('smart_rule_r1')),
          200,
          scrollable: find.descendant(
            of: find.byKey(const Key('smart_rules_list')),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _tap(tester, find.byKey(const Key('smart_rule_r1')));
        for (int i = 0; i < 12; i++) {
          await tester.drag(find.byKey(const Key('smart_editor_list')),
              const Offset(0, -300));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      });
    }

    testWidgets('semantics: headings, day names, switch labels',
        (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final _Fx fx = await _Fx.create();
      await fx.seed(_rule());
      await _pump(tester, fx);
      expect(find.bySemanticsLabel('Turn off Work'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('smart_rule_r1')));
      expect(
        tester.getSemantics(find.bySemanticsLabel('Monday')),
        isSemantics(
          label: 'Monday',
          isSelected: true,
          isButton: true,
          hasTapAction: true,
        ),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Saturday')),
        isSemantics(
          label: 'Saturday',
          isSelected: false,
          isButton: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });
  });

  testWidgets(
      'CR-2 proof scope: every relaxed app, once, within 60 s; '
      'an empty set is refused', (WidgetTester tester) async {
    final _Fx fx = await _Fx.create();
    await _pump(tester, fx);
    DateTime clock = _now;
    final NavigatorState nav =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    final Future<UnprotectRequestResult> pending =
        requestUnprotectAuthorization(
      navigator: nav,
      credentials: fx.c.auth,
      packages: <String>{_notes},
      clock: () => clock,
      title: relaxRuleConfirmTitle,
    );
    await tester.pumpAndSettle();
    await _enterPin(tester, _pin);
    final UnprotectAuthorization auth = (await pending).authorization!;
    int writes = 0;
    Future<Result<void>> write() async {
      writes++;
      return Result.success(null);
    }

    expect(
        (await relaxSmartRulesWith<void>(auth, <String>{}, write,
                clock: () => clock))
            .isFailure,
        isTrue);
    expect(
        (await relaxSmartRulesWith<void>(auth, <String>{_notes, _bank}, write,
                clock: () => clock))
            .isFailure,
        isTrue,
        reason: 'Bank was never confirmed');
    clock =
        _now.add(UnprotectAuthorization.maxAge + const Duration(seconds: 1));
    expect(
        (await relaxSmartRulesWith<void>(auth, <String>{_notes}, write,
                clock: () => clock))
            .isFailure,
        isTrue,
        reason: 'expired');
    clock = _now.add(const Duration(seconds: 5));
    expect(
        (await relaxSmartRulesWith<void>(auth, <String>{_notes}, write,
                clock: () => clock))
            .isSuccess,
        isTrue);
    expect(
        (await relaxSmartRulesWith<void>(auth, <String>{_notes}, write,
                clock: () => clock))
            .isFailure,
        isTrue,
        reason: 'consumed once');
    expect(writes, 1);
  });

  test('presentation: day and time summaries', () {
    expect(_T.days(SmartRuleDays.everyDay), 'Every day');
    expect(_T.days(<int>[5, 4, 3, 2, 1]), 'Weekdays');
    expect(_T.days(<int>[7, 6]), 'Weekends');
    expect(_T.days(<int>[3, 1]), 'Mon, Wed');
    expect(_T.time(const SmartRuleTime.allDay()), 'All day');
    expect(_T.time(SmartRuleTime.window(startMinute: 0, endMinute: 1439)),
        '00:00–23:59');
    expect(jsonEncode(_T.minute(65)), '"01:05"');
  });
}
