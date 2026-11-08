// Phase 11 / M2: manual profile switching and custom profile management,
// end to end through the Smart tab (AppContainer.inMemory + the SIMULATED
// native model). Includes the CR-2 proof isolation matrix with REAL
// PIN-minted proofs, session safety, and layout/accessibility checks.
// All results are SIMULATED (no device).

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
import 'package:smart_app_lock/protection/bound_relaxation.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/credential_state.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/watcher_service.dart';
import 'package:smart_app_lock/ui/screens/apps/unprotect_gate.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/smart/profile_change.dart';
import 'package:smart_app_lock/ui/screens/smart/profile_editor_screen.dart';
import 'package:smart_app_lock/ui/screens/smart/profile_presentation.dart';
import 'package:smart_app_lock/ui/screens/smart/profiles_screen.dart';
import 'package:smart_app_lock/ui/screens/smart/smart_screen.dart';
import 'package:smart_app_lock/utilities/result.dart';

typedef _L = AppSecurityLevel;
typedef _P = ProfileText;

const String _pin = '2468';
const String _wrongPin = '1357';
const String _notes = 'com.example.notes'; // protected, Standard
const String _chat = 'com.example.chat'; // protected, Sensitive
const String _maps = 'com.example.maps'; // installed, NOT protected
final DateTime _now = DateTime(2026, 11, 2, 12); // Monday noon

final SmartRule _chatCritical = SmartRule(
  id: 'chat-critical',
  name: 'Chat Critical',
  targetPackages: const <String>[_chat],
  days: SmartRuleDays.everyDay,
  time: const SmartRuleTime.allDay(),
  action: SmartRuleAction.critical,
);

SecurityProfileSet _guest() =>
    SecurityProfileSet.defaults().withActive(SecurityProfileKind.guest.id);

SecurityProfile _trip({_L? all = _L.critical, String name = 'Trip'}) =>
    SecurityProfile.custom(
      id: 'custom-00000000000a',
      name: name,
      allProtectedLevel: all,
    );

class _Db extends InMemoryLocalDatabase {
  bool failProfileWrites = false;
  int profileWrites = 0;
  String? corruptProfiles;

  @override
  Future<String?> getSetting(String key) async {
    if (key == SecurityProfileRepositoryImpl.storageKey &&
        corruptProfiles != null) {
      return corruptProfiles;
    }
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) {
    if (key == SecurityProfileRepositoryImpl.storageKey) {
      profileWrites++;
      if (failProfileWrites) throw StateError('simulated profile write');
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
    for (final SmartRule r in rules) {
      expect((await c.smartRules.saveRule(r)).isSuccess, isTrue);
    }
    if (profiles != null) {
      expect(
        (await c.securityProfiles.saveProfiles(profiles,
                expected: SecurityProfileSet.defaults()))
            .isSuccess,
        isTrue,
      );
    }
    await c.protectionBootstrap.synchronize();
    expect((c.watcher as StaticWatcherService).lastRuleStatus,
        SmartRuleSyncStatus.applied);
    db.profileWrites = 0;
    return _Fx(c, db);
  }

  Future<SecurityProfileSet> profiles() async =>
      (await c.securityProfiles.getProfiles()).valueOrNull!;

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

Future<void> _openProfiles(WidgetTester tester) async {
  await _tap(tester, find.byKey(const Key('smart_profile_change')));
  expect(find.byType(ProfilesScreen), findsOneWidget);
}

Future<void> _enterPin(WidgetTester tester, [String pin = _pin]) async {
  expect(find.byType(PinUnlockScreen), findsOneWidget);
  for (final String d in pin.split('')) {
    await tester.tap(find.byKey(Key('pin_key_$d')));
    await tester.pumpAndSettle();
  }
}

Future<void> _menu(WidgetTester tester, String id, String item) async {
  final Finder menu = find.byKey(Key('profile_menu_$id'));
  if (menu.evaluate().isEmpty) {
    // Lazily built list (narrow screens / large text): scroll to it.
    await tester.scrollUntilVisible(menu, 200,
        scrollable: find
            .descendant(
                of: find.byType(ProfilesScreen),
                matching: find.byType(Scrollable))
            .first);
  }
  await _tap(tester, menu);
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

void _noOverflow(WidgetTester tester) {
  final Object? e = tester.takeException();
  expect(e, isNull, reason: '$e');
}

void main() {
  group('P11-M2 switching (#13–#22, SIMULATED)', () {
    testWidgets(
        'SW-1 (#13). stronger Normal → Guest: no PIN; persisted, sent, '
        '"active" only after the applied ack; an open session is revoked',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      expect((await fx.access.grantAccess(_notes)).isSuccess, isTrue);
      expect(fx.access.sessionFor(_notes), isNotNull);
      await _pump(tester, fx);
      expect(find.textContaining('Security profile: Normal'), findsOneWidget);
      await _openProfiles(tester);
      await _tap(tester, find.byKey(const Key('profile_tile_guest')));

      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(find.text('Guest is active.'), findsOneWidget);
      expect((await fx.profiles()).activeProfileId, 'guest');
      expect(fx.native(_notes), _L.critical);
      expect(fx.native(_maps), isNull, reason: 'never protects others');
      expect(fx.flagged, 0);
      expect(fx.access.sessionFor(_notes), isNull, reason: 'revoked');
      expect(fx.watcher.authorizedPackages, isEmpty);
      expect(find.text(_P.nativeStatus(ProfileNativeStatus.applied)),
          findsOneWidget);
      // Saved levels never change.
      final List<ProtectedApp> apps =
          (await fx.c.protectedApps.getProtectedApps()).valueOrNull!;
      expect(<String, _L>{
        for (final ProtectedApp a in apps) a.packageName: a.securityLevel,
      }, <String, _L>{
        _notes: _L.standard,
        _chat: _L.sensitive
      });
    });

    testWidgets(
        'SW-2 (#14/#15). weaker Guest → Normal: PIN required; cancel writes '
        'and sends nothing; the PIN applies it through ONE bound flag',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(profiles: _guest());
      await _pump(tester, fx);
      await _openProfiles(tester);
      final int sent = fx.watcher.receivedPolicies.length;
      await _tap(tester, find.byKey(const Key('profile_tile_normal')));
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(find.text(profileChangeConfirmTitle), findsOneWidget);
      expect(find.byKey(const Key('pin_key_biometric')), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text(_P.denied(UnprotectDenial.notAuthenticated)),
          findsOneWidget);
      expect(fx.db.profileWrites, 0);
      expect(fx.watcher.receivedPolicies.length, sent);
      expect((await fx.profiles()).activeProfileId, 'guest');

      // A wrong PIN never switches.
      await _tap(tester, find.byKey(const Key('profile_tile_normal')));
      await _enterPin(tester, _wrongPin);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect((await fx.profiles()).activeProfileId, 'guest');

      await _tap(tester, find.byKey(const Key('profile_tile_normal')));
      await _enterPin(tester);
      expect(find.text('Normal is active.'), findsOneWidget);
      expect((await fx.profiles()).activeProfileId, 'normal');
      expect(fx.native(_notes), isNull);
      expect(fx.flagged, 1);
      expect(fx.watcher.authorizedPackages, isEmpty, reason: 'no grant');
      expect(fx.access.sessionFor(_notes), isNull, reason: 'no auto-open');
    });

    testWidgets(
        'SW-3 (#24). a profile PIN never releases a held RULE reduction: '
        'blocked, profile unchanged, rule still enforced',
        (WidgetTester tester) async {
      final SecurityProfileSet kids = SecurityProfileSet.defaults()
          .withProfile(SecurityProfile(
            kind: SecurityProfileKind.kids,
            appLevels: const <String, _L>{_notes: _L.critical},
          ))
          .withActive('kids');
      final _Fx fx =
          await _Fx.create(profiles: kids, rules: <SmartRule>[_chatCritical]);
      expect((await fx.c.smartRules.deleteRule(_chatCritical.id)).isSuccess,
          isTrue);
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.watcher.lastRuleStatus, SmartRuleSyncStatus.held);
      await _pump(tester, fx);
      await _openProfiles(tester);
      await _tap(tester, find.byKey(const Key('profile_tile_normal')));
      await _enterPin(tester);
      expect(
        find.text(_P.outcome(
            const ProfileChangeOutcome(ProfileChangeStatus.blocked),
            name: 'Normal')),
        findsOneWidget,
      );
      expect(fx.flagged, 0);
      expect((await fx.profiles()).activeProfileId, 'kids');
      expect(fx.native(_chat), _L.critical);
      expect(fx.native(_notes), _L.critical);
    });

    testWidgets(
        'SW-4 (#16). equal Normal → Home (no extra protection): no PIN, no '
        'flag, applied', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pump(tester, fx);
      await _openProfiles(tester);
      await _tap(tester, find.byKey(const Key('profile_tile_home')));
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(find.text('Home is active.'), findsOneWidget);
      expect(fx.flagged, 0);
      expect((await fx.profiles()).activeProfileId, 'home');
    });

    testWidgets(
        'SW-5 (#18). a failed save claims nothing: still Normal, native '
        'untouched', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pump(tester, fx);
      await _openProfiles(tester);
      final int sent = fx.watcher.receivedPolicies.length;
      fx.db.failProfileWrites = true;
      await _tap(tester, find.byKey(const Key('profile_tile_guest')));
      expect(
        find.text(_P.outcome(
            const ProfileChangeOutcome(ProfileChangeStatus.failed),
            name: 'Guest')),
        findsOneWidget,
      );
      expect(find.text('Guest is active.'), findsNothing);
      fx.db.failProfileWrites = false;
      expect((await fx.profiles()).activeProfileId, 'normal');
      expect(fx.watcher.receivedPolicies.length, sent);
      expect(fx.native(_notes), isNull);
    });

    testWidgets(
        'SW-6 (#19). saved but native not confirming: "Saved, not confirmed"; '
        'never "active"; the Dart floor is the stricter Guest',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pump(tester, fx);
      await _openProfiles(tester);
      fx.watcher.configureFault =
          (ProtectionPolicySnapshot? p) => StaticConfigureFault.failBeforeApply;
      await _tap(tester, find.byKey(const Key('profile_tile_guest')));
      expect(
        find.text(_P.outcome(
            const ProfileChangeOutcome(ProfileChangeStatus.savedUnconfirmed),
            name: 'Guest')),
        findsOneWidget,
      );
      expect(find.text('Guest is active.'), findsNothing);
      expect(find.text(_P.nativeStatus(ProfileNativeStatus.unconfirmed)),
          findsOneWidget);
      expect(find.text(_P.nativeStatus(ProfileNativeStatus.applied)),
          findsNothing);
      expect(fx.c.protectionBootstrap.extraLevelFor(_notes, _now), _L.critical);
    });

    testWidgets(
        'SW-7 (#33). a stale screen cannot overwrite: storage changed behind '
        'it → conflict; nothing written by the switch',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pump(tester, fx);
      await _openProfiles(tester);
      expect(
        (await fx.c.securityProfiles.saveProfiles(
          SecurityProfileSet.defaults().withAdded(_trip()),
          expected: SecurityProfileSet.defaults(),
        ))
            .isSuccess,
        isTrue,
      );
      fx.db.profileWrites = 0;
      await _tap(tester, find.byKey(const Key('profile_tile_guest')));
      expect(
        find.text(_P.outcome(
            const ProfileChangeOutcome(ProfileChangeStatus.conflict),
            name: 'Guest')),
        findsOneWidget,
      );
      expect(fx.db.profileWrites, 0);
      expect((await fx.profiles()).activeProfileId, 'normal');
    });
  });

  group('P11-M2 final gate: failed lowering never shows Applied (SIMULATED)',
      () {
    testWidgets(
        'GATE-3. Guest → Normal: the flagged write fails (persisted=false) → '
        '"previous profile is still active"; never "Normal is active"; Guest '
        'stays active and is Applied only because its restore was acked',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(profiles: _guest());
      await _pump(tester, fx);
      await _openProfiles(tester);
      fx.watcher.configureFault = (ProtectionPolicySnapshot? p) =>
          p?.authorizedRuleRelaxation == true
              ? StaticConfigureFault.failAfterApply
              : null;
      await _tap(tester, find.byKey(const Key('profile_tile_normal')));
      await _enterPin(tester);
      expect(
        find.text(_P.outcome(
            const ProfileChangeOutcome(ProfileChangeStatus.notApplied),
            name: 'Normal')),
        findsOneWidget,
      );
      expect(find.text('Normal is active.'), findsNothing);
      expect((await fx.profiles()).activeProfileId, 'guest');
      expect(fx.native(_notes), _L.critical);
      expect(
          fx.watcher.receivedPolicies.last!.authorizedRuleRelaxation, isFalse);
      // The active tile is still Guest, confirmed by the restore's ack.
      expect(
        find.descendant(
          of: find.byKey(const Key('profile_tile_guest')),
          matching: find.byKey(const Key('profile_active_pill')),
        ),
        findsOneWidget,
      );
      expect(find.text(_P.nativeStatus(ProfileNativeStatus.applied)),
          findsOneWidget);
    });

    testWidgets(
        'GATE-4. the flagged write AND the recovery fail → "Couldn\'t confirm '
        'the change"; no tile shows Applied; Guest is still the saved profile',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(profiles: _guest());
      await _pump(tester, fx);
      await _openProfiles(tester);
      bool flagged = false;
      fx.watcher.configureFault = (ProtectionPolicySnapshot? p) {
        if (p?.authorizedRuleRelaxation == true) flagged = true;
        return flagged ? StaticConfigureFault.failBeforeApply : null;
      };
      await _tap(tester, find.byKey(const Key('profile_tile_normal')));
      await _enterPin(tester);
      expect(
        find.text(_P.outcome(
            const ProfileChangeOutcome(ProfileChangeStatus.unknown),
            name: 'Normal')),
        findsOneWidget,
      );
      expect(find.text('Normal is active.'), findsNothing);
      expect(find.text(_P.nativeStatus(ProfileNativeStatus.applied)),
          findsNothing);
      expect((await fx.profiles()).activeProfileId, 'guest');
      expect(fx.native(_notes), _L.critical);
    });
  });

  group('P11-M2 custom profile management (#1–#12, SIMULATED)', () {
    testWidgets(
        'MG-1. create: name validation (empty, taken); an inactive profile '
        'is saved WITHOUT contacting native and without a proof',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pump(tester, fx);
      await _openProfiles(tester);
      final int configures = fx.watcher.configureCalls;
      await _tap(tester, find.byKey(const Key('profile_new')));
      expect(find.byType(ProfileEditorScreen), findsOneWidget);
      await _tap(tester, find.byKey(const Key('profile_editor_save')));
      expect(find.text('Enter a name.'), findsOneWidget);
      await tester.enterText(
          find.byKey(const Key('profile_editor_name')), 'GUEST');
      await _tap(tester, find.byKey(const Key('profile_editor_save')));
      expect(find.text(_P.nameTaken), findsOneWidget);
      await tester.enterText(
          find.byKey(const Key('profile_editor_name')), ' Travel ');
      await _tap(tester,
          find.byKey(const Key('profile_editor_app_${_chat}_critical')));
      await _tap(tester, find.byKey(const Key('profile_editor_save')));

      expect(find.byType(ProfileEditorScreen), findsNothing);
      expect(find.text('Saved.'), findsOneWidget);
      final SecurityProfileSet s = await fx.profiles();
      final SecurityProfile travel = s.customProfiles.single;
      expect(travel.name, 'Travel');
      expect(travel.appLevels, const <String, _L>{_chat: _L.critical});
      expect(s.activeProfileId, 'normal');
      expect(fx.watcher.configureCalls, configures, reason: 'no native');
      expect(find.byKey(Key('profile_tile_${travel.id}')), findsOneWidget);
      // The editor only offers protected apps (never enrols Maps).
      expect(find.byKey(const Key('profile_editor_app_${_maps}_critical')),
          findsNothing);
    });

    testWidgets(
        'MG-2. leaving with unsaved changes asks; Keep editing stays; '
        'Discard changes leaves and writes nothing',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pump(tester, fx);
      await _openProfiles(tester);
      await _tap(tester, find.byKey(const Key('profile_new')));
      await tester.enterText(
          find.byKey(const Key('profile_editor_name')), 'Draft');
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text(_P.discardTitle), findsOneWidget);
      await tester.tap(find.byKey(const Key('profile_keep_editing')));
      await tester.pumpAndSettle();
      expect(find.byType(ProfileEditorScreen), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profile_discard')));
      await tester.pumpAndSettle();
      expect(find.byType(ProfileEditorScreen), findsNothing);
      expect(fx.db.profileWrites, 0);
    });

    testWidgets(
        'MG-3. a failed save keeps the draft and claims nothing; retry with '
        'the same id succeeds (no duplicate)', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pump(tester, fx);
      await _openProfiles(tester);
      await _tap(tester, find.byKey(const Key('profile_new')));
      await tester.enterText(
          find.byKey(const Key('profile_editor_name')), 'Keep me');
      fx.db.failProfileWrites = true;
      await _tap(tester, find.byKey(const Key('profile_editor_save')));
      expect(find.byType(ProfileEditorScreen), findsOneWidget);
      expect(find.byKey(const Key('profile_editor_message')), findsOneWidget);
      expect(find.text('Keep me'), findsOneWidget);
      fx.db.failProfileWrites = false;
      expect((await fx.profiles()).customProfiles, isEmpty);
      await _tap(tester, find.byKey(const Key('profile_editor_save')));
      expect(find.byType(ProfileEditorScreen), findsNothing);
      expect((await fx.profiles()).customProfiles, hasLength(1));
    });

    testWidgets(
        'MG-4 (#5). editing the ACTIVE profile so it lowers protection needs '
        'the PIN; with it, applied', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
        profiles: SecurityProfileSet.defaults()
            .withAdded(_trip())
            .withActive('custom-00000000000a'),
      );
      expect(fx.native(_notes), _L.critical);
      await _pump(tester, fx);
      await _openProfiles(tester);
      await _menu(tester, 'custom-00000000000a', _P.edit);
      await _tap(tester, find.byKey(const Key('profile_editor_all_none')));
      await _tap(tester, find.byKey(const Key('profile_editor_save')));
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await _enterPin(tester);
      expect(find.text('Trip is active.'), findsOneWidget);
      expect(fx.native(_notes), isNull);
      expect(fx.flagged, 1);
    });

    testWidgets(
        'MG-5 (#6). editing an INACTIVE profile never needs a PIN and never '
        'touches native', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pump(tester, fx);
      await _openProfiles(tester);
      final int configures = fx.watcher.configureCalls;
      await _menu(tester, 'home', _P.edit);
      expect(find.byKey(const Key('profile_editor_name')), findsNothing,
          reason: 'presets keep their name');
      await _tap(tester, find.byKey(const Key('profile_editor_all_critical')));
      await _tap(tester, find.byKey(const Key('profile_editor_save')));
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(fx.watcher.configureCalls, configures);
      // No authorization and no enforcement change (final gate item 6).
      expect(fx.flagged, 0);
      expect(fx.watcher.authorizedPackages, isEmpty);
      expect(fx.c.protectionBootstrap.extraLevelFor(_notes, _now), isNull);
      expect(fx.native(_notes), isNull);
      expect(
          (await fx.profiles())
              .byKind(SecurityProfileKind.home)
              .allProtectedLevel,
          _L.critical);
      // Lowering an inactive profile is free as well (not enforced).
      await _menu(tester, 'home', _P.edit);
      await _tap(tester, find.byKey(const Key('profile_editor_all_none')));
      await _tap(tester, find.byKey(const Key('profile_editor_save')));
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(fx.watcher.configureCalls, configures);
    });

    testWidgets(
        'MG-6 (#7). deleting the ACTIVE custom profile falls back to Normal; '
        'it lowers protection, so the PIN is required',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
        profiles: SecurityProfileSet.defaults()
            .withAdded(_trip())
            .withActive('custom-00000000000a'),
      );
      await _pump(tester, fx);
      await _openProfiles(tester);
      await _menu(tester, 'custom-00000000000a', _P.delete);
      expect(find.text(_P.deleteActiveBody), findsOneWidget);
      await tester.tap(find.byKey(const Key('profile_delete_confirm')));
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await _enterPin(tester);
      final SecurityProfileSet s = await fx.profiles();
      expect(s.activeProfileId, 'normal');
      expect(s.customProfiles, isEmpty);
      expect(fx.native(_notes), isNull);
    });

    testWidgets(
        'MG-7 (#3). duplicating Guest creates an editable custom copy with '
        'the same protection', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pump(tester, fx);
      await _openProfiles(tester);
      await _menu(tester, 'guest', _P.duplicate);
      expect(find.text('Guest copy'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('profile_editor_save')));
      final SecurityProfile copy = (await fx.profiles()).customProfiles.single;
      expect(copy.name, 'Guest copy');
      expect(copy.allProtectedLevel, _L.critical);
      expect(copy.isEditable, isTrue);
    });

    testWidgets(
        'MG-8 (#10). corrupt / newer documents: error states, no actions, '
        'nothing overwritten', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      fx.db.corruptProfiles = '{"version":2,"oops":1}';
      await _pump(tester, fx);
      expect(find.text(_P.corrupt), findsOneWidget);
      await _openProfiles(tester);
      expect(find.byKey(const Key('profiles_error')), findsOneWidget);
      expect(find.byKey(const Key('profile_new')), findsNothing);
      expect(find.byKey(const Key('profile_tile_guest')), findsNothing);
      expect(fx.db.profileWrites, 0);
      fx.db.corruptProfiles =
          '{"version":99,"activeProfileId":"normal","profiles":[]}';
      await _tap(tester, find.byKey(const Key('profiles_retry')));
      expect(find.text(_P.unsupported), findsOneWidget);
    });
  });

  group('P11-M2 CR-2 proof isolation with real PIN proofs (#23–#28)', () {
    late GlobalKey<NavigatorState> key;
    DateTime now = _now;

    Future<UnprotectAuthorization> mint(
      WidgetTester tester,
      _Fx fx,
      Set<String> packages,
      UnprotectIntent intent,
    ) async {
      UnprotectRequestResult? result;
      requestUnprotectAuthorization(
        navigator: key.currentState!,
        credentials: fx.c.auth,
        packages: packages,
        clock: () => now,
        intent: intent,
      ).then((UnprotectRequestResult r) => result = r);
      await tester.pumpAndSettle();
      await _enterPin(tester);
      return result!.authorization!;
    }

    Future<_Fx> host(WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      key = GlobalKey<NavigatorState>();
      now = _now;
      await tester.pumpWidget(
        AppScope(
          container: fx.c,
          child: MaterialApp(
            navigatorKey: key,
            theme: AppTheme.dark,
            home: const Scaffold(body: SizedBox()),
          ),
        ),
      );
      return fx;
    }

    testWidgets(
        'CR-1 (#25/#27). a PROFILE proof can never unprotect, downgrade or '
        'write a rule reduction; nothing changes', (WidgetTester tester) async {
      final _Fx fx = await host(tester);
      final UnprotectAuthorization p = await mint(
          tester, fx, <String>{_notes, _chat}, UnprotectIntent.profileChange);
      expect(
          (await removeProtectionWith(p, fx.c.protectedApps, _notes,
                  clock: () => now))
              .isFailure,
          isTrue);
      expect(
          (await lowerSecurityLevelWith(
                  p, fx.c.protectedApps, _chat, _L.standard,
                  clock: () => now))
              .isFailure,
          isTrue);
      int writes = 0;
      expect(
          (await relaxSmartRulesWith<void>(p, <String>{_notes}, () async {
            writes++;
            return Result.success(null);
          }, clock: () => now))
              .isFailure,
          isTrue);
      expect(writes, 0);
      expect(
          consumeBoundRelaxation(
              p, <String>{_notes}, BoundRelaxationIntent.ruleReduction,
              clock: () => now),
          isFalse);
      expect(
          consumeBoundRelaxation(
              p, <String>{_notes}, BoundRelaxationIntent.confirmSaved,
              clock: () => now),
          isFalse);
      expect(
          (await fx.c.protectedApps.getProtectedApps()).valueOrNull!.length, 2);
      // ...but it does authorize exactly one profile flag in scope.
      expect(
          consumeBoundRelaxation(
              p, <String>{_notes}, BoundRelaxationIntent.profileChange,
              clock: () => now),
          isTrue);
      expect(
          consumeBoundRelaxation(
              p, <String>{_chat}, BoundRelaxationIntent.profileChange,
              clock: () => now),
          isFalse,
          reason: 'one flag per proof');
    });

    testWidgets(
        'CR-2 (#25/#26). a DOWNGRADE / unprotect proof can never authorize a '
        'profile flag or a rule flag', (WidgetTester tester) async {
      final _Fx fx = await host(tester);
      final UnprotectAuthorization d = await mint(
          tester, fx, <String>{_notes, _chat}, UnprotectIntent.packageChange);
      for (final BoundRelaxationIntent i in BoundRelaxationIntent.values) {
        expect(consumeBoundRelaxation(d, <String>{_notes}, i, clock: () => now),
            isFalse,
            reason: '$i');
      }
      // The downgrade itself still works exactly as before (Phase 8).
      expect(
          (await lowerSecurityLevelWith(
                  d, fx.c.protectedApps, _chat, _L.standard,
                  clock: () => now))
              .isSuccess,
          isTrue);
    });

    testWidgets(
        'CR-3 (#23). a RULE proof flags only the packages its own rule write '
        'consumed, once; never a profile change', (WidgetTester tester) async {
      final _Fx fx = await host(tester);
      final UnprotectAuthorization r = await mint(
          tester, fx, <String>{_notes, _chat}, UnprotectIntent.packageChange);
      expect(
          (await relaxSmartRulesWith<void>(
                  r, <String>{_notes}, () async => Result.success(null),
                  clock: () => now))
              .isSuccess,
          isTrue);
      expect(
          consumeBoundRelaxation(
              r, <String>{_notes}, BoundRelaxationIntent.profileChange,
              clock: () => now),
          isFalse);
      expect(
          consumeBoundRelaxation(
              r, <String>{_notes, _chat}, BoundRelaxationIntent.ruleReduction,
              clock: () => now),
          isFalse,
          reason: 'chat was never written');
      // A rule flag is bounded in time as well: the write-consumed set alone
      // never keeps a proof usable past maxAge (or with the clock moved back).
      expect(
          consumeBoundRelaxation(
              r, <String>{_notes}, BoundRelaxationIntent.ruleReduction,
              clock: () => now.add(
                  UnprotectAuthorization.maxAge + const Duration(seconds: 1))),
          isFalse,
          reason: 'expired rule proof');
      expect(
          consumeBoundRelaxation(
              r, <String>{_notes}, BoundRelaxationIntent.ruleReduction,
              clock: () => now.subtract(const Duration(seconds: 1))),
          isFalse,
          reason: 'clock moved back');
      expect(
          consumeBoundRelaxation(
              r, <String>{_notes}, BoundRelaxationIntent.ruleReduction,
              clock: () => now),
          isTrue);
      expect(
          consumeBoundRelaxation(
              r, <String>{_notes}, BoundRelaxationIntent.ruleReduction,
              clock: () => now),
          isFalse,
          reason: 'single use');
    });

    testWidgets(
        'CR-4 (#28). profile proofs: out of scope, expired, clock moved back '
        'and empty sets are refused', (WidgetTester tester) async {
      final _Fx fx = await host(tester);
      final UnprotectAuthorization p = await mint(
          tester, fx, <String>{_notes}, UnprotectIntent.profileChange);
      expect(
          consumeBoundRelaxation(
              p, <String>{_chat}, BoundRelaxationIntent.profileChange,
              clock: () => now),
          isFalse,
          reason: 'out of scope');
      expect(
          consumeBoundRelaxation(
              p, <String>{}, BoundRelaxationIntent.profileChange,
              clock: () => now),
          isFalse);
      expect(
          consumeBoundRelaxation(
              p, <String>{_notes}, BoundRelaxationIntent.profileChange,
              clock: () => now.subtract(const Duration(seconds: 1))),
          isFalse,
          reason: 'clock moved back');
      expect(
          consumeBoundRelaxation(
              p, <String>{_notes}, BoundRelaxationIntent.profileChange,
              clock: () => now.add(
                  UnprotectAuthorization.maxAge + const Duration(seconds: 1))),
          isFalse,
          reason: 'expired');
      // The confirmSaved proof is separate as well.
      final UnprotectAuthorization c = await mint(
          tester, fx, <String>{_notes}, UnprotectIntent.confirmSaved);
      expect(
          consumeBoundRelaxation(
              c, <String>{_notes}, BoundRelaxationIntent.profileChange,
              clock: () => now),
          isFalse);
      expect(
          consumeBoundRelaxation(
              c, <String>{_notes}, BoundRelaxationIntent.confirmSaved,
              clock: () => now),
          isTrue);
    });
  });

  group('P11-M2 session safety (#34–#40, SIMULATED)', () {
    testWidgets(
        'SS-1. lockout persists across switching; a stronger switch needs no '
        'PIN and resets nothing; a weaker one cannot be confirmed while '
        'locked out', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      AuthAttemptResult? last;
      for (int i = 0; i < 20 && last is! AuthLockedOut; i++) {
        last = (await fx.c.auth.authenticatePin(_wrongPin)).valueOrNull;
      }
      expect(last, isA<AuthLockedOut>());
      final CredentialState before = (await fx.c.auth.status()).valueOrNull!;
      await _pump(tester, fx);
      await _openProfiles(tester);
      await _tap(tester, find.byKey(const Key('profile_tile_guest')));
      expect(find.text('Guest is active.'), findsOneWidget);
      final CredentialState after = (await fx.c.auth.status()).valueOrNull!;
      expect(after.lockedOutUntil, before.lockedOutUntil);
      expect(after.failedAttempts, before.failedAttempts);
      await _tap(tester, find.byKey(const Key('profile_tile_normal')));
      expect(find.text(PinUnlockScreen.lockedOutTitle), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect((await fx.profiles()).activeProfileId, 'guest');
    });

    testWidgets(
        'SS-2. a pending challenge survives a switch in either direction; '
        'no package is authorized; Recents/grace are not extended',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(profiles: _guest());
      fx.watcher.challengePending = true;
      await _pump(tester, fx);
      await _openProfiles(tester);
      await _tap(tester, find.byKey(const Key('profile_tile_normal')));
      await _enterPin(tester);
      expect(fx.watcher.challengePending, isTrue);
      expect(fx.watcher.authorizedPackages, isEmpty);
      expect(fx.access.departureAtFor(_notes), isNull);
      await _tap(tester, find.byKey(const Key('profile_tile_guest')));
      expect(fx.watcher.challengePending, isTrue);
      expect(fx.watcher.authorizedPackages, isEmpty);
    });

    testWidgets(
        'SS-3. Guest → Normal leaves an existing Critical grant Critical '
        '(no grace inherited); Normal → Guest revokes a Standard session at '
        'once', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      final _Grant standard = await _grant(fx, _notes);
      expect(standard.level, _L.standard);
      await _pump(tester, fx);
      await _openProfiles(tester);
      await _tap(tester, find.byKey(const Key('profile_tile_guest')));
      expect(fx.access.sessionFor(_notes), isNull);
      final _Grant critical = await _grant(fx, _notes);
      expect(critical.level, _L.critical);
      await _tap(tester, find.byKey(const Key('profile_tile_normal')));
      await _enterPin(tester);
      expect(fx.access.sessionFor(_notes)?.securityLevel, _L.critical,
          reason: 'the existing grant is not upgraded to Standard grace');
    });
  });

  group('P11-M2 UI (#41–#46, SIMULATED)', () {
    for (final (String name, ThemeData theme) in <(String, ThemeData)>[
      ('light', AppTheme.light),
      ('dark', AppTheme.dark),
    ]) {
      testWidgets(
          'UI-1. 320 dp, 2× text, $name theme: Smart card, list and editor '
          'render without overflow', (WidgetTester tester) async {
        final _Fx fx = await _Fx.create(
          profiles: SecurityProfileSet.defaults()
              .withAdded(_trip(name: 'A rather long profile name!!')),
        );
        await _pump(tester, fx,
            size: const Size(320, 1400), textScale: 2.0, theme: theme);
        _noOverflow(tester);
        await _openProfiles(tester);
        _noOverflow(tester);
        await _menu(tester, 'custom-00000000000a', _P.edit);
        _noOverflow(tester);
        await tester.ensureVisible(
            find.byKey(const Key('profile_editor_app_${_chat}_critical')));
        await tester.pumpAndSettle();
        _noOverflow(tester);
      });
    }

    testWidgets(
        'UI-2 (TalkBack). the active profile is announced as selected; level '
        'choices are labelled with app and level', (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final _Fx fx = await _Fx.create(profiles: _guest());
      await _pump(tester, fx);
      await _openProfiles(tester);
      final SemanticsNode tile =
          tester.getSemantics(find.byKey(const Key('profile_tile_guest')));
      final SemanticsData data = tile.getSemanticsData();
      expect(tile, isSemantics(isSelected: true));
      final List<String> lines = data.label.split('\n');
      expect(lines.first, 'Guest, Active');
      expect(lines.skip(1), isNot(contains('Guest')),
          reason: 'name not read twice');
      expect(lines.skip(1), isNot(contains(_P.active)),
          reason: '"Active" not read twice');
      expect(lines, contains('All protected apps: Critical'));
      expect(lines, contains(_P.nativeStatus(ProfileNativeStatus.applied)));
      // An inactive tile is a button named after the profile.
      final SemanticsNode normal =
          tester.getSemantics(find.byKey(const Key('profile_tile_normal')));
      expect(normal, isSemantics(isSelected: false, isButton: true));
      expect(normal.getSemanticsData().label.split('\n').first, 'Normal');
      await _menu(tester, 'kids', _P.edit);
      expect(find.bySemanticsLabel('Chat: Critical'), findsOneWidget);
      expect(find.bySemanticsLabel('All protected apps: No extra'),
          findsOneWidget);
      handle.dispose();
    });

    testWidgets(
        'UI-3. the Smart card never shows "Applied" before an ack: '
        'Not checked yet → Applied after the first sync',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      expect(
        profileNativeStatus(
          saved: SecurityProfileSet.defaults(),
          record: null,
          protectedPackages: const <String>{_notes},
        ),
        ProfileNativeStatus.notChecked,
      );
      expect(
        profileNativeStatus(
          saved: null,
          record: fx.c.protectionBootstrap.lastRuleExchange,
          protectedPackages: const <String>{_notes},
        ),
        ProfileNativeStatus.unavailable,
      );
      // Saved Guest, but the last exchange carried Normal → unconfirmed.
      expect(
        profileNativeStatus(
          saved: _guest(),
          record: fx.c.protectionBootstrap.lastRuleExchange,
          protectedPackages: const <String>{_notes, _chat},
        ),
        ProfileNativeStatus.unconfirmed,
      );
      await _pump(tester, fx);
      expect(find.textContaining(_P.nativeStatus(ProfileNativeStatus.applied)),
          findsOneWidget);
    });
  });
}

typedef _Grant = ({_L level});

Future<_Grant> _grant(_Fx fx, String pkg) async {
  final Result<dynamic> r = await fx.access.grantAccess(pkg);
  expect(r.isSuccess, isTrue);
  return (level: fx.access.sessionFor(pkg)!.securityLevel);
}
