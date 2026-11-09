// Phase 11 / M3 (§8, §9): "Apply profile" inside the existing Smart Rules
// screen (no new tab): type selector + profile picker, never an app list;
// no PIN to add protection, PIN for every reduction (disable / delete an
// activation, weaken or delete a referenced profile); missing-profile and
// unavailable states; honest status; discard guard; per-layer details;
// 320 dp / 2× text, dark / light, TalkBack semantics. All SIMULATED.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/impl/security_profile_repository_impl.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/profiles/security_profile.dart';
import 'package:smart_app_lock/profiles/security_profile_policy.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/rules/smart_rule_policy.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/watcher_service.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/smart/profile_presentation.dart';
import 'package:smart_app_lock/ui/screens/smart/profiles_screen.dart';
import 'package:smart_app_lock/ui/screens/smart/smart_rule_editor_screen.dart';
import 'package:smart_app_lock/ui/screens/smart/smart_rule_presentation.dart';
import 'package:smart_app_lock/ui/screens/smart/smart_screen.dart';

typedef _L = AppSecurityLevel;
typedef _T = SmartRuleText;
typedef _P = ProfileText;

const String _pin = '2468';
const String _notes = 'com.example.notes'; // protected, Standard
const String _chat = 'com.example.chat'; // protected, Sensitive
const String _maps = 'com.example.maps'; // installed, NOT protected
const String _tripId = 'custom-00000000000a';
final DateTime _now = DateTime(2026, 11, 2, 12); // Monday noon

SmartRule _act(String profile, {String id = 'a1', bool on = true}) => SmartRule(
      id: id,
      name: 'Daytime $profile',
      targetPackages: const <String>[],
      days: SmartRuleDays.everyDay,
      time: const SmartRuleTime.allDay(),
      action: SmartRuleAction.applyProfile,
      profileId: profile,
      enabled: on,
    );

SecurityProfile _trip([_L? all = _L.critical]) =>
    SecurityProfile.custom(id: _tripId, name: 'Trip', allProtectedLevel: all);

SecurityProfileSet _withTrip([_L? all = _L.critical]) =>
    SecurityProfileSet.defaults().withAdded(_trip(all));

class _Db extends InMemoryLocalDatabase {
  bool failProfileReads = false;

  @override
  Future<String?> getSetting(String key) async {
    if (key == SecurityProfileRepositoryImpl.storageKey && failProfileReads) {
      throw StateError('simulated profile read failure');
    }
    return super.getSetting(key);
  }
}

class _Fx {
  _Fx(this.c, this.db);

  final AppContainer c;
  final _Db db;

  StaticWatcherService get watcher => c.watcher as StaticWatcherService;

  static Future<_Fx> create({
    SecurityProfileSet? profiles,
    List<SmartRule> rules = const <SmartRule>[],
  }) async {
    final _Db db = _Db();
    final AppContainer c = AppContainer.inMemory(
      apps: const <AppEntry>[
        AppEntry(packageName: _notes, label: 'Notes'),
        AppEntry(packageName: _chat, label: 'Chat'),
        AppEntry(packageName: _maps, label: 'Maps'),
      ],
      database: db,
      accessClock: () => _now,
    );
    (c.watcher as StaticWatcherService).ruleClock = () => _now;
    await c.auth.enrollPin(_pin);
    await c.protectedApps.add(ProtectedApp(
      packageName: _notes,
      label: 'Notes',
      addedAt: DateTime(2026, 11, 1),
    ));
    await c.protectedApps.add(ProtectedApp(
      packageName: _chat,
      label: 'Chat',
      addedAt: DateTime(2026, 11, 1),
      securityLevel: _L.sensitive,
    ));
    if (profiles != null) {
      expect(
        (await c.securityProfiles.saveProfiles(profiles,
                expected: SecurityProfileSet.defaults()))
            .isSuccess,
        isTrue,
      );
    }
    for (final SmartRule r in rules) {
      expect((await c.smartRules.saveRule(r)).isSuccess, isTrue);
    }
    await c.protectionBootstrap.synchronize();
    expect((c.watcher as StaticWatcherService).lastRuleStatus,
        SmartRuleSyncStatus.applied);
    return _Fx(c, db);
  }

  Future<SecurityProfileSet> profiles() async =>
      (await c.securityProfiles.getProfiles()).valueOrNull!;

  Future<List<SmartRule>> rules() async =>
      (await c.smartRules.getRules()).valueOrNull!;

  int get flagged => watcher.receivedPolicies
      .where(
          (ProtectionPolicySnapshot? p) => p?.authorizedRuleRelaxation == true)
      .length;

  _L? native(String pkg) => watcher.simulatedRuleLevel(pkg, _now);
}

Future<void> _pump(
  WidgetTester tester,
  _Fx fx, {
  Size size = const Size(800, 2600),
  double textScale = 1.0,
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

Future<void> _openCreateProfileRule(WidgetTester tester) async {
  await _tap(tester, find.byKey(const Key('smart_create')));
  expect(find.byType(SmartRuleEditorScreen), findsOneWidget);
  await tester.enterText(find.byKey(const Key('smart_name')), 'School day');
  await tester.pumpAndSettle();
  await _tap(tester, find.byKey(const Key('smart_day_1')));
  await _tap(tester, find.byKey(const Key('smart_all_day')));
  await _tap(tester, find.byKey(const Key('smart_level_profile')));
}

/// Lazily built lists (320 dp / 2× text): scroll [f] into existence
/// (down first, then up).
Future<void> _reveal(WidgetTester tester, Finder f, Finder within) async {
  if (f.evaluate().isEmpty) {
    final Finder scrollable =
        find.descendant(of: within, matching: find.byType(Scrollable)).first;
    try {
      await tester.scrollUntilVisible(f, 200,
          scrollable: scrollable, maxScrolls: 30);
    } on StateError {
      await tester.scrollUntilVisible(f, -200,
          scrollable: scrollable, maxScrolls: 60);
    }
  }
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
}

Future<void> _openProfiles(WidgetTester tester) async {
  await _tap(tester, find.byKey(const Key('smart_profile_change')));
  expect(find.byType(ProfilesScreen), findsOneWidget);
}

Future<void> _profileMenu(WidgetTester tester, String id, String item) async {
  await _tap(tester, find.byKey(Key('profile_menu_$id')));
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

void main() {
  group('P11-M3 editor: Apply profile (SIMULATED)', () {
    testWidgets(
        'UA-1. create: type selector → profile picker (no app list) → save '
        'with NO PIN; the manual profile stays Normal; native applies Guest '
        'as an overlay; list and Smart card are honest',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pump(tester, fx);
      await _openCreateProfileRule(tester);
      expect(find.byKey(const Key('smart_app_$_notes')), findsNothing,
          reason: 'a profile rule never shows an app list');
      expect(find.text(_T.profileAppsNote), findsOneWidget);
      for (final String id in <String>['normal', 'home', 'work', 'guest']) {
        expect(find.byKey(Key('smart_profile_$id')), findsOneWidget);
      }
      await _tap(tester, find.byKey(const Key('smart_profile_guest')));
      final Finder review = find.byKey(const Key('smart_review'));
      expect(find.descendant(of: review, matching: find.text('Profile: Guest')),
          findsOneWidget);
      expect(
          find.descendant(
              of: review,
              matching: find.textContaining(_T.profileSummary('Guest'))),
          findsOneWidget);

      await _tap(tester, find.byKey(const Key('smart_save')));
      expect(find.byType(PinUnlockScreen), findsNothing,
          reason: 'adding protection needs no confirmation');
      final SmartRule saved = (await fx.rules()).single;
      expect(saved.action, SmartRuleAction.applyProfile);
      expect(saved.profileId, 'guest');
      expect(saved.targetPackages, isEmpty);
      expect(saved.days, <int>[1]);
      expect((await fx.profiles()).activeProfileId, 'normal');
      expect(fx.native(_notes), _L.critical);
      expect(fx.native(_maps), isNull);
      expect(fx.flagged, 0);
      expect(find.text(_T.savedEnforced), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(Key('smart_rule_summary_${saved.id}')))
            .data,
        _T.profileSummary('Guest'),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('smart_profile_scheduled')))
            .data,
        _T.scheduledNow(<String>['Guest']),
      );
    });

    testWidgets('UA-2. validation: no profile chosen → error; nothing saved',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pump(tester, fx);
      await _openCreateProfileRule(tester);
      await _tap(tester, find.byKey(const Key('smart_save')));
      expect(find.text(_T.profileRequired), findsWidgets);
      expect(await fx.rules(), isEmpty);
      expect(find.byType(SmartRuleEditorScreen), findsOneWidget);
    });

    testWidgets(
        'UA-3. profiles unavailable: retry state, save refused; retry loads',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pump(tester, fx);
      fx.db.failProfileReads = true;
      await _openCreateProfileRule(tester);
      expect(find.byKey(const Key('smart_profiles_retry')), findsOneWidget);
      expect(find.byKey(const Key('smart_profile_guest')), findsNothing);
      await _tap(tester, find.byKey(const Key('smart_save')));
      expect(await fx.rules(), isEmpty);
      fx.db.failProfileReads = false;
      await _tap(tester, find.byKey(const Key('smart_profiles_retry')));
      expect(find.byKey(const Key('smart_profile_guest')), findsOneWidget);
    });

    testWidgets(
        'UA-4. discard guard: changing the profile of a saved rule asks '
        'before leaving; Discard writes nothing', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_act('guest')]);
      await _pump(tester, fx);
      await _tap(tester, find.byKey(const Key('smart_rule_a1')));
      expect(find.byType(SmartRuleEditorScreen), findsOneWidget);
      await _tap(tester, find.byKey(const Key('smart_profile_home')));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('smart_keep_editing')), findsOneWidget);
      await _tap(tester, find.byKey(const Key('smart_discard')));
      expect(find.byType(SmartRuleEditorScreen), findsNothing);
      expect(await fx.rules(), <SmartRule>[_act('guest')]);
    });

    testWidgets(
        'UA-5 (TalkBack). profile choices are a mutually exclusive group; '
        'the chosen one is announced selected', (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_act('guest')]);
      await _pump(tester, fx);
      await _tap(tester, find.byKey(const Key('smart_rule_a1')));
      for (final (String key, String label, bool selected)
          in <(String, String, bool)>[
        ('smart_profile_guest', 'Guest', true),
        ('smart_profile_home', 'Home', false),
        ('smart_level_profile', 'Apply profile', true),
        ('smart_level_critical', 'Critical', false),
      ]) {
        final SemanticsNode node = tester.getSemantics(find.byKey(Key(key)));
        expect(
          node,
          isSemantics(
            isSelected: selected,
            hasSelectedState: true,
            isInMutuallyExclusiveGroup: true,
            hasTapAction: true,
          ),
          reason: key,
        );
        expect(node.getSemanticsData().label.split('\n').first, label,
            reason: key);
      }
      handle.dispose();
    });
  });

  group('P11-M3 reductions need the PIN (SIMULATED)', () {
    testWidgets(
        'UR-1. turning off an activation rule needs the PIN; cancel changes '
        'nothing; with it ONE bound flag; the manual profile is untouched',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_act('guest')]);
      await _pump(tester, fx);
      final Finder toggle = find.byKey(const Key('smart_toggle_a1'));
      await _tap(tester, toggle);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect((await fx.rules()).single.enabled, isTrue);
      expect(fx.native(_notes), _L.critical);
      expect(fx.flagged, 0);

      await _tap(tester, toggle);
      await _enterPin(tester);
      expect((await fx.rules()).single.enabled, isFalse);
      expect(fx.native(_notes), isNull);
      expect(fx.flagged, 1);
      expect(await fx.profiles(), SecurityProfileSet.defaults());
      expect(find.text(_T.savedEnforced), findsOneWidget);
    });

    testWidgets(
        'UR-2 (R2). a missing profile is shown as such (list pill, summary, '
        'editor card); native treats it as Critical; turning it off is a '
        'PIN-confirmed reduction (never a dead end)',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_act(_tripId)]);
      expect(fx.native(_notes), _L.critical);
      await _pump(tester, fx);
      expect(find.byKey(const Key('smart_rule_missing_a1')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('smart_rule_summary_a1')))
            .data,
        _T.profileSummary(null),
      );
      await _tap(tester, find.byKey(const Key('smart_rule_a1')));
      expect(find.byKey(const Key('smart_profile_missing')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await _tap(tester, find.byKey(const Key('smart_toggle_a1')));
      await _enterPin(tester);
      expect((await fx.rules()).single.enabled, isFalse);
      expect(fx.native(_notes), isNull);
    });

    testWidgets(
        'UR-3 (R1). a referenced profile shows "Used by"; deleting it is '
        'refused (no PIN, nothing changed)', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
          profiles: _withTrip(), rules: <SmartRule>[_act(_tripId)]);
      await _pump(tester, fx);
      await _openProfiles(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('profile_used_by_$_tripId')))
            .data,
        isNotNull,
      );
      await _profileMenu(tester, _tripId, _P.delete);
      final Finder confirm = find.byKey(const Key('profile_delete_confirm'));
      if (confirm.evaluate().isNotEmpty) {
        await tester.tap(confirm);
        await tester.pumpAndSettle();
      }
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(find.text(_P.inUse), findsOneWidget);
      expect(await fx.profiles(), _withTrip());
      expect(fx.native(_notes), _L.critical);
    });

    testWidgets(
        'UR-4 (R3). weakening an INACTIVE but referenced profile warns in '
        'the editor and needs the PIN; rules unchanged',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
          profiles: _withTrip(), rules: <SmartRule>[_act(_tripId)]);
      await _pump(tester, fx);
      await _openProfiles(tester);
      await _profileMenu(tester, _tripId, _P.edit);
      expect(find.byKey(const Key('profile_editor_used_by')), findsOneWidget);
      expect(find.text(_P.usedByRules(1)), findsOneWidget);
      await _tap(tester, find.byKey(const Key('profile_editor_all_none')));
      await _tap(tester, find.byKey(const Key('profile_editor_save')));
      expect(find.byType(PinUnlockScreen), findsOneWidget,
          reason: 'the scheduled overlay gets weaker');
      await _enterPin(tester);
      expect((await fx.profiles()).byId(_tripId)!.allProtectedLevel, isNull);
      expect((await fx.profiles()).activeProfileId, 'normal');
      expect(fx.native(_notes), isNull);
      expect(await fx.rules(), <SmartRule>[_act(_tripId)]);
    });

    testWidgets('UR-5. strengthening a referenced profile needs no PIN',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
          profiles: _withTrip(_L.sensitive), rules: <SmartRule>[_act(_tripId)]);
      await _pump(tester, fx);
      await _openProfiles(tester);
      await _profileMenu(tester, _tripId, _P.edit);
      await _tap(tester, find.byKey(const Key('profile_editor_all_critical')));
      await _tap(tester, find.byKey(const Key('profile_editor_save')));
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(fx.native(_notes), _L.critical);
      expect(fx.flagged, 0);
    });

    testWidgets(
        'UR-6 (§3/R2). a disabled rule whose profile is missing can NOT be '
        'turned back on: refused before any write, nothing sent, no PIN',
        (WidgetTester tester) async {
      final _Fx fx =
          await _Fx.create(rules: <SmartRule>[_act(_tripId, on: false)]);
      expect(fx.native(_notes), isNull);
      await _pump(tester, fx);
      final int flaggedBefore = fx.flagged;
      await _tap(tester, find.byKey(const Key('smart_toggle_a1')));
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(await fx.rules(), <SmartRule>[_act(_tripId, on: false)],
          reason: 'an enabled rule may never point at a missing profile');
      expect(fx.native(_notes), isNull);
      expect(fx.flagged, flaggedBefore);
      expect(find.text(_T.savedEnforced), findsNothing);
    });
  });

  group('P11-M3 details per layer (SIMULATED)', () {
    testWidgets(
        'UD-1. scheduled layer and effective level are shown per app '
        '(calculated, not labelled live)', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(rules: <SmartRule>[_act('guest')]);
      await _pump(tester, fx);
      await _tap(tester, find.byKey(const Key('smart_rule_details_toggle')));
      final Finder scheduled =
          find.byKey(const Key('smart_rule_details_scheduled_$_notes'));
      expect(scheduled, findsOneWidget);
      expect(tester.widget<Text>(scheduled).data, contains('Guest'));
      expect(find.byKey(const Key('smart_rule_details_effective_$_notes')),
          findsOneWidget);
      expect(find.byKey(const Key('smart_rule_details_scheduled_$_maps')),
          findsNothing,
          reason: 'unprotected apps are never listed as protected');
      expect(find.textContaining('live'), findsNothing);
      expect(find.textContaining('at the last check in this session'),
          findsOneWidget,
          reason: 'the native line is the last exchange, never live (§9)');
    });

    test(
        'UN-1 (§6/§9). profile status is "Applied" only when the ACTIVATION '
        'part of the last exchange equals what the saved rules and profiles '
        'compile to now', () {
      const Set<String> protectedPackages = <String>{_notes, _chat};
      final List<SmartRule> rules = <SmartRule>[_act(_tripId)];
      List<Map<String, Object?>> activation(SecurityProfileSet set,
              [List<SmartRule>? r]) =>
          SmartRulePolicy.nativeTransport(SecurityProfilePolicy.activationRules(
              r ?? rules, set, protectedPackages));
      final List<Map<String, Object?>> manual = SmartRulePolicy.nativeTransport(
          SecurityProfilePolicy.overlayRules(
              _withTrip().active, protectedPackages));
      SmartRuleNativeRecord record(List<Map<String, Object?>>? sent) =>
          SmartRuleNativeRecord(
            status: SmartRuleSyncStatus.applied,
            sentRules: const <Map<String, Object?>>[],
            sentProfileOverlay: manual,
            sentActivationOverlay: sent,
          );
      ProfileNativeStatus status(SmartRuleNativeRecord r,
              [List<SmartRule>? withRules]) =>
          profileNativeStatus(
            saved: _withTrip(),
            record: r,
            protectedPackages: protectedPackages,
            rules: withRules ?? rules,
          );

      final List<Map<String, Object?>> current = activation(_withTrip());
      expect(current, isNotEmpty);
      expect(status(record(current)), ProfileNativeStatus.applied);
      // Trip was strengthened Sensitive → Critical after the last exchange.
      final List<Map<String, Object?>> stale =
          activation(_withTrip(_L.sensitive));
      expect(stale.toString(), isNot(current.toString()));
      expect(status(record(stale)), ProfileNativeStatus.unconfirmed);
      // Activation expected, none recorded.
      expect(status(record(null)), ProfileNativeStatus.unconfirmed);
      // The rule was deleted, but native last got its activation.
      expect(status(record(current), const <SmartRule>[]),
          ProfileNativeStatus.unconfirmed);
    });
  });

  group('P11-M3 layout (SIMULATED)', () {
    for (final (String name, ThemeData theme) in <(String, ThemeData)>[
      ('dark', AppTheme.dark),
      ('light', AppTheme.light),
    ]) {
      testWidgets(
          'UL-1. 320 dp, 2× text, $name: list, details and profile editor '
          'lay out without overflow', (WidgetTester tester) async {
        final _Fx fx = await _Fx.create(
            profiles: _withTrip(),
            rules: <SmartRule>[_act('guest'), _act(_tripId, id: 'a2')]);
        await _pump(tester, fx,
            size: const Size(320, 1400), textScale: 2.0, theme: theme);
        expect(tester.takeException(), isNull);
        final Finder screen = find.byType(SmartScreen);
        final Finder toggle =
            find.byKey(const Key('smart_rule_details_toggle'));
        await _reveal(tester, toggle, screen);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _reveal(
            tester,
            find.byKey(const Key('smart_rule_details_scheduled_$_notes')),
            screen);
        expect(tester.takeException(), isNull);
        final Finder rule = find.byKey(const Key('smart_rule_a2'));
        await _reveal(tester, rule, screen);
        await tester.tap(rule);
        await tester.pumpAndSettle();
        expect(find.byType(SmartRuleEditorScreen), findsOneWidget);
        final Finder editor = find.byType(SmartRuleEditorScreen);
        await _reveal(
            tester, find.byKey(const Key('smart_profile_$_tripId')), editor);
        await _reveal(tester, find.byKey(const Key('smart_review')), editor);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
