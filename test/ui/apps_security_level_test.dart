// Phase 8 / M1 — per-app security level UI and security isolation (8B).
// Phase 8 / M2 updated the M1-only contract tests (marked "M2:"): levels
// are now enforced and transported, and lowering a level needs CR-2.
//
// SIMULATED: production Apps screen, level sheet, repository, credential
// manager, access controller, lock-challenge host and protection bootstrap
// over the in-memory container (static native fakes). No device, no real
// SQLite file, no Android challenge window. Physical-device QA is deferred
// to the combined Phase 6–10 round (docs/regression.md).

import 'dart:async';
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
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/security/credentials/credential_state.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/ui/screens/apps/apps_screen.dart';
import 'package:smart_app_lock/ui/screens/apps/security_level_sheet.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';

const String _pin = '1234';
const String _wa = 'com.whatsapp';
const String _ig = 'com.instagram';
const String _bank = 'com.example.bank';

const List<AppEntry> _seed = <AppEntry>[
  AppEntry(packageName: _wa, label: 'WhatsApp'),
  AppEntry(packageName: _ig, label: 'Instagram'),
  AppEntry(packageName: _bank, label: 'Bank'),
];

/// Counts level writes; optional gate and failure (simulated DB).
class _Db extends InMemoryLocalDatabase {
  int levelWrites = 0;
  Completer<void>? gate;
  bool failLevelWrites = false;

  @override
  Future<bool> updateProtectedAppSecurityLevel(
    String packageName,
    AppSecurityLevel level,
  ) async {
    levelWrites++;
    final Completer<void>? g = gate;
    if (g != null) await g.future;
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

  static Future<_Fx> create({
    List<String> protect = const <String>[_wa],
    bool full = false,
  }) async {
    final _Db db = _Db();
    final AppContainer c = AppContainer.inMemory(
      apps: _seed,
      database: db,
      accessibilityEnabled: full,
      overlayGranted: full,
    );
    await c.auth.enrollPin(_pin);
    for (final String p in protect) {
      await c.protectedApps.add(
        ProtectedApp(
          packageName: p,
          label: p,
          addedAt: DateTime(2026, 11, 2),
        ),
      );
    }
    await c.protectionBootstrap.synchronize();
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
  tester.view.physicalSize = const Size(800, 1600);
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
Finder _levelLabel(String p) => find.byKey(Key('app_level_$p'));
Finder _option(AppSecurityLevel l) =>
    find.byKey(SecurityLevelSheet.optionKey(l));

String? _levelText(WidgetTester tester, String p) {
  final Finder f = _levelLabel(p);
  return f.evaluate().isEmpty ? null : tester.widget<Text>(f).data;
}

Future<void> _choose(
  WidgetTester tester,
  String pkg,
  AppSecurityLevel level, {
  bool settle = true,
}) async {
  await tester.tap(_tile(pkg));
  await tester.pumpAndSettle();
  expect(find.byType(SecurityLevelSheet), findsOneWidget);
  await tester.tap(_option(level));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
}

Future<void> _enterPin(WidgetTester tester, String pin) async {
  for (final String d in pin.split('')) {
    await tester.tap(find.byKey(Key('pin_key_$d')));
    await tester.pumpAndSettle();
  }
}

void main() {
  group('Apps tab: per-app level selection (SIMULATED)', () {
    testWidgets(
        'a protected row shows its level (Standard by default); an '
        'unprotected row shows none and a tap opens nothing',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pumpApps(tester, fx.c);
      expect(_levelText(tester, _wa),
          AppsScreen.levelSuffix(AppSecurityLevel.standard));
      expect(find.text(AppsScreen.protectedLabel), findsOneWidget);
      expect(_levelLabel(_ig), findsNothing);
      await tester.tap(_tile(_ig));
      await tester.pumpAndSettle();
      expect(find.byType(SecurityLevelSheet), findsNothing);
      expect(fx.db.levelWrites, 0);
    });

    testWidgets(
        'the sheet explains the levels, marks the current one and says how '
        'levels behave (M2: enforced; lowering needs PIN or pattern)',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pumpApps(tester, fx.c);
      await tester.tap(_tile(_wa));
      await tester.pumpAndSettle();
      expect(find.text(SecurityLevelSheet.title('WhatsApp')), findsOneWidget);
      expect(find.text(SecurityLevelSheet.levelNotice), findsOneWidget);
      for (final AppSecurityLevel l in AppSecurityLevel.values) {
        expect(_option(l), findsOneWidget);
        expect(find.text(l.description), findsOneWidget);
      }
      expect(find.text('Standard (current)'), findsOneWidget);
      final SemanticsHandle h = tester.ensureSemantics();
      expect(
        tester.getSemantics(_option(AppSecurityLevel.standard)),
        isSemantics(
          isInMutuallyExclusiveGroup: true,
          hasCheckedState: true,
          isChecked: true,
          isSelected: true,
          hasTapAction: true,
          label: 'Standard (current)\n${AppSecurityLevel.standard.description}',
        ),
      );
      expect(
        tester.getSemantics(_option(AppSecurityLevel.critical)),
        isSemantics(
          isInMutuallyExclusiveGroup: true,
          hasCheckedState: true,
          isChecked: false,
          hasTapAction: true,
        ),
      );
      expect(tester.getSize(_option(AppSecurityLevel.critical)).height,
          greaterThanOrEqualTo(48));
      h.dispose();
    });

    testWidgets(
        'Sensitive → Critical → Standard: each is saved, shown only after '
        'the write, and survives a screen restart (M2: the downgrade to '
        'Standard is confirmed with the PIN first)',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pumpApps(tester, fx.c);
      for (final AppSecurityLevel l in <AppSecurityLevel>[
        AppSecurityLevel.sensitive,
        AppSecurityLevel.critical,
        AppSecurityLevel.standard,
      ]) {
        await _choose(tester, _wa, l);
        if (l == AppSecurityLevel.standard) await _enterPin(tester, _pin);
        expect(_levelText(tester, _wa), AppsScreen.levelSuffix(l));
        expect(find.text(AppsScreen.levelSaved('WhatsApp', l)), findsOneWidget);
        expect(await fx.level(_wa), l);
        ScaffoldMessenger.of(tester.element(find.byType(AppsScreen)))
            .removeCurrentSnackBar();
        await tester.pumpAndSettle();
      }
      await _choose(tester, _wa, AppSecurityLevel.critical);
      // "Restart": tear the screen down and rebuild over the same store.
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpApps(tester, fx.c);
      expect(_levelText(tester, _wa),
          AppsScreen.levelSuffix(AppSecurityLevel.critical));
      expect(fx.db.levelWrites, 4);
    });

    testWidgets('levels of different apps are independent',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(protect: <String>[_wa, _bank]);
      await _pumpApps(tester, fx.c);
      await _choose(tester, _bank, AppSecurityLevel.critical);
      expect(_levelText(tester, _bank),
          AppsScreen.levelSuffix(AppSecurityLevel.critical));
      expect(_levelText(tester, _wa),
          AppsScreen.levelSuffix(AppSecurityLevel.standard));
      expect(await fx.level(_wa), AppSecurityLevel.standard);
    });

    testWidgets(
        'dismissing the sheet or choosing the current level writes '
        'nothing', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pumpApps(tester, fx.c);
      await tester.tap(_tile(_wa));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(20, 20)); // barrier
      await tester.pumpAndSettle();
      expect(find.byType(SecurityLevelSheet), findsNothing);
      await _choose(tester, _wa, AppSecurityLevel.standard);
      expect(fx.db.levelWrites, 0);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets(
        'rapid interaction: while saving the row shows Saving…, further taps '
        'are ignored, exactly one write happens', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pumpApps(tester, fx.c);
      fx.db.gate = Completer<void>();
      await _choose(tester, _wa, AppSecurityLevel.critical, settle: false);
      expect(_levelText(tester, _wa), AppsScreen.levelSavingSuffix);
      for (int i = 0; i < 3; i++) {
        await tester.tap(_tile(_wa));
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(find.byType(SecurityLevelSheet), findsNothing);
      expect(fx.db.levelWrites, 1);
      fx.db.gate!.complete();
      await tester.pumpAndSettle();
      expect(_levelText(tester, _wa),
          AppsScreen.levelSuffix(AppSecurityLevel.critical));
      expect(fx.db.levelWrites, 1);
    });

    testWidgets('a failed write is reported and the old level stays',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pumpApps(tester, fx.c);
      fx.db.failLevelWrites = true;
      await _choose(tester, _wa, AppSecurityLevel.critical);
      expect(
        find.text(AppsScreen.levelSaveFailed(AppSecurityLevel.standard)),
        findsOneWidget,
      );
      expect(_levelText(tester, _wa),
          AppsScreen.levelSuffix(AppSecurityLevel.standard));
      expect(await fx.level(_wa), AppSecurityLevel.standard);
    });

    testWidgets(
        'app unprotected elsewhere while the sheet is open: nothing is saved '
        'and nothing is re-protected', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pumpApps(tester, fx.c);
      await tester.tap(_tile(_wa));
      await tester.pumpAndSettle();
      await fx.c.protectedApps.remove(_wa);
      // Resume re-reads the persisted set (existing Phase 3F behaviour).
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await tester.tap(_option(AppSecurityLevel.critical));
      await tester.pumpAndSettle();
      expect(find.text(AppsScreen.levelNotProtectedMessage), findsOneWidget);
      expect(fx.db.levelWrites, 0);
      expect((await fx.c.protectedApps.isProtected(_wa)).valueOrNull, isFalse);
    });

    testWidgets(
        'protect via the switch → Standard; unprotect (CR-2 PIN) retires the '
        'level; protect again → Standard', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(protect: const <String>[]);
      await _pumpApps(tester, fx.c);
      await tester.tap(find.byKey(const Key('app_toggle_$_bank')));
      await tester.pumpAndSettle();
      expect(_levelText(tester, _bank),
          AppsScreen.levelSuffix(AppSecurityLevel.standard));
      await _choose(tester, _bank, AppSecurityLevel.critical);

      await tester.tap(find.byKey(const Key('app_toggle_$_bank')));
      await tester.pumpAndSettle();
      await _enterPin(tester, _pin);
      expect(
          (await fx.c.protectedApps.isProtected(_bank)).valueOrNull, isFalse);
      expect(_levelLabel(_bank), findsNothing);

      await tester.tap(find.byKey(const Key('app_toggle_$_bank')));
      await tester.pumpAndSettle();
      expect(await fx.level(_bank), AppSecurityLevel.standard);
      expect(_levelText(tester, _bank),
          AppsScreen.levelSuffix(AppSecurityLevel.standard));
    });

    testWidgets(
        'search, the protection switch and selection mode keep working; in '
        'selection mode a row tap selects, never opens the level sheet',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(protect: <String>[_wa, _bank]);
      await _pumpApps(tester, fx.c);
      await _choose(tester, _bank, AppSecurityLevel.sensitive);

      await tester.enterText(find.byKey(const Key('apps_search_field')), 'ban');
      await tester.pumpAndSettle();
      expect(find.text('WhatsApp'), findsNothing);
      expect(_levelText(tester, _bank),
          AppsScreen.levelSuffix(AppSecurityLevel.sensitive));
      await tester.tap(find.byKey(const Key('apps_search_clear')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('apps_select_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('app_row_$_bank')));
      await tester.pumpAndSettle();
      expect(find.byType(SecurityLevelSheet), findsNothing);
      expect(
        tester
            .widget<Checkbox>(find.byKey(const Key('app_check_$_bank')))
            .value,
        isTrue,
      );
      expect(fx.db.levelWrites, 1);
    });
  });

  group('Security isolation of level changes (SIMULATED)', () {
    testWidgets(
        'with a pending native challenge: level upgrades keep the ticket and '
        'never authorize, restart the watcher, change grace, touch the '
        'challenge or the lockout counters (M2: each change sends exactly '
        'one protection snapshot)', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(protect: <String>[_wa, _bank]);
      await fx.c.auth.authenticatePin('0000'); // one failed attempt
      final CredentialState before = (await fx.c.auth.status()).valueOrNull!;
      fx.watcher
        ..pendingChallenge = _bank
        ..pendingChallengeGeneration = 9;
      // M2: each change runs the existing protection sync (as protect and
      // unprotect do): one snapshot and one liveness heartbeat, no timer.
      final int configureBefore = fx.watcher.configureCalls;
      final int heartbeatBefore = fx.watcher.heartbeatCalls;
      final List<int> counters = <int>[
        fx.watcher.startCalls,
        fx.watcher.stopCalls,
        fx.watcher.setGracePeriodCalls,
        fx.watcher.authorizePackageCalls,
        fx.watcher.revokeAllAuthorizationsCalls,
        fx.overlay.markChallengeReadyCalls,
        fx.overlay.showLockChallengeCalls,
        fx.overlay.hideLockChallengeCalls,
      ];
      final Set<String> nativePackages =
          Set<String>.of(fx.watcher.protectedPackages);
      final Duration grace = fx.watcher.gracePeriod;

      await _pumpApps(tester, fx.c);
      await _choose(tester, _bank, AppSecurityLevel.critical);
      await _choose(tester, _wa, AppSecurityLevel.sensitive);
      await _choose(tester, _wa, AppSecurityLevel.critical);

      expect(fx.watcher.pendingChallenge, _bank);
      expect(fx.watcher.pendingChallengeGeneration, 9);
      expect(fx.watcher.authorizedPackages, isEmpty);
      expect(fx.watcher.configureCalls - configureBefore, 3);
      expect(fx.watcher.heartbeatCalls - heartbeatBefore, 3);
      expect(<int>[
        fx.watcher.startCalls,
        fx.watcher.stopCalls,
        fx.watcher.setGracePeriodCalls,
        fx.watcher.authorizePackageCalls,
        fx.watcher.revokeAllAuthorizationsCalls,
        fx.overlay.markChallengeReadyCalls,
        fx.overlay.showLockChallengeCalls,
        fx.overlay.hideLockChallengeCalls,
      ], counters);
      expect(fx.watcher.protectedPackages, nativePackages);
      expect(fx.watcher.gracePeriod, grace);
      expect(fx.access.sessionFor(_bank), isNull);
      expect(fx.access.sessionFor(_wa), isNull);
      final CredentialState after = (await fx.c.auth.status()).valueOrNull!;
      expect(after.failedAttempts, before.failedAttempts);
      expect(after.lockedOutUntil, before.lockedOutUntil);
      expect(after.lockoutStreak, before.lockoutStreak);
    });

    testWidgets(
        'full app: a challenge shown for a protected app stays enforced when '
        'its level changes; wrong PIN refused, only the exact PIN grants',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(protect: <String>[_bank], full: true);
      tester.view.physicalSize = const Size(1080, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(SmartAppLockApp(container: fx.c));
      await tester.pumpAndSettle();
      final StaticAccessibilityLockService a11y =
          fx.c.accessibility as StaticAccessibilityLockService;
      a11y.emitForegroundPackage(_bank);
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      // The level change commits while the challenge is on screen.
      expect(
        (await fx.c.protectedApps
                .setSecurityLevel(_bank, AppSecurityLevel.critical))
            .isSuccess,
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(fx.access.sessionFor(_bank), isNull);

      await _enterPin(tester, '9999');
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(fx.access.sessionFor(_bank), isNull);
      await _enterPin(tester, _pin);
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(fx.access.sessionFor(_bank), isNotNull,
          reason: 'M2: Critical keeps the current authenticated interaction '
              'usable (no challenge loop)');
    });

    testWidgets(
        'M2 transport: a protection sync sends the same package set and '
        'enabled flag, plus the levels of exactly those packages in the '
        'same snapshot', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(protect: <String>[_wa, _bank]);
      final Set<String> before = Set<String>.of(fx.watcher.protectedPackages);
      final bool configured = fx.watcher.protectionConfigured;
      await fx.c.protectedApps
          .setSecurityLevel(_bank, AppSecurityLevel.critical);
      await fx.c.protectedApps
          .setSecurityLevel(_wa, AppSecurityLevel.sensitive);
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.watcher.protectedPackages, before);
      expect(fx.watcher.protectionConfigured, configured);
      expect(
          fx.watcher.receivedPolicies.last!.levels, <String, AppSecurityLevel>{
        _bank: AppSecurityLevel.critical,
        _wa: AppSecurityLevel.sensitive,
      });
    });

    test(
        'M2 source contract: the Dart and Kotlin level policies use the same '
        'numbers', () {
      final String kotlin = File(
        'android/app/src/main/kotlin/com/smartapplock/app/'
        'SecurityLevelPolicy.kt',
      ).readAsStringSync();
      expect(kotlin, contains('SENSITIVE_GRACE_CAP_MS = 15_000L'));
      expect(kotlin, contains('STRICT_SESSION_WINDOW_MS = 60_000L'));
      final String dart =
          File('lib/protection/security_level_policy.dart').readAsStringSync();
      expect(dart, contains('sensitiveGraceCap = Duration(seconds: 15)'));
      expect(dart, contains('strictSessionWindow = Duration(minutes: 1)'));
    });
  });
}
