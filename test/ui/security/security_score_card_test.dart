// Phase 9 / M2 (PRD 9F) — Security Score UI in the Security Center.
//
// SIMULATED: production widgets, MainShell, router, the Phase 7 health
// engine + monitor + controller, the real protected-app and lock-settings
// repositories over an in-memory database, and the container's static
// platform services. No Android device, Settings screen, OEM behaviour or
// native enforcement is observed; physical QA is pending
// (docs/regression.md, Phase 9 / M2).
//
// Numbers refer to the Phase 9 / M2 brief's test list (section 7).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/impl/lock_settings_repository_impl.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/protection/health/protection_health_engine.dart';
import 'package:smart_app_lock/protection/health/protection_health_monitor.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/ui/screens/apps/apps_screen.dart';
import 'package:smart_app_lock/ui/screens/health/protection_health_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/security/security_center_section.dart';
import 'package:smart_app_lock/ui/screens/security/security_score.dart';
import 'package:smart_app_lock/ui/screens/security/security_score_card.dart';
import 'package:smart_app_lock/ui/screens/security/security_screen.dart';

typedef _L = AppSecurityLevel;
typedef _C = SecurityScoreCard;

const String _pin = '2468';
const String _bank = 'com.example.bank';
const String _chat = 'com.example.chat';
const String _photos = 'com.example.photos';

/// The real in-memory store with read gates, failures and write counters.
class _Db extends InMemoryLocalDatabase {
  /// Per-read gates, consumed in order. A gated read captures its data
  /// BEFORE waiting, so a late completion carries OLD data.
  final List<Completer<void>> readGates = <Completer<void>>[];
  Object? readError;
  Object? graceError;
  Object? settingWriteError;
  int reads = 0;
  int writes = 0;
  int settingWrites = 0;

  @override
  Future<List<ProtectedApp>> getProtectedApps() async {
    reads++;
    final List<ProtectedApp> snapshot = await super.getProtectedApps();
    if (readGates.isNotEmpty) await readGates.removeAt(0).future;
    final Object? error = readError;
    if (error != null) throw error;
    return snapshot;
  }

  @override
  Future<String?> getSetting(String key) {
    final Object? error = graceError;
    if (error != null && key == LockSettingsRepositoryImpl.gracePeriodKey) {
      return Future<String?>.error(error);
    }
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) {
    settingWrites++;
    final Object? error = settingWriteError;
    if (error != null) return Future<void>.error(error);
    return super.setSetting(key, value);
  }

  @override
  Future<void> saveProtectedApp(ProtectedApp app) {
    writes++;
    return super.saveProtectedApp(app);
  }

  @override
  Future<bool> updateProtectedAppSecurityLevel(
    String packageName,
    AppSecurityLevel level,
  ) {
    writes++;
    return super.updateProtectedAppSecurityLevel(packageName, level);
  }

  @override
  Future<void> removeProtectedApp(String packageName) {
    writes++;
    return super.removeProtectedApp(packageName);
  }
}

/// A health source whose refresh fails as a whole.
class _FailingMonitor extends ProtectionHealthMonitor {
  _FailingMonitor(AppContainer c)
      : super(
          protectedApps: c.protectedApps,
          credentials: c.auth,
          installedApps: c.installedAppsService,
          accessibility: c.accessibility,
          overlay: c.overlay,
          watcher: c.watcher,
          preferences: c.preferences,
          biometrics: c.biometrics,
        );

  @override
  Future<ProtectionHealthReport> refresh({bool afterChange = false}) =>
      Future<ProtectionHealthReport>.error(StateError('simulated failure'));
}

class _Fx {
  _Fx(this.c, this.db);

  final AppContainer c;
  final _Db db;

  StaticWatcherService get watcher => c.watcher as StaticWatcherService;
  StaticOverlayLockService get overlay => c.overlay as StaticOverlayLockService;
  StaticAccessibilityLockService get accessibility =>
      c.accessibility as StaticAccessibilityLockService;
  StaticInstalledAppsService get installed =>
      c.installedAppsService as StaticInstalledAppsService;
  DefaultAccessController get access =>
      c.accessController as DefaultAccessController;

  /// A simulated-healthy device with [protect]ed apps, a PIN (unless
  /// [withPin] is false) and the re-lock [grace].
  static Future<_Fx> create(
    Map<String, AppSecurityLevel> protect, {
    bool withPin = true,
    Duration grace = Duration.zero,
  }) async {
    final _Db db = _Db();
    final AppContainer c = AppContainer.inMemory(
      database: db,
      accessibilityEnabled: true,
      overlayGranted: true,
    );
    if (withPin) await c.auth.enrollPin(_pin);
    for (final MapEntry<String, AppSecurityLevel> e in protect.entries) {
      await c.protectedApps.add(
        ProtectedApp(
          packageName: e.key,
          label: e.key.split('.').last,
          addedAt: DateTime(2026, 11, 1),
          securityLevel: e.value,
        ),
      );
    }
    await c.lockSettings.setGracePeriod(grace);
    (c.watcher as StaticWatcherService)
      ..protectionConfigured = protect.isNotEmpty && withPin
      ..running = true
      ..accessibilityServiceConnected = true
      ..shieldArmed = true
      ..challengePending = false
      ..backgroundRestricted = false
      ..powerSaveMode = false
      ..ignoringBatteryOptimizations = false
      ..sdkInt = 34;
    db.writes = 0;
    db.settingWrites = 0;
    return _Fx(c, db);
  }
}

void _tallView(WidgetTester tester, {double width = 1080}) {
  tester.view.physicalSize = Size(width, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The full app (MainShell, router, challenge host); native levels synced.
Future<void> _pumpApp(WidgetTester tester, _Fx fx, {bool sync = true}) async {
  _tallView(tester);
  addTearDown(fx.c.capabilityMonitor.dispose);
  await tester.pumpWidget(SmartAppLockApp(container: fx.c));
  await tester.pumpAndSettle();
  if (sync) await fx.c.protectionBootstrap.synchronize();
}

Future<void> _go(WidgetTester tester, String tab) async {
  await tester.tap(find.byKey(Key(tab)));
  await tester.pumpAndSettle();
}

Future<void> _openSecurity(WidgetTester tester) => _go(tester, 'nav_security');

/// Just the Security Center, for a test-specific health monitor.
Future<void> _pumpSection(
  WidgetTester tester,
  _Fx fx, {
  ProtectionHealthMonitor? monitor,
  ValueNotifier<int>? revision,
}) async {
  _tallView(tester);
  final ValueNotifier<int> rev = revision ?? ValueNotifier<int>(0);
  await tester.pumpWidget(
    AppScope(
      container: fx.c,
      child: MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ValueListenableBuilder<int>(
              valueListenable: rev,
              builder: (BuildContext context, int value, Widget? _) =>
                  SecurityCenterSection(
                healthMonitor: monitor,
                settingsRevision: value,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _inScore(Finder f) => find.descendant(
      of: find.byKey(const Key('security_center_score')),
      matching: f,
      matchRoot: true,
    );

Finder _inKey(String key, Finder f) =>
    find.descendant(of: find.byKey(Key(key)), matching: f, matchRoot: true);

/// The number shown, or null when none is shown.
int? _shownPoints(WidgetTester tester) {
  final Finder value = find.byKey(const Key('sc_score_value'));
  if (value.evaluate().isEmpty) return null;
  return int.parse(tester.widget<Text>(value).data!);
}

void _expectFactor(String key, int earned, int max) {
  expect(
    _inKey(key, find.text(_C.factorValue(earned, max))),
    findsOneWidget,
    reason: '$key should be $earned of $max',
  );
}

/// Every string the score card renders.
List<String> _scoreTexts(WidgetTester tester) =>
    _inScore(find.byType(Text)).evaluate().map((Element e) {
      final Text t = e.widget as Text;
      return t.data ?? t.textSpan?.toPlainText() ?? '';
    }).toList();

/// Honest wording: no percentages, perfection, urgency or upsell. The only
/// "guarantee" is the negated one; "bypass" appears only in the scope
/// statements.
void _expectHonestWording(WidgetTester tester) {
  final List<String> texts = _scoreTexts(tester);
  final String all = texts.join(' | ').toLowerCase();
  for (final String banned in const <String>[
    '%',
    'percent',
    'perfect',
    'fully secure',
    'fully protected',
    'unhackable',
    'impossible',
    'urgent',
    'immediately',
    'act now',
    'premium',
    'upgrade',
  ]) {
    expect(all.contains(banned), isFalse, reason: 'banned wording "$banned"');
  }
  for (final String t in texts) {
    final String l = t.toLowerCase();
    if (l.contains('guarantee')) {
      expect(l, contains('not a guarantee'), reason: t);
    }
    if (l.contains('bypass')) {
      expect(
        t == _C.description || t == _C.howLines.last,
        isTrue,
        reason: 'bypass only in the scope statements: "$t"',
      );
    }
  }
}

void main() {
  group('presentation (SIMULATED)', () {
    for (final Brightness brightness in Brightness.values) {
      testWidgets(
          '18/19. 320 dp, 2x text (${brightness.name}): provisional score, '
          'breakdown and details render without overflow; screen-reader '
          'labels state the score and each factor',
          (WidgetTester tester) async {
        final _Fx fx = await _Fx.create(
          <String, AppSecurityLevel>{_bank: _L.critical, _chat: _L.standard},
          grace: const Duration(minutes: 5),
        );
        fx.installed.usageAccessGranted = false; // ATTENTION: longest copy
        await fx.c.protectionBootstrap.synchronize();
        _tallView(tester, width: 320);
        final SemanticsHandle semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          AppScope(
            container: fx.c,
            child: MaterialApp(
              theme: AppTheme.light,
              darkTheme: AppTheme.dark,
              themeMode: brightness == Brightness.dark
                  ? ThemeMode.dark
                  : ThemeMode.light,
              builder: (BuildContext context, Widget? child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: const Scaffold(body: SecurityScreen()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('sc_score_how')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'no overflow');
        expect(find.byKey(const Key('sc_score_how_details')), findsOneWidget);

        // Critical 40 + Standard @5 min 10 -> floor(10 x 5 / 2) = 25.
        expect(_shownPoints(tester), 25);
        expect(
          find.bySemanticsLabel(
            'Provisional security score: 25 out of 100 points. Problems '
            'remain.',
          ),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel(RegExp(r'^Protection health: 0 of 60 points\. '
              r'Needs attention: ')),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel(
            RegExp(r'^Re-lock after leaving: 25 of 40 points\. '),
          ),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel(SecurityScoreCard.heading),
          findsOneWidget,
          reason: 'the heading is announced',
        );
        // The number never uses a success colour.
        final BuildContext ctx =
            tester.element(find.byKey(const Key('sc_score_value')));
        expect(
          tester
              .widget<Text>(find.byKey(const Key('sc_score_value')))
              .style
              ?.color,
          ctx.dsColors.textPrimary,
        );
        semantics.dispose();
        await fx.c.capabilityMonitor.dispose();
      });
    }

    testWidgets(
        'the score sits in the Security Center between health and the app '
        'summary; every existing Security tab control is still below',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);

      final double health =
          tester.getTopLeft(find.byKey(const Key('security_center_health'))).dy;
      final double score =
          tester.getTopLeft(find.byKey(const Key('security_center_score'))).dy;
      final double apps =
          tester.getTopLeft(find.byKey(const Key('security_center_apps'))).dy;
      expect(health < score && score < apps, isTrue);
      expect(
        find.descendant(
          of: find.byKey(const Key('security_center')),
          matching: find.byKey(const Key('security_center_score')),
        ),
        findsOneWidget,
      );
      for (final String text in <String>[
        'Authentication',
        SecurityScreen.changePinTitle,
        'Grace period',
      ]) {
        expect(find.text(text), findsWidgets, reason: text);
      }
      expect(find.byKey(const Key('grace_selector')), findsOneWidget);
    });
  });

  group('states (SIMULATED)', () {
    testWidgets(
        '6/17. SECURE with a valid setup: the number, breakdown and '
        'reductions equal the model', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
        <String, AppSecurityLevel>{
          _bank: _L.critical,
          _chat: _L.sensitive,
          _photos: _L.standard,
        },
        grace: const Duration(minutes: 1),
      );
      await _pumpApp(tester, fx);
      await _openSecurity(tester);

      // Model, from the same inputs the UI reads.
      final SecurityScoreAssessment model = SecurityScore.assess(
        SecurityScoreInputs(
          appsState: ScoreSourceState.loaded,
          apps: (await fx.c.protectedApps.getProtectedApps()).valueOrNull!,
          nativeLevelFor: fx.c.protectionBootstrap.nativeLevelFor,
          graceState: ScoreSourceState.loaded,
          grace: const Duration(minutes: 1),
          health: fx.c.protectionHealth.latest(),
        ),
      );
      expect(model.status, SecurityScoreStatus.available);
      expect(model.points, 90);
      expect(_shownPoints(tester), model.points);
      _expectFactor('sc_factor_health', 60, 60);
      _expectFactor('sc_factor_relock', 30, 40);
      expect(_inScore(find.text(_C.availableMessage)), findsOneWidget);
      expect(_inScore(find.text(_C.tierLine(RelockTier.noDelay, 1))),
          findsOneWidget);
      expect(_inScore(find.text(_C.tierLine(RelockTier.upTo15Seconds, 1))),
          findsOneWidget);
      expect(_inScore(find.text(_C.tierLine(RelockTier.upTo1Minute, 1))),
          findsOneWidget);
      expect(_inScore(find.text(_C.lowersRelock(10))), findsOneWidget);
      expect(find.byKey(const Key('sc_lowers_health')), findsNothing);
      expect(find.byKey(const Key('sc_score_provisional')), findsNothing);
      expect(find.byKey(const Key('sc_score_fix')), findsNothing);
      expect(_inScore(find.text(_C.description)), findsOneWidget);
      _expectHonestWording(tester);
    });

    testWidgets(
        'every factor at its maximum: 100 is explained as an assessment, '
        'not a perfect state', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _photos: _L.standard,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      expect(_shownPoints(tester), 100);
      expect(_inScore(find.text(_C.maxedMessage)), findsOneWidget);
      expect(find.byKey(const Key('sc_score_lowers')), findsNothing);
      _expectHonestWording(tester);
    });

    testWidgets(
        '4. first-time setup: no PIN and no apps -> setup steps, no number, '
        'no failure wording; Choose apps opens the Apps tab',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
        const <String, AppSecurityLevel>{},
        withPin: false,
      );
      await _pumpApp(tester, fx, sync: false);
      await _openSecurity(tester);

      expect(find.byKey(const Key('sc_score_setup')), findsOneWidget);
      expect(_inScore(find.text(_C.setupTitle)), findsOneWidget);
      expect(
        _inScore(find.text('${_C.setupCredentialStep} ${_C.setupAppsStep}')),
        findsOneWidget,
      );
      expect(_shownPoints(tester), isNull);
      final String all = _scoreTexts(tester).join(' ').toLowerCase();
      for (final String failure in <String>['offline', 'not working', 'fail']) {
        expect(all.contains(failure), isFalse, reason: failure);
      }
      _expectHonestWording(tester);

      await tester.tap(find.byKey(const Key('sc_score_choose_apps')));
      await tester.pumpAndSettle();
      expect(find.text(AppsScreen.description), findsOneWidget);
    });

    testWidgets('5. PIN set, no protected apps -> setup (apps step only)',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(const <String, AppSecurityLevel>{});
      await _pumpApp(tester, fx, sync: false);
      await _openSecurity(tester);
      expect(_inScore(find.text(_C.setupAppsStep)), findsOneWidget);
      expect(_inScore(find.text(_C.setupCredentialStep)), findsNothing);
      expect(_shownPoints(tester), isNull);
    });

    testWidgets(
        '7. ATTENTION: provisional tag, health 0 of 60 with the problem '
        'named, problems-remain message; Fix protection opens Health Details',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      fx.installed.usageAccessGranted = false;
      await _pumpApp(tester, fx);
      await _openSecurity(tester);

      expect(_shownPoints(tester), 40);
      expect(find.byKey(const Key('sc_score_provisional')), findsOneWidget);
      expect(_inScore(find.text(_C.provisionalMessage)), findsOneWidget);
      _expectFactor('sc_factor_health', 0, 60);
      expect(
        _inKey('sc_factor_health', find.text(_C.healthProblem)),
        findsOneWidget,
      );
      // The problem is named in the Protection Health card and (Phase 9 /
      // M3) once as a recommendation; never in the score card.
      expect(find.byKey(const Key('sc_top_issue')), findsOneWidget);
      final String issueTitle =
          tester.widget<Text>(find.byKey(const Key('sc_top_issue'))).data!;
      expect(_inKey('security_center_health', find.text(issueTitle)),
          findsOneWidget);
      expect(_inKey('security_center_recommendations', find.text(issueTitle)),
          findsOneWidget);
      expect(find.text(issueTitle), findsNWidgets(2));
      expect(_inScore(find.textContaining(issueTitle)), findsNothing);
      expect(_inScore(find.text(_C.lowersHealth(60))), findsOneWidget);
      _expectHonestWording(tester);

      await tester.tap(find.byKey(const Key('sc_score_fix')));
      await tester.pumpAndSettle();
      expect(find.byType(ProtectionHealthScreen), findsOneWidget);
    });

    testWidgets(
        '8. OFFLINE (Critical assigned, Immediate re-lock): no number, '
        'withheld message; Fix protection opens Health Details',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
        _chat: _L.critical,
      });
      fx.overlay.overlayGranted = false;
      await _pumpApp(tester, fx);
      await _openSecurity(tester);

      expect(find.byKey(const Key('sc_score_withheld')), findsOneWidget);
      expect(_shownPoints(tester), isNull);
      expect(find.byKey(const Key('sc_factor_health')), findsNothing);
      expect(find.byKey(const Key('sc_factor_relock')), findsNothing);
      _expectHonestWording(tester);

      await tester.tap(find.byKey(const Key('sc_score_fix')));
      await tester.pumpAndSettle();
      expect(find.byType(ProtectionHealthScreen), findsOneWidget);
    });

    testWidgets(
        '9. stale health: once the last SECURE check is out of date the '
        'number disappears (no new probe); Check again restores it',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await fx.c.protectionBootstrap.synchronize();
      DateTime now = DateTime.now();
      final ProtectionHealthMonitor monitor = ProtectionHealthMonitor(
        protectedApps: fx.c.protectedApps,
        credentials: fx.c.auth,
        installedApps: fx.c.installedAppsService,
        accessibility: fx.c.accessibility,
        overlay: fx.c.overlay,
        watcher: fx.c.watcher,
        preferences: fx.c.preferences,
        biometrics: fx.c.biometrics,
        now: () => now,
      );
      await _pumpSection(tester, fx, monitor: monitor);
      expect(_shownPoints(tester), 100);
      final int probes = fx.watcher.getHealthCalls;

      now = now.add(
        ProtectionHealthEngine.defaultMaxAge + const Duration(seconds: 1),
      );
      await tester.pump(
        ProtectionHealthEngine.defaultMaxAge + const Duration(seconds: 1),
      );
      await tester.pump();
      expect(_shownPoints(tester), isNull);
      expect(
        _inScore(find
            .text(_C.unavailableMessage(ScoreUnavailableReason.healthStale))),
        findsOneWidget,
      );
      expect(fx.watcher.getHealthCalls, probes, reason: 'no polling');

      await tester.tap(find.byKey(const Key('sc_score_check')));
      await tester.pumpAndSettle();
      expect(_shownPoints(tester), 100);
    });

    testWidgets(
        '9b/16. while a check after a change runs, an earlier score is '
        'hidden ("Assessing"), never shown as current',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      expect(_shownPoints(tester), 100);

      fx.watcher.getHealthGate = Completer<void>();
      await tester.tap(find.byKey(const Key('sc_check_again')));
      await tester.pump();
      await tester.pump();
      expect(_shownPoints(tester), isNull);
      expect(find.byKey(const Key('sc_score_assessing')), findsOneWidget);

      fx.watcher.getHealthGate!.complete();
      await tester.pumpAndSettle();
      expect(_shownPoints(tester), 100);
    });

    testWidgets(
        '9c. health check failure -> unavailable with Check again; no '
        'health source -> unavailable', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await _pumpSection(tester, fx, monitor: _FailingMonitor(fx.c));
      expect(_shownPoints(tester), isNull);
      expect(
        _inScore(find
            .text(_C.unavailableMessage(ScoreUnavailableReason.healthFailed))),
        findsOneWidget,
      );
      expect(find.byKey(const Key('sc_score_check')), findsOneWidget);
    });

    testWidgets(
        '16. no number while the saved apps are loading (no default 100)',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await _pumpApp(tester, fx);
      final Completer<void> gate = Completer<void>();
      fx.db.readGates.add(gate);
      await tester.tap(find.byKey(const Key('nav_security')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('sc_score_assessing')), findsOneWidget);
      expect(_shownPoints(tester), isNull);
      expect(_inScore(find.text('100')), findsNothing);
      expect(_inScore(find.text('0')), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();
      expect(_shownPoints(tester), 100);
    });
  });

  group('failures (SIMULATED)', () {
    testWidgets(
        '10. a failed repository read drops the earlier score (never 0, '
        'never the old value); Try again recovers',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      expect(_shownPoints(tester), 100);

      fx.db.readError = StateError('simulated read failure');
      await _go(tester, 'nav_apps');
      await _openSecurity(tester);
      expect(_shownPoints(tester), isNull);
      expect(
        _inScore(find.text(
            _C.unavailableMessage(ScoreUnavailableReason.appsUnreadable))),
        findsOneWidget,
      );

      fx.db.readError = null;
      await tester.tap(find.byKey(const Key('sc_score_retry')));
      await tester.pumpAndSettle();
      // The failed read also made the shared health check unable to
      // confirm protection (ATTENTION). Try again re-reads the apps only,
      // so the score is provisional until health is checked again: the
      // score and the health card never disagree.
      expect(_shownPoints(tester), 40);
      expect(find.byKey(const Key('sc_score_provisional')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sc_check_again')));
      await tester.pumpAndSettle();
      expect(_shownPoints(tester), 100);
      expect(find.byKey(const Key('sc_score_provisional')), findsNothing);
    });

    testWidgets(
        '10b. a failed re-lock setting read -> unavailable (settings); the '
        'app summary is unaffected; Try again recovers',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      fx.db.graceError = StateError('simulated settings failure');
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      expect(_shownPoints(tester), isNull);
      expect(
        _inScore(find.text(
            _C.unavailableMessage(ScoreUnavailableReason.settingsUnreadable))),
        findsOneWidget,
      );
      expect(find.byKey(const Key('sc_total')), findsOneWidget);

      fx.db.graceError = null;
      await tester.tap(find.byKey(const Key('sc_score_retry')));
      await tester.pumpAndSettle();
      expect(_shownPoints(tester), 100);
    });
  });

  group('refresh and consistency (SIMULATED)', () {
    testWidgets(
        '14. changing the Grace period below updates the score at once '
        '(event driven); a failed save keeps the saved value',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _photos: _L.standard,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      expect(_shownPoints(tester), 100);
      final int healthProbes = fx.watcher.getHealthCalls;

      await tester.tap(_inKey('grace_selector', find.text('5 minutes')));
      await tester.pumpAndSettle();
      expect(fx.watcher.gracePeriod, const Duration(minutes: 5));
      expect(_shownPoints(tester), 70);
      _expectFactor('sc_factor_relock', 10, 40);
      expect(fx.watcher.getHealthCalls, healthProbes,
          reason: 'a settings change re-reads settings only, no probe');

      // The next save fails: the screen rolls back and the score shows the
      // saved value, not the attempted one.
      fx.db.settingWriteError = StateError('simulated write failure');
      await tester.tap(_inKey('grace_selector', find.text('30 seconds')));
      await tester.pumpAndSettle();
      expect(fx.watcher.gracePeriod, const Duration(minutes: 5));
      expect(_shownPoints(tester), 70);
      fx.db.settingWriteError = null;
    });

    testWidgets(
        '11/15. level changes elsewhere are reflected on return; a confirmed '
        'upgrade raises F2, an unconfirmed one is credited lower',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
        <String, AppSecurityLevel>{_bank: _L.standard},
        grace: const Duration(minutes: 5),
      );
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      expect(_shownPoints(tester), 70);

      // Saved but not yet confirmed by native: no extra credit.
      await fx.c.protectedApps.setSecurityLevel(_bank, _L.critical);
      await _go(tester, 'nav_apps');
      await _openSecurity(tester);
      expect(_shownPoints(tester), 70);
      expect(find.byKey(const Key('sc_score_unconfirmed')), findsOneWidget);

      // Native confirms the upgrade.
      await fx.c.protectionBootstrap.synchronize();
      await _go(tester, 'nav_apps');
      await _openSecurity(tester);
      expect(fx.c.protectionBootstrap.nativeLevelFor(_bank), _L.critical);
      expect(_shownPoints(tester), 100);
      expect(find.byKey(const Key('sc_score_unconfirmed')), findsNothing);
    });

    testWidgets(
        '12/13. held-stricter native level (downgrade pending CR-2): the '
        'score counts the lower saved level and says so; nothing is synced',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
        <String, AppSecurityLevel>{_bank: _L.critical},
        grace: const Duration(minutes: 5),
      );
      await _pumpApp(tester, fx);
      expect(fx.c.protectionBootstrap.nativeLevelFor(_bank), _L.critical);
      await fx.c.protectedApps.setSecurityLevel(_bank, _L.standard);
      final int configures = fx.watcher.configureCalls;
      await _openSecurity(tester);

      expect(_shownPoints(tester), 70);
      expect(_inScore(find.text(_C.heldNote(1))), findsOneWidget);
      expect(fx.c.protectionBootstrap.nativeLevelFor(_bank), _L.critical);
      expect(fx.watcher.configureCalls, configures);
      expect(fx.watcher.authorizePackageCalls, 0);
    });

    testWidgets(
        '20. rapid refresh: an older read completing last never overwrites '
        'the newer score', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
        <String, AppSecurityLevel>{_photos: _L.standard},
        grace: const Duration(minutes: 5),
      );
      await fx.c.protectionBootstrap.synchronize();
      final ValueNotifier<int> revision = ValueNotifier<int>(0);
      await _pumpSection(tester, fx, revision: revision);
      expect(_shownPoints(tester), 70);

      // Read 1 captures the OLD data (Standard) and waits. Each gate is
      // queued right before its own read (the repository and the sync
      // below read the apps too).
      final Completer<void> older = Completer<void>();
      final Completer<void> newer = Completer<void>();
      fx.db.readGates.add(older);
      revision.value++;
      await tester.pump();
      expect(fx.db.readGates, isEmpty, reason: 'read 1 is waiting');
      // The level changes and native confirms; read 2 captures it.
      await fx.c.protectedApps.setSecurityLevel(_photos, _L.critical);
      await fx.c.protectionBootstrap.synchronize();
      fx.db.readGates.add(newer);
      revision.value++;
      await tester.pump();
      expect(fx.db.readGates, isEmpty, reason: 'read 2 is waiting');

      newer.complete();
      await tester.pumpAndSettle();
      expect(_shownPoints(tester), 100);
      older.complete();
      await tester.pumpAndSettle();
      expect(_shownPoints(tester), 100, reason: 'the stale read is ignored');
    });

    testWidgets(
        'return from Android Settings (app resume) re-assesses: a fixed '
        'permission turns a provisional score into a current one',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      fx.installed.usageAccessGranted = false;
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      expect(find.byKey(const Key('sc_score_provisional')), findsOneWidget);

      fx.installed.usageAccessGranted = true;
      for (final AppLifecycleState s in <AppLifecycleState>[
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sc_score_provisional')), findsNothing);
      expect(_shownPoints(tester), 100);
    });
  });

  group('boundaries (SIMULATED)', () {
    testWidgets(
        '21. a pending PIN challenge stays on top while the score is shown; '
        'only the exact PIN grants', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      expect(_shownPoints(tester), 100);

      fx.accessibility.emitForegroundPackage(_bank);
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      final Route<dynamic>? top =
          ModalRoute.of(tester.element(find.byType(PinUnlockScreen)));
      expect(top?.isCurrent, isTrue);
      expect(fx.access.sessionFor(_bank), isNull);
      expect(fx.watcher.authorizePackageCalls, 0);

      for (final String digit in _pin.split('')) {
        await tester.tap(find.byKey(Key('pin_key_$digit')));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(fx.access.sessionFor(_bank), isNotNull);
    });

    testWidgets(
        '22. read-only: assessing, expanding details and every action write '
        'nothing, sync nothing and authorize nothing',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
        <String, AppSecurityLevel>{_bank: _L.critical, _chat: _L.standard},
        grace: const Duration(seconds: 30),
      );
      fx.installed.usageAccessGranted = false; // provisional: Fix action
      await _pumpApp(tester, fx);
      final int configures = fx.watcher.configureCalls;
      final int graceCalls = fx.watcher.setGracePeriodCalls;
      fx.db.writes = 0;
      fx.db.settingWrites = 0;
      await _openSecurity(tester);

      await tester.tap(find.byKey(const Key('sc_score_how')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sc_score_how_details')), findsOneWidget);
      for (final String line in _C.howLines) {
        expect(_inScore(find.text(line)), findsOneWidget);
      }
      _expectHonestWording(tester);
      await tester.tap(find.byKey(const Key('sc_score_how')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sc_score_how_details')), findsNothing);
      await tester.tap(find.byKey(const Key('sc_score_fix')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(fx.db.writes, 0, reason: 'no level/protection writes');
      expect(fx.db.settingWrites, 0, reason: 'no settings writes');
      expect(fx.watcher.configureCalls, configures, reason: 'no policy sync');
      expect(fx.watcher.setGracePeriodCalls, graceCalls);
      expect(fx.watcher.authorizePackageCalls, 0);
      expect(fx.access.sessionFor(_bank), isNull);
      expect(fx.access.sessionFor(_chat), isNull);
      expect(
        (await fx.c.lockSettings.getGracePeriod()).valueOrNull,
        const Duration(seconds: 30),
      );
      expect(
        <String, AppSecurityLevel>{
          for (final ProtectedApp a
              in (await fx.c.protectedApps.getProtectedApps()).valueOrNull!)
            a.packageName: a.securityLevel,
        },
        <String, AppSecurityLevel>{_bank: _L.critical, _chat: _L.standard},
      );
    });

    testWidgets('the card renders a given assessment exactly (no container)',
        (WidgetTester tester) async {
      // Without any container the Security Center has no inputs: the
      // score is unavailable, never 0 or 100.
      _tallView(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: SingleChildScrollView(child: SecurityCenterSection()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_shownPoints(tester), isNull);
      expect(find.byKey(const Key('sc_score_unavailable')), findsOneWidget);
      expect(find.byKey(const Key('sc_score_check')), findsNothing,
          reason: 'no health source, no Check again');
    });
  });
}
