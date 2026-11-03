// Phase 8 / M3 (PRD 8G) — level-change security regression and
// recommendation integrity through the production Apps screen.
//
// SIMULATED: production AppsScreen, SecurityLevelSheet, CR-2 gate
// (`unprotect_gate.dart`), CredentialManager (real attempts and lockout),
// repository, ProtectionBootstrap and access controller, over the simulated
// native watcher (StaticWatcherService). No device evidence.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/access_controller.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/ui/screens/apps/apps_screen.dart';
import 'package:smart_app_lock/ui/screens/apps/security_level_sheet.dart';
import 'package:smart_app_lock/ui/screens/apps/unprotect_gate.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/utilities/result.dart';

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

  @override
  Future<bool> updateProtectedAppSecurityLevel(
    String packageName,
    AppSecurityLevel level,
  ) async {
    levelWrites++;
    return super.updateProtectedAppSecurityLevel(packageName, level);
  }
}

class _Fx {
  _Fx(this.c, this.db);

  final AppContainer c;
  final _Db db;

  StaticWatcherService get watcher => c.watcher as StaticWatcherService;
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
          addedAt: DateTime(2026, 11, 3),
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

Future<void> _choose(
  WidgetTester tester,
  String pkg,
  AppSecurityLevel l,
) async {
  await tester.tap(find.byKey(Key('app_tile_$pkg')));
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

/// The six level transitions of 8G.
const List<(AppSecurityLevel, AppSecurityLevel)> _transitions =
    <(AppSecurityLevel, AppSecurityLevel)>[
  (_L.standard, _L.sensitive),
  (_L.standard, _L.critical),
  (_L.sensitive, _L.critical),
  (_L.critical, _L.sensitive),
  (_L.critical, _L.standard),
  (_L.sensitive, _L.standard),
];

void main() {
  group('8G level transitions through the Apps screen (SIMULATED)', () {
    for (final (AppSecurityLevel from, AppSecurityLevel to) in _transitions) {
      final bool upgrade = to.isStricterThan(from);
      testWidgets(
          '${from.label} → ${to.label}: '
          '${upgrade ? 'upgrade, no PIN, old window ends' : 'downgrade needs the PIN'}; '
          'ticket, grace and native authorization untouched',
          (WidgetTester tester) async {
        final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
          _bank: from,
        });
        // A prior unlock with a running grace window (none for Critical).
        fx.access.setGracePeriod(const Duration(minutes: 5));
        await fx.access.grantAccess(_bank);
        await fx.access.revokeAccess(_bank);
        fx.watcher
          ..pendingChallenge = _bank
          ..pendingChallengeGeneration = 7;
        final int authorizeCalls = fx.watcher.authorizePackageCalls;
        final int graceCalls = fx.watcher.setGracePeriodCalls;
        await _pumpApps(tester, fx.c);

        await _choose(tester, _bank, to);
        if (upgrade) {
          expect(find.byType(PinUnlockScreen), findsNothing);
          expect(fx.access.sessionFor(_bank), isNull);
          expect(fx.access.departureAtFor(_bank), isNull);
          expect(await fx.access.evaluate(_bank), AccessDecision.challenge);
          expect(
              fx.watcher.receivedPolicies.last!.authorizedDowngrades, isEmpty);
        } else {
          expect(find.byType(PinUnlockScreen), findsOneWidget);
          expect(find.text(lowerLevelConfirmTitle), findsOneWidget);
          expect(await fx.level(_bank), from, reason: 'nothing before PIN');
          await _enterPin(tester, _pin);
          expect(fx.watcher.receivedPolicies.last!.authorizedDowngrades,
              <String>{_bank});
        }
        expect(await fx.level(_bank), to);
        expect(fx.watcher.securityLevels[_bank], to);
        expect(fx.c.protectionBootstrap.nativeLevelFor(_bank), to,
            reason: 're-lock policy in Dart matches native');
        expect(find.text(AppsScreen.levelSaved('Bank', to)), findsOneWidget);
        expect(fx.watcher.pendingChallenge, _bank);
        expect(fx.watcher.pendingChallengeGeneration, 7);
        expect(fx.watcher.authorizePackageCalls, authorizeCalls);
        expect(fx.watcher.authorizedPackages, isNot(contains(_bank)));
        expect(fx.watcher.setGracePeriodCalls, graceCalls);
        expect(fx.access.gracePeriod, const Duration(minutes: 5));
      });
    }

    for (final (AppSecurityLevel from, AppSecurityLevel to)
        in _transitions.where(((AppSecurityLevel, AppSecurityLevel) t) =>
            t.$1.isStricterThan(t.$2))) {
      testWidgets(
          '${from.label} → ${to.label} cancelled at the PIN: nothing saved '
          'or sent', (WidgetTester tester) async {
        final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
          _bank: from,
        });
        await _pumpApps(tester, fx.c);
        final int configures = fx.watcher.configureCalls;
        await _choose(tester, _bank, to);
        expect(find.byType(PinUnlockScreen), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(await fx.level(_bank), from);
        expect(fx.db.levelWrites, 0);
        expect(fx.watcher.configureCalls, configures);
        expect(fx.watcher.securityLevels[_bank], from);
        expect(
          find.text(AppsScreen.levelLowerNotConfirmedMessage),
          findsOneWidget,
        );
      });
    }

    testWidgets(
        'a lockout on the downgrade confirmation never downgrades; the '
        'lockout is shared with the lock screen', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await _pumpApps(tester, fx.c);
      final int configures = fx.watcher.configureCalls;
      await _choose(tester, _bank, _L.standard);
      for (int attempt = 0; attempt < 4; attempt++) {
        await _enterPin(tester, '9999');
      }
      // Fifth wrong attempt: the lockout countdown starts (no settle).
      for (final String d in '9999'.split('')) {
        await tester.tap(find.byKey(Key('pin_key_$d')));
        await tester.pump(const Duration(milliseconds: 300));
      }
      await tester.pump(const Duration(seconds: 1));
      expect(
        (await fx.c.auth.status()).valueOrNull!.lockedOutUntil,
        isNotNull,
      );
      await tester.pageBack();
      for (int i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(await fx.level(_bank), _L.critical);
      expect(fx.db.levelWrites, 0);
      expect(fx.watcher.configureCalls, configures);
      expect(fx.watcher.securityLevels[_bank], _L.critical);
      expect(await fx.access.evaluate(_bank), AccessDecision.deny);
    });

    testWidgets(
        'a confirmation proof is single-use across actions (lower vs '
        'unprotect) and refuses a clock that moved backwards',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
        _wa: _L.critical,
        _vault: _L.critical,
      });
      final DateTime now = DateTime(2026, 11, 3, 12);
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
      Future<UnprotectAuthorization> mint(Set<String> packages) async {
        UnprotectRequestResult? result;
        requestUnprotectAuthorization(
          navigator: key.currentState!,
          credentials: fx.c.auth,
          packages: packages,
          clock: () => now,
          title: lowerLevelConfirmTitle,
        ).then((UnprotectRequestResult r) => result = r);
        await tester.pumpAndSettle();
        await _enterPin(tester, _pin);
        return result!.authorization!;
      }

      final repo = fx.c.protectedApps;
      // Refused by the proof itself (not by a later repository check).
      void expectRefusedByProof(Result<void> r) {
        expect(r.isFailure, isTrue);
        expect(r.errorOrNull.toString(), contains('not authorized'));
      }

      final UnprotectAuthorization proof = await mint(<String>{_bank, _wa});
      expect(proof.allows(_bank, now), isTrue);
      expect(proof.allows(_wa, now), isTrue);
      expect(
        (await lowerSecurityLevelWith(proof, repo, _bank, _L.standard,
                clock: () => now))
            .isSuccess,
        isTrue,
      );
      expect(proof.allows(_bank, now), isFalse, reason: 'used by lowering');
      expect(proof.allows(_wa, now), isTrue, reason: 'package-scoped');
      expectRefusedByProof(
        await removeProtectionWith(proof, repo, _bank, clock: () => now),
      );
      expect(
        (await removeProtectionWith(proof, repo, _wa, clock: () => now))
            .isSuccess,
        isTrue,
      );
      expect(proof.allows(_wa, now), isFalse, reason: 'used by unprotect');
      expectRefusedByProof(
        await lowerSecurityLevelWith(proof, repo, _wa, _L.standard,
            clock: () => now),
      );
      final UnprotectAuthorization early = await mint(<String>{_vault});
      expectRefusedByProof(
        await lowerSecurityLevelWith(early, repo, _vault, _L.standard,
            clock: () => now.subtract(const Duration(seconds: 1))),
      );
      expect(await fx.level(_bank), _L.standard);
      expect((await repo.isProtected(_bank)).valueOrNull, isTrue);
      expect((await repo.isProtected(_wa)).valueOrNull, isFalse);
      expect(await fx.level(_vault), _L.critical);
    });
  });

  group('8G recommendation integrity (SIMULATED)', () {
    testWidgets(
        'no hint for apps already at or above the suggestion, for unknown '
        'apps, or for unprotected catalog apps; a hint never protects',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _vault: _L.critical,
        _bank: _L.standard,
      });
      await _pumpApps(tester, fx.c);
      expect(find.byKey(const Key('app_suggestion_$_vault')), findsNothing);
      expect(find.byKey(const Key('app_suggestion_$_bank')), findsNothing);
      expect(find.byKey(const Key('app_suggestion_$_wa')), findsNothing);
      expect((await fx.c.protectedApps.isProtected(_wa)).valueOrNull, isFalse);

      // The sheet of a Critical catalog app offers no (lower) suggestion.
      await tester.tap(find.byKey(const Key('app_tile_$_vault')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Suggested'), findsNothing);
      expect(find.text(SecurityLevelSheet.dismissRecommendationLabel),
          findsNothing);
      Navigator.of(tester.element(find.byType(SecurityLevelSheet))).pop();
      await tester.pumpAndSettle();
      expect(await fx.level(_vault), _L.critical);
      expect(fx.db.levelWrites, 0);
    });

    test(
        'no network path: the catalog is self-contained, no network '
        'dependency, no INTERNET permission, no HTTP/socket client', () {
      final List<String> imports = File(
        'lib/data/models/security_recommendation.dart',
      ).readAsLinesSync().where((String l) => l.startsWith('import ')).toList();
      expect(imports, <String>["import 'app_security_level.dart';"]);

      final List<String> pubspec = File('pubspec.yaml').readAsLinesSync();
      final int from = pubspec.indexOf('dependencies:');
      final int to = pubspec.indexOf('dev_dependencies:');
      final Set<String> deps = pubspec
          .sublist(from + 1, to)
          .where((String l) => RegExp(r'^  [a-z_]+:').hasMatch(l))
          .map((String l) => l.trim().split(':').first)
          .toSet();
      expect(deps, <String>{
        'flutter',
        'cupertino_icons',
        'crypto',
        'shared_preferences',
        'sqflite',
        'path',
        'flutter_secure_storage',
        'cryptography',
        'local_auth',
      });

      expect(
        File('android/app/src/main/AndroidManifest.xml')
            .readAsStringSync()
            .contains('android.permission.INTERNET'),
        isFalse,
      );

      final RegExp network =
          RegExp(r'HttpClient|package:http/|WebSocket|Socket\.connect');
      final List<String> offenders = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart'))
          .where((File f) => network.hasMatch(f.readAsStringSync()))
          .map((File f) => f.path)
          .toList();
      expect(offenders, isEmpty);
    });
  });
}
