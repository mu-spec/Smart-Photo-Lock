// Phase 8 / M2 — level changes (upgrade/downgrade/CR-2/sync failure) and
// 8F recommendations through the production Apps screen.
//
// SIMULATED: production Apps screen, level sheet, CR-2 gate, repository,
// credential manager, access controller, protection bootstrap and
// preferences over the in-memory container. Native is the static watcher
// (simulated resolution mirroring PolicySnapshotResolver.kt). No device,
// no real SQLite file. Physical-device QA is deferred (docs/regression.md).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/models/security_recommendation.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/access_controller.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/ui/screens/apps/apps_screen.dart';
import 'package:smart_app_lock/ui/screens/apps/security_level_sheet.dart';
import 'package:smart_app_lock/ui/screens/apps/unprotect_gate.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';

const String _pin = '1234';
const String _wa = 'com.whatsapp'; // catalog: privacy → Sensitive
const String _vault = 'com.x8bit.bitwarden'; // catalog: password manager
const String _bank = 'com.example.bank'; // not in the catalog

const List<AppEntry> _seed = <AppEntry>[
  AppEntry(packageName: _wa, label: 'WhatsApp'),
  AppEntry(packageName: _vault, label: 'Bitwarden'),
  AppEntry(packageName: _bank, label: 'Bank'),
];

typedef _L = AppSecurityLevel;

class _Db extends InMemoryLocalDatabase {
  int levelWrites = 0;
  bool failLevelWrites = false;

  @override
  Future<bool> updateProtectedAppSecurityLevel(
    String packageName,
    AppSecurityLevel level,
  ) async {
    levelWrites++;
    if (failLevelWrites) throw StateError('simulated level write failure');
    return super.updateProtectedAppSecurityLevel(packageName, level);
  }
}

class _Fx {
  _Fx(this.c, this.db);

  final AppContainer c;
  final _Db db;

  StaticWatcherService get watcher => c.watcher as StaticWatcherService;
  StaticOverlayLockService get overlay => c.overlay as StaticOverlayLockService;
  DefaultAccessController get access =>
      c.accessController as DefaultAccessController;

  static Future<_Fx> create(Map<String, AppSecurityLevel> protect) async {
    final _Db db = _Db();
    final AppContainer c = AppContainer.inMemory(apps: _seed, database: db);
    await c.auth.enrollPin(_pin);
    for (final MapEntry<String, AppSecurityLevel> e in protect.entries) {
      await c.protectedApps.add(
        ProtectedApp(
          packageName: e.key,
          label: e.key,
          addedAt: DateTime(2026, 11, 2),
        ),
      );
      await c.protectedApps.setSecurityLevel(e.key, e.value);
    }
    await c.protectionBootstrap.synchronize();
    db.levelWrites = 0;
    return _Fx(c, db);
  }

  Future<AppSecurityLevel?> level(String pkg) async {
    for (final ProtectedApp a
        in (await c.protectedApps.getProtectedApps()).valueOrNull!) {
      if (a.packageName == pkg) return a.securityLevel;
    }
    return null;
  }
}

Future<void> _pumpApps(WidgetTester tester, AppContainer c) async {
  tester.view.physicalSize = const Size(800, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    AppScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark,
        home: const Scaffold(body: AppsScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _tile(String p) => find.byKey(Key('app_tile_$p'));
Finder _held(String p) => find.byKey(Key('app_level_held_$p'));
Finder _hint(String p) => find.byKey(Key('app_suggestion_$p'));

String? _levelText(WidgetTester tester, String p) {
  final Finder f = find.byKey(Key('app_level_$p'));
  return f.evaluate().isEmpty ? null : tester.widget<Text>(f).data;
}

Future<void> _choose(
    WidgetTester tester, String pkg, AppSecurityLevel l) async {
  await tester.tap(_tile(pkg));
  await tester.pumpAndSettle();
  expect(find.byType(SecurityLevelSheet), findsOneWidget);
  await tester.tap(find.byKey(SecurityLevelSheet.optionKey(l)));
  await tester.pumpAndSettle();
}

Future<void> _enterPin(WidgetTester tester, String pin) async {
  for (final String d in pin.split('')) {
    await tester.tap(find.byKey(Key('pin_key_$d')));
    await tester.pumpAndSettle();
  }
}

void _clearSnack(WidgetTester tester) =>
    ScaffoldMessenger.of(tester.element(find.byType(AppsScreen)))
        .removeCurrentSnackBar();

void main() {
  group('Level changes (SIMULATED)', () {
    testWidgets(
        '13. an upgrade needs no PIN and ends the old unlock window in Dart '
        'and native at once', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.standard,
      });
      fx.access.setGracePeriod(const Duration(minutes: 5));
      await fx.access.grantAccess(_bank);
      await fx.access.revokeAccess(_bank); // grace armed
      fx.watcher.authorizedPackages.add(_bank);
      await _pumpApps(tester, fx.c);

      await _choose(tester, _bank, _L.critical);
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(await fx.level(_bank), _L.critical);
      expect(fx.access.sessionFor(_bank), isNull);
      expect(await fx.access.evaluate(_bank), AccessDecision.challenge);
      expect(fx.watcher.authorizedPackages, isNot(contains(_bank)));
      expect(fx.watcher.securityLevels[_bank], _L.critical);
      expect(find.text(AppsScreen.levelSaved('Bank', _L.critical)),
          findsOneWidget);
    });

    testWidgets(
        '14. a downgrade asks for the PIN (CR-2) first; only then is it '
        'saved and sent as a confirmed downgrade', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await _pumpApps(tester, fx.c);
      final int configures = fx.watcher.configureCalls;

      await _choose(tester, _bank, _L.standard);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(find.text(lowerLevelConfirmTitle), findsOneWidget);
      expect(fx.db.levelWrites, 0, reason: 'nothing saved before the PIN');
      expect(fx.watcher.configureCalls, configures);

      await _enterPin(tester, _pin);
      expect(await fx.level(_bank), _L.standard);
      expect(fx.watcher.securityLevels[_bank], _L.standard);
      expect(fx.watcher.receivedPolicies.last!.authorizedDowngrades,
          <String>{_bank});
      expect(_levelText(tester, _bank), AppsScreen.levelSuffix(_L.standard));
      expect(_held(_bank), findsNothing);
      expect(find.text(AppsScreen.levelSaved('Bank', _L.standard)),
          findsOneWidget);
    });

    testWidgets(
        '15. cancel or a wrong PIN leaves the saved AND enforced level '
        'unchanged; nothing is sent to native', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await _pumpApps(tester, fx.c);
      final int configures = fx.watcher.configureCalls;

      await _choose(tester, _bank, _L.sensitive);
      await _enterPin(tester, '9999');
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
          find.text(AppsScreen.levelLowerNotConfirmedMessage), findsOneWidget);
      expect(await fx.level(_bank), _L.critical);
      expect(fx.db.levelWrites, 0);
      expect(fx.watcher.configureCalls, configures);
      expect(fx.watcher.securityLevels[_bank], _L.critical);
      expect(_levelText(tester, _bank), AppsScreen.levelSuffix(_L.critical));
    });

    testWidgets(
        '16. a failed write after the PIN keeps the stricter level and sends '
        'nothing to native', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await _pumpApps(tester, fx.c);
      final int configures = fx.watcher.configureCalls;
      fx.db.failLevelWrites = true;
      await _choose(tester, _bank, _L.standard);
      await _enterPin(tester, _pin);
      expect(
          find.text(AppsScreen.levelSaveFailed(_L.critical)), findsOneWidget);
      expect(await fx.level(_bank), _L.critical);
      expect(fx.watcher.configureCalls, configures);
      expect(fx.watcher.securityLevels[_bank], _L.critical);
    });

    testWidgets(
        '17a. native sync failure on an upgrade: saved, Dart enforces it, '
        'and the message never claims it is fully active',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.standard,
      });
      fx.access.setGracePeriod(const Duration(minutes: 5));
      await _pumpApps(tester, fx.c);
      fx.watcher.configureError = StateError('native write failed');
      await _choose(tester, _bank, _L.critical);
      expect(find.text(AppsScreen.levelSavedNotConfirmed('Bank', _L.critical)),
          findsOneWidget);
      expect(await fx.level(_bank), _L.critical);
      await fx.access.grantAccess(_bank);
      await fx.access.revokeAccess(_bank);
      expect(await fx.access.evaluate(_bank), AccessDecision.challenge);
    });

    testWidgets(
        '17b/18. native sync failure on a downgrade: the row and message say '
        'the stricter level is still enforced, Dart keeps it, and it stays '
        'so after a screen restart until a confirmed retry applies it',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      fx.access.setGracePeriod(const Duration(minutes: 5));
      await _pumpApps(tester, fx.c);
      fx.watcher.configureError = StateError('native write failed');
      await _choose(tester, _bank, _L.standard);
      await _enterPin(tester, _pin);
      expect(
        find.text(
          AppsScreen.levelLowerNotApplied('Bank', _L.standard, _L.critical),
        ),
        findsOneWidget,
      );
      expect(await fx.level(_bank), _L.standard);
      expect(fx.watcher.securityLevels[_bank], _L.critical);
      expect(tester.widget<Text>(_held(_bank)).data,
          AppsScreen.levelHeldSuffix(_L.critical));
      // Dart floor: no grace while native still enforces Critical.
      await fx.access.grantAccess(_bank);
      await fx.access.revokeAccess(_bank);
      expect(await fx.access.evaluate(_bank), AccessDecision.challenge);

      // Screen restart: still held (never shown as the weaker level).
      fx.watcher.configureError = null;
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpApps(tester, fx.c);
      expect(_held(_bank), findsOneWidget);

      // Retry: choosing Standard again goes through CR-2 and applies.
      await _choose(tester, _bank, _L.standard);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      await _enterPin(tester, _pin);
      expect(fx.watcher.securityLevels[_bank], _L.standard);
      expect(_held(_bank), findsNothing);
    });

    testWidgets(
        '19. a pending challenge survives upgrades and a downgrade: same '
        'ticket, no authorization, no shield change',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.standard,
        _wa: _L.standard,
      });
      fx.watcher
        ..pendingChallenge = _bank
        ..pendingChallengeGeneration = 11;
      final List<int> before = <int>[
        fx.watcher.authorizePackageCalls,
        fx.watcher.revokeAllAuthorizationsCalls,
        fx.watcher.stopCalls,
        fx.watcher.setGracePeriodCalls,
        fx.overlay.markChallengeReadyCalls,
        fx.overlay.showLockChallengeCalls,
        fx.overlay.hideLockChallengeCalls,
      ];
      await _pumpApps(tester, fx.c);
      await _choose(tester, _bank, _L.critical);
      _clearSnack(tester);
      await _choose(tester, _wa, _L.sensitive);
      _clearSnack(tester);
      await _choose(tester, _bank, _L.sensitive);
      await _enterPin(tester, _pin);
      expect(fx.watcher.pendingChallenge, _bank);
      expect(fx.watcher.pendingChallengeGeneration, 11);
      expect(fx.watcher.authorizedPackages, isEmpty);
      expect(<int>[
        fx.watcher.authorizePackageCalls,
        fx.watcher.revokeAllAuthorizationsCalls,
        fx.watcher.stopCalls,
        fx.watcher.setGracePeriodCalls,
        fx.overlay.markChallengeReadyCalls,
        fx.overlay.showLockChallengeCalls,
        fx.overlay.hideLockChallengeCalls,
      ], before);
      expect(fx.access.sessionFor(_bank), isNull);
    });

    testWidgets(
        '20. rapid changes on two apps while native is slow: syncs are '
        'serialized in order and native ends equal to what was saved',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.standard,
        _wa: _L.standard,
      });
      await _pumpApps(tester, fx.c);
      final int before = fx.watcher.receivedPolicies.length;
      fx.watcher.configureGate = Completer<void>();
      await tester.tap(_tile(_bank));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SecurityLevelSheet.optionKey(_L.critical)));
      await tester.pumpAndSettle(); // bank's sync is blocked in native
      await tester.tap(_tile(_wa));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SecurityLevelSheet.optionKey(_L.sensitive)));
      await tester.pumpAndSettle();
      expect(fx.watcher.receivedPolicies.length - before, 1,
          reason: "wa's sync waits for bank's");
      fx.watcher.configureGate!.complete();
      fx.watcher.configureGate = null;
      await tester.pumpAndSettle();
      final List<int> revisions = fx.watcher.receivedPolicies
          .skip(before)
          .map((p) => p!.revision)
          .toList();
      expect(revisions.length, 2);
      expect(revisions[1], greaterThan(revisions[0]));
      expect(fx.watcher.securityLevels, <String, AppSecurityLevel>{
        _bank: _L.critical,
        _wa: _L.sensitive,
      });
      expect(await fx.level(_bank), _L.critical);
      expect(await fx.level(_wa), _L.sensitive);
    });
  });

  group('CR-2 downgrade proof (SIMULATED)', () {
    testWidgets(
        'lowerSecurityLevelWith: package-scoped, single-use, expiring; a '
        'refused proof writes nothing', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
        _wa: _L.critical,
        _vault: _L.critical,
      });
      DateTime now = DateTime(2026, 11, 2, 12);
      final GlobalKey<NavigatorState> key = GlobalKey<NavigatorState>();
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
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
      UnprotectRequestResult? result;
      requestUnprotectAuthorization(
        navigator: key.currentState!,
        credentials: fx.c.auth,
        packages: <String>{_bank, _wa},
        clock: () => now,
        title: lowerLevelConfirmTitle,
      ).then((UnprotectRequestResult r) => result = r);
      await tester.pumpAndSettle();
      expect(find.text(lowerLevelConfirmTitle), findsOneWidget);
      await _enterPin(tester, _pin);
      final UnprotectAuthorization auth = result!.authorization!;
      final repo = fx.c.protectedApps;

      // Out of scope.
      expect(
        (await lowerSecurityLevelWith(auth, repo, _vault, _L.standard,
                clock: () => now))
            .isFailure,
        isTrue,
      );
      // In scope, fresh.
      expect(
        (await lowerSecurityLevelWith(auth, repo, _bank, _L.standard,
                clock: () => now))
            .isSuccess,
        isTrue,
      );
      // Single use.
      expect(
        (await lowerSecurityLevelWith(auth, repo, _bank, _L.sensitive,
                clock: () => now))
            .isFailure,
        isTrue,
      );
      // Expired.
      now = now.add(UnprotectAuthorization.maxAge + const Duration(seconds: 1));
      expect(
        (await lowerSecurityLevelWith(auth, repo, _wa, _L.standard,
                clock: () => now))
            .isFailure,
        isTrue,
      );
      expect(await fx.level(_bank), _L.standard);
      expect(await fx.level(_wa), _L.critical);
      expect(await fx.level(_vault), _L.critical);
      expect(fx.db.levelWrites, 1);
    });
  });

  group('8F recommendations (SIMULATED)', () {
    testWidgets(
        '21/23. hints appear only on protected catalog apps below the '
        'suggested level; showing them changes nothing',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _wa: _L.standard,
        _bank: _L.standard,
      });
      final int configures = fx.watcher.configureCalls;
      await _pumpApps(tester, fx.c);
      expect(_hint(_wa), findsOneWidget);
      expect(_hint(_bank), findsNothing, reason: 'not in the catalog');
      expect(_hint(_vault), findsNothing, reason: 'not protected');
      expect(
        tester.getSemantics(_hint(_wa)).label,
        contains(AppsScreen.suggestionSemantics(_L.sensitive)),
      );
      expect(fx.db.levelWrites, 0);
      expect(fx.watcher.configureCalls, configures);
      expect(await fx.level(_wa), _L.standard);
    });

    testWidgets(
        '22. the sheet explains why; accepting is an explicit upgrade (no '
        'PIN), after which the hint disappears', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _vault: _L.sensitive,
      });
      await _pumpApps(tester, fx.c);
      expect(_hint(_vault), findsOneWidget);
      await tester.tap(_tile(_vault));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('security_level_recommendation')),
          findsOneWidget);
      expect(find.text(SensitiveAppCategory.passwordManager.reason),
          findsOneWidget);
      expect(find.text(SecurityLevelSheet.recommendationTitle(_L.critical)),
          findsOneWidget);
      await tester
          .tap(find.byKey(const Key('security_level_recommendation_accept')));
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(await fx.level(_vault), _L.critical);
      expect(fx.watcher.securityLevels[_vault], _L.critical);
      expect(_hint(_vault), findsNothing);
    });

    testWidgets(
        '24. "Don\'t suggest again" changes no level, is stored locally and '
        'is not repeated after a restart', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _wa: _L.standard,
      });
      final int configures = fx.watcher.configureCalls;
      await _pumpApps(tester, fx.c);
      await tester.tap(_tile(_wa));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const Key('security_level_recommendation_dismiss')));
      await tester.pumpAndSettle();
      expect(find.text(AppsScreen.suggestionDismissedMessage), findsOneWidget);
      expect(_hint(_wa), findsNothing);
      expect(fx.db.levelWrites, 0);
      expect(fx.watcher.configureCalls, configures);
      expect(await fx.level(_wa), _L.standard);
      expect(await fx.c.preferences.getDismissedSecurityRecommendations(),
          <String>{'com.whatsapp@sensitive'});

      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpApps(tester, fx.c);
      expect(_hint(_wa), findsNothing);
      await tester.tap(_tile(_wa));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const Key('security_level_recommendation')), findsNothing);
    });
  });
}
