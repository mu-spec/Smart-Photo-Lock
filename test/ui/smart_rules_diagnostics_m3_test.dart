// Phase 10 / M3 (PRD 10K): the read-only "Rule details" view of the Smart
// tab — calculated vs native-confirmed status, multiple matching rules,
// why lower-priority rules had no effect, unavailable/stale states,
// no side effects, layout and semantics.
//
// SIMULATED: production SmartScreen + SmartRuleDetails over
// AppContainer.inMemory; the static watcher stands in for native. No device.

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
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/rules/smart_rule_document.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/watcher_service.dart';
import 'package:smart_app_lock/ui/screens/smart/smart_rule_details.dart';
import 'package:smart_app_lock/ui/screens/smart/smart_screen.dart';

typedef _T = SmartRuleDetailsText;

const String _notes = 'com.example.notes'; // protected, Standard
const String _bank = 'com.example.bank'; // protected, Critical
const String _game = 'com.example.game'; // installed, NOT protected

/// Mutable test clock (Monday 2026-11-02 12:30 local by default).
DateTime _clock = DateTime(2026, 11, 2, 12, 30);

final SmartRule _work = SmartRule(
  id: 'work',
  name: 'Work Hours',
  targetPackages: const <String>[_notes, _bank],
  days: SmartRuleDays.weekdays,
  time: SmartRuleTime.window(startMinute: 9 * 60, endMinute: 17 * 60),
  action: SmartRuleAction.sensitive,
);
final SmartRule _banking = SmartRule(
  id: 'banking',
  name: 'Banking Protection',
  targetPackages: const <String>[_notes, _game],
  days: SmartRuleDays.everyDay,
  time: SmartRuleTime.window(startMinute: 12 * 60, endMinute: 14 * 60),
  action: SmartRuleAction.critical,
);
final SmartRule _weekend = SmartRule(
  id: 'weekend',
  name: 'Weekend',
  targetPackages: const <String>[_notes],
  days: SmartRuleDays.weekend,
  time: const SmartRuleTime.allDay(),
  action: SmartRuleAction.critical,
);

class _Db extends InMemoryLocalDatabase {
  bool failRuleReads = false;
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
    if (key == SmartRuleRepositoryImpl.storageKey) ruleWrites++;
    return super.setSetting(key, value);
  }
}

class _Fx {
  _Fx(this.c, this.db);

  final AppContainer c;
  final _Db db;

  StaticWatcherService get watcher => c.watcher as StaticWatcherService;

  /// [rules] are stored; [sync] = a startup sync ran (rules read + sent).
  static Future<_Fx> create({
    List<SmartRule> rules = const <SmartRule>[],
    bool sync = true,
  }) async {
    _clock = DateTime(2026, 11, 2, 12, 30);
    final _Db db = _Db();
    if (rules.isNotEmpty) {
      await db.setSetting(
          SmartRuleRepositoryImpl.storageKey, SmartRuleDocument.encode(rules));
    }
    final AppContainer c = AppContainer.inMemory(
      apps: const <AppEntry>[
        AppEntry(packageName: _notes, label: 'Notes'),
        AppEntry(packageName: _bank, label: 'Bank'),
        AppEntry(packageName: _game, label: 'Game'),
      ],
      database: db,
      accessClock: () => _clock,
    );
    await c.auth.enrollPin('2468');
    await c.protectedApps.add(ProtectedApp(
      packageName: _notes,
      label: 'Notes',
      addedAt: DateTime(2026, 11, 1),
    ));
    await c.protectedApps.add(ProtectedApp(
      packageName: _bank,
      label: 'Bank',
      addedAt: DateTime(2026, 11, 1),
      securityLevel: AppSecurityLevel.critical,
    ));
    (c.watcher as StaticWatcherService).ruleClock = () => _clock;
    if (sync) {
      expect((await c.protectionBootstrap.synchronize()).isSuccess, isTrue);
    }
    db.ruleWrites = 0;
    return _Fx(c, db);
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Fx fx, {
  Size size = const Size(800, 3000),
  double textScale = 1,
  ThemeData? theme,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
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
        home: Scaffold(body: SmartScreen(clock: () => _clock)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester) async {
  final Finder toggle = find.byKey(const Key('smart_rule_details_toggle'));
  await tester.scrollUntilVisible(
    toggle,
    200,
    scrollable: find.descendant(
      of: find.byKey(const Key('smart_rules_list')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.ensureVisible(toggle);
  await tester.pumpAndSettle();
  await tester.tap(toggle);
  await tester.pumpAndSettle();
}

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  group('16–20. details content (SIMULATED)', () {
    testWidgets('collapsed by default; no diagnostics until opened',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_work, _banking]);
      await _pump(tester, fx);
      expect(find.byKey(const Key('smart_rule_details')), findsOneWidget);
      expect(find.byKey(const Key('smart_rule_details_body')), findsNothing);
      await _open(tester);
      expect(find.byKey(const Key('smart_rule_details_body')), findsOneWidget);
    });

    testWidgets(
        'multiple matching rules: deciding rule, outranked rule, saved-level '
        'cover and an unprotected app', (WidgetTester tester) async {
      final _Fx fx =
          await _Fx.create(rules: <SmartRule>[_work, _banking, _weekend]);
      await _pump(tester, fx);
      await _open(tester);

      // Notes: Standard saved, Work (Sensitive) + Banking (Critical) match.
      expect(_text(tester, 'smart_rule_details_level_$_notes'),
          _T.calculated(AppSecurityLevel.critical));
      expect(_text(tester, 'smart_rule_details_decided_$_notes'),
          _T.decidedByRule('Banking Protection'));
      expect(_text(tester, 'smart_rule_details_entry_${_notes}_banking'),
          'Banking Protection · Critical: applies now and decides the level');
      expect(_text(tester, 'smart_rule_details_entry_${_notes}_work'),
          'Work Hours · Sensitive: applies now, but a stricter rule decides');
      expect(_text(tester, 'smart_rule_details_entry_${_notes}_weekend'),
          'Weekend · Critical: not now: not scheduled for Monday');

      // Bank: saved Critical already covers Work Hours.
      expect(_text(tester, 'smart_rule_details_level_$_bank'),
          _T.calculated(AppSecurityLevel.critical));
      expect(_text(tester, 'smart_rule_details_decided_$_bank'),
          _T.decidedBySaved);
      expect(
          _text(tester, 'smart_rule_details_entry_${_bank}_work'),
          'Work Hours · Sensitive: applies now, but the saved level is '
          'already Critical');
      expect(find.byKey(const Key('smart_rule_details_entry_${_bank}_banking')),
          findsNothing,
          reason: 'only rules that select the app are listed');

      // Game: targeted but not protected.
      expect(
          find.descendant(
            of: find.byKey(const Key('smart_rule_details_app_$_game')),
            matching: find.text(_T.notProtected),
          ),
          findsOneWidget);
      expect(find.byKey(const Key('smart_rule_details_level_$_game')),
          findsNothing);
    });

    testWidgets('Refresh re-evaluates at the clock (no timer)',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_work, _banking]);
      await _pump(tester, fx);
      await _open(tester);
      expect(_text(tester, 'smart_rule_details_decided_$_notes'),
          _T.decidedByRule('Banking Protection'));
      _clock = DateTime(2026, 11, 2, 14); // Banking ends (exclusive)
      await tester.pump(const Duration(minutes: 5));
      expect(_text(tester, 'smart_rule_details_decided_$_notes'),
          _T.decidedByRule('Banking Protection'),
          reason: 'nothing refreshes by itself');
      await tester.tap(find.byKey(const Key('smart_rule_details_refresh')));
      await tester.pumpAndSettle();
      expect(_text(tester, 'smart_rule_details_decided_$_notes'),
          _T.decidedByRule('Work Hours'),
          reason: 'falls back to the next strongest rule, not Standard');
      expect(_text(tester, 'smart_rule_details_level_$_notes'),
          _T.calculated(AppSecurityLevel.sensitive));
      expect(_text(tester, 'smart_rule_details_checked'),
          _T.checkedAt(DateTime(2026, 11, 2, 14)));
    });
  });

  group('19–20. native and engine status (SIMULATED)', () {
    testWidgets('confirmed only after native applied exactly these rules',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_work, _banking]);
      await _pump(tester, fx);
      await _open(tester);
      expect(find.byKey(const Key('smart_rule_details_native_confirmed')),
          findsOneWidget);
      expect(find.text(_T.nativeConfirmed), findsOneWidget);
      expect(find.text(_T.calculatedNote), findsOneWidget);
    });

    testWidgets(
        'before any native exchange: not checked yet, and protected apps are '
        'Critical until rules are read', (WidgetTester tester) async {
      final _Fx fx =
          await _Fx.create(rules: <SmartRule>[_work, _banking], sync: false);
      await _pump(tester, fx);
      await _open(tester);
      expect(find.byKey(const Key('smart_rule_details_native_notReported')),
          findsOneWidget);
      expect(find.byKey(const Key('smart_rule_details_engine_notLoaded')),
          findsOneWidget);
      // The calculated level is still shown as a calculation.
      expect(_text(tester, 'smart_rule_details_level_$_notes'),
          _T.calculated(AppSecurityLevel.critical));
      expect(find.text(_T.nativeConfirmed), findsNothing);
    });

    testWidgets(
        'a saved but unsynced change: not confirmed, engine behind saved',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_work]);
      expect((await fx.c.smartRules.saveRule(_banking)).isSuccess, isTrue);
      await _pump(tester, fx);
      await _open(tester);
      expect(find.byKey(const Key('smart_rule_details_native_notConfirmed')),
          findsOneWidget);
      expect(find.byKey(const Key('smart_rule_details_engine_behindSaved')),
          findsOneWidget);
      expect(find.text(_T.nativeConfirmed), findsNothing);
    });

    testWidgets('held stricter native rules are shown as held',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_work, _banking]);
      // A reduction synced WITHOUT the CR-2 flag → native holds the union.
      expect((await fx.c.smartRules.deleteRule('banking')).isSuccess, isTrue);
      expect(
          (await fx.c.protectionBootstrap.synchronize())
              .valueOrNull!
              .policyAck
              .ruleStatus,
          SmartRuleSyncStatus.held);
      await _pump(tester, fx);
      await _open(tester);
      expect(find.byKey(const Key('smart_rule_details_native_heldStricter')),
          findsOneWidget);
      expect(find.text(_T.nativeHeld), findsOneWidget);
    });

    testWidgets('a failed native write is never shown as confirmed',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_work]);
      fx.watcher.configureFault = (_) => StaticConfigureFault.failAfterApply;
      expect((await fx.c.smartRules.saveRule(_banking)).isSuccess, isTrue);
      expect((await fx.c.protectionBootstrap.synchronize()).isFailure, isTrue);
      await _pump(tester, fx);
      await _open(tester);
      expect(find.byKey(const Key('smart_rule_details_native_notConfirmed')),
          findsOneWidget);
      expect(find.text(_T.nativeConfirmed), findsNothing);
    });

    testWidgets(
        'unreadable rules: error card says protected apps are Critical for '
        'now (R-A floor), no details offered', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_work]);
      fx.db.failRuleReads = true;
      await fx.c.protectionBootstrap.synchronize();
      await _pump(tester, fx);
      expect(find.byKey(const Key('smart_rules_engine_note')), findsOneWidget);
      expect(find.text(_T.engineReadFailed), findsOneWidget);
      expect(find.byKey(const Key('smart_rule_details')), findsNothing);
    });

    testWidgets('unreadable on screen but engine current: no Critical claim',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_work]);
      fx.db.failRuleReads = true; // the screen's read fails; engine is current
      await _pump(tester, fx);
      expect(find.byKey(const Key('smart_rules_error_storageUnavailable')),
          findsOneWidget);
      expect(find.byKey(const Key('smart_rules_engine_note')), findsNothing);
    });
  });

  group('22. no side effects (SIMULATED)', () {
    testWidgets('opening, refreshing and closing writes and sends nothing',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_work, _banking]);
      await _pump(tester, fx);
      final int configures = fx.watcher.configureCalls;
      final int authorizes = fx.watcher.authorizePackageCalls;
      final Object? exchange = fx.c.protectionBootstrap.lastRuleExchange;
      await _open(tester);
      for (int i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const Key('smart_rule_details_refresh')));
        await tester.pumpAndSettle();
      }
      await _open(tester); // close
      expect(fx.db.ruleWrites, 0);
      expect(fx.watcher.configureCalls, configures);
      expect(fx.watcher.authorizePackageCalls, authorizes);
      expect(fx.watcher.authorizedPackages, isEmpty);
      expect(identical(fx.c.protectionBootstrap.lastRuleExchange, exchange),
          isTrue);
      expect(
          (await fx.c.protectedApps.getProtectedApps())
              .valueOrNull!
              .map((ProtectedApp a) => '${a.packageName}:${a.securityLevel}')
              .toSet(),
          <String>{
            '$_notes:${AppSecurityLevel.standard}',
            '$_bank:${AppSecurityLevel.critical}',
          },
          reason: 'saved levels unchanged');
    });
  });

  group('32. layout and accessibility (SIMULATED)', () {
    for (final (String label, ThemeData theme) in <(String, ThemeData)>[
      ('dark', AppTheme.dark),
      ('light', AppTheme.light),
    ]) {
      testWidgets('320 dp at 2× text ($label): details lay out',
          (WidgetTester tester) async {
        final _Fx fx = await _Fx.create(
            rules: <SmartRule>[_work, _banking, _weekend], sync: false);
        await _pump(tester, fx,
            size: const Size(320, 640), textScale: 2, theme: theme);
        await _open(tester);
        expect(tester.takeException(), isNull);
        for (int i = 0; i < 15; i++) {
          await tester.drag(
              find.byKey(const Key('smart_rules_list')), const Offset(0, -300));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      });
    }

    testWidgets('toggle semantics: button with expanded state',
        (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_work]);
      await _pump(tester, fx);
      final Finder toggle = find.bySemanticsLabel(_T.title);
      expect(
        tester.getSemantics(toggle),
        isSemantics(
          label: _T.title,
          isButton: true,
          hasExpandedState: true,
          isExpanded: false,
          hasTapAction: true,
        ),
      );
      await _open(tester);
      // The body is read separately, never folded into the button.
      final Finder body =
          find.bySemanticsLabel(RegExp(RegExp.escape(_T.nativeConfirmed)));
      expect(body, findsOneWidget);
      expect(
        tester.getSemantics(body),
        isSemantics(isButton: false, hasTapAction: false),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel(_T.title)),
        isSemantics(
          label: _T.title,
          isButton: true,
          hasExpandedState: true,
          isExpanded: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });
  });
}
