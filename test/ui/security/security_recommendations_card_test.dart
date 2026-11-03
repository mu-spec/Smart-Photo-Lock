// Phase 9 / M3 (PRD 9G) — "Recommended improvements" in the Security Center.
//
// SIMULATED: production widgets, MainShell, router, the challenge host, the
// Phase 7 health engine + monitor + controller, the real protected-app,
// lock-settings and preference stores (in memory) and the container's
// static platform services. No Android device, Settings screen, OEM
// behaviour or native enforcement is observed; physical QA is pending
// (docs/regression.md, Phase 9 / M3).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/models/security_recommendation.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_key_value_store.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/data/storage/preferences_store.dart';
import 'package:smart_app_lock/protection/health/protection_health_engine.dart';
import 'package:smart_app_lock/protection/health/protection_health_monitor.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/ui/screens/apps/apps_screen.dart';
import 'package:smart_app_lock/ui/screens/health/protection_health_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/security/security_center_recommendations.dart';
import 'package:smart_app_lock/ui/screens/security/security_center_section.dart';
import 'package:smart_app_lock/ui/screens/security/security_recommendations_card.dart';
import 'package:smart_app_lock/ui/screens/security/security_score.dart';
import 'package:smart_app_lock/ui/screens/security/security_screen.dart';

typedef _L = AppSecurityLevel;
typedef _Card = SecurityRecommendationsCard;
typedef _R = SecurityCenterRecommendations;

const String _pin = '2468';
const String _bank = 'com.example.bank'; // not in the catalog
const String _chat = 'com.example.chat'; // not in the catalog
const String _wa = 'com.whatsapp'; // catalog: privacy → Sensitive

/// Installed apps, so the Apps tab lists them (and their Phase 8 hints).
const List<AppEntry> _installed = <AppEntry>[
  AppEntry(packageName: _bank, label: 'bank'),
  AppEntry(packageName: _chat, label: 'chat'),
  AppEntry(packageName: _wa, label: 'whatsapp'),
];

/// The real in-memory store with read gates, failures and write counters.
class _Db extends InMemoryLocalDatabase {
  final List<Completer<void>> readGates = <Completer<void>>[];
  Object? readError;
  int writes = 0;
  int settingWrites = 0;

  @override
  Future<List<ProtectedApp>> getProtectedApps() async {
    final List<ProtectedApp> snapshot = await super.getProtectedApps();
    if (readGates.isNotEmpty) await readGates.removeAt(0).future;
    final Object? error = readError;
    if (error != null) throw error;
    return snapshot;
  }

  @override
  Future<void> setSetting(String key, String value) {
    settingWrites++;
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

/// The preferences tier, shared across a simulated restart. A failing
/// dismissal save behaves like shared_preferences: the value lands in memory
/// first, then the write fails.
class _Kv extends InMemoryKeyValueStore {
  bool failDismissals = false;

  /// With [failDismissals], this many dismissal saves still succeed first.
  int succeedFirst = 0;

  @override
  Future<void> setString(String key, String value) async {
    await super.setString(key, value);
    if (key != AppPrefKeys.dismissedSecurityRecommendations) return;
    if (!failDismissals) return;
    if (succeedFirst > 0) {
      succeedFirst--;
      return;
    }
    throw StateError('simulated preference write failure');
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
  _Fx(this.c, this.db, this.kv, this.secrets);

  final AppContainer c;
  final _Db db;
  final _Kv kv;
  final InMemorySecretStore secrets;

  StaticWatcherService get watcher => c.watcher as StaticWatcherService;
  StaticOverlayLockService get overlay => c.overlay as StaticOverlayLockService;
  StaticAccessibilityLockService get accessibility =>
      c.accessibility as StaticAccessibilityLockService;
  StaticInstalledAppsService get installed =>
      c.installedAppsService as StaticInstalledAppsService;
  DefaultAccessController get access =>
      c.accessController as DefaultAccessController;

  static Future<_Fx> create(
    Map<String, AppSecurityLevel> protect, {
    bool withPin = true,
    Duration grace = Duration.zero,
  }) async {
    final _Db db = _Db();
    final _Kv kv = _Kv();
    final InMemorySecretStore secrets = InMemorySecretStore();
    final AppContainer c = _container(db, kv, secrets);
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
    _healthy(c, configured: protect.isNotEmpty && withPin);
    db.writes = 0;
    db.settingWrites = 0;
    return _Fx(c, db, kv, secrets);
  }

  static AppContainer _container(_Db db, _Kv kv, InMemorySecretStore secrets) =>
      AppContainer.inMemory(
        apps: _installed,
        database: db,
        secretStore: secrets,
        keyValueStore: kv,
        accessibilityEnabled: true,
        overlayGranted: true,
      );

  /// SIMULATED process restart: a new container over the same persisted
  /// database, secret store and preferences.
  _Fx restart() {
    final AppContainer next = _container(db, kv, secrets);
    _healthy(next, configured: true);
    return _Fx(next, db, kv, secrets);
  }

  static void _healthy(AppContainer c, {required bool configured}) {
    (c.watcher as StaticWatcherService)
      ..protectionConfigured = configured
      ..running = true
      ..accessibilityServiceConnected = true
      ..shieldArmed = true
      ..challengePending = false
      ..backgroundRestricted = false
      ..powerSaveMode = false
      ..ignoringBatteryOptimizations = false
      ..sdkInt = 34;
  }

  Future<Set<String>> dismissed() =>
      c.preferences.getDismissedSecurityRecommendations();

  Future<Map<String, AppSecurityLevel>> levels() async => <String, _L>{
        for (final ProtectedApp a
            in (await c.protectedApps.getProtectedApps()).valueOrNull!)
          a.packageName: a.securityLevel,
      };
}

void _view(WidgetTester tester, {double width = 1080, double height = 6000}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pumpApp(
  WidgetTester tester,
  _Fx fx, {
  bool sync = true,
  double height = 6000,
}) async {
  _view(tester, height: height);
  addTearDown(fx.c.capabilityMonitor.dispose);
  await tester.pumpWidget(SmartAppLockApp(container: fx.c));
  await tester.pumpAndSettle();
  if (sync) await fx.c.protectionBootstrap.synchronize();
}

/// Tears the app down and starts it again over the same persisted state.
Future<_Fx> _restart(WidgetTester tester, _Fx fx) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  final _Fx next = fx.restart();
  await _pumpApp(tester, next);
  return next;
}

Future<void> _go(WidgetTester tester, String tab) async {
  await tester.tap(find.byKey(Key(tab)));
  await tester.pumpAndSettle();
}

Future<void> _openSecurity(WidgetTester tester) => _go(tester, 'nav_security');

Future<void> _resume(WidgetTester tester) async {
  for (final AppLifecycleState s in const <AppLifecycleState>[
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
}

/// Just the Security Center, for a test-specific health monitor.
Future<void> _pumpSection(
  WidgetTester tester,
  _Fx fx, {
  ProtectionHealthMonitor? monitor,
  ValueNotifier<int>? revision,
  bool settle = true,
}) async {
  _view(tester);
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
  if (settle) await tester.pumpAndSettle();
}

Finder _inRec(Finder f) => find.descendant(
      of: find.byKey(const Key('security_center_recommendations')),
      matching: f,
      matchRoot: true,
    );

Finder _inKey(String key, Finder f) =>
    find.descendant(of: find.byKey(Key(key)), matching: f, matchRoot: true);

/// Scrolls the Security tab's lazy list (either way) until [f] is built and
/// on screen.
Future<void> _scrollTo(WidgetTester tester, Finder f, {double by = -300}) =>
    tester.scrollUntilVisible(
      f,
      by,
      scrollable: find
          .descendant(
            of: find.byType(SecurityScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );

/// Item roots (`sc_rec_<id>`) in on-screen order.
List<String> _itemIds(WidgetTester tester) {
  final List<Element> items = find
      .byWidgetPredicate((Widget w) {
        final Key? k = w.key;
        if (k is! ValueKey<String>) return false;
        final String v = k.value;
        return v.startsWith('sc_rec_') &&
            (v.startsWith('sc_rec_setup.') ||
                v.startsWith('sc_rec_improve.') ||
                v.startsWith('sc_rec_health.'));
      })
      .evaluate()
      .toList()
    ..sort((Element a, Element b) => tester
        .getTopLeft(find.byElementPredicate((Element e) => e == a))
        .dy
        .compareTo(tester
            .getTopLeft(find.byElementPredicate((Element e) => e == b))
            .dy));
  return items
      .map((Element e) =>
          (e.widget.key! as ValueKey<String>).value.substring('sc_rec_'.length))
      .toList();
}

/// The score number shown, or null.
int? _points(WidgetTester tester) {
  final Finder value = find.byKey(const Key('sc_score_value'));
  if (value.evaluate().isEmpty) return null;
  return int.parse(tester.widget<Text>(value).data!);
}

List<String> _recTexts(WidgetTester tester) =>
    _inRec(find.byType(Text)).evaluate().map((Element e) {
      final Text t = e.widget as Text;
      return t.data ?? t.textSpan?.toPlainText() ?? '';
    }).toList();

/// No absolute claims, urgency, scare tactics or upsell in the section.
void _expectCalmWording(WidgetTester tester) {
  final String all = _recTexts(tester).join(' | ').toLowerCase();
  for (final String banned in const <String>[
    '%',
    'perfect',
    'fully secure',
    'fully protected',
    '100',
    'guarantee',
    'unhackable',
    'impossible',
    'urgent',
    'immediately',
    'act now',
    'warning',
    'danger',
    'at risk',
    'hacked',
    'premium',
    'upgrade',
    'subscribe',
    'buy',
    'pro version',
    '!',
    'score',
    'fingerprint',
  ]) {
    expect(all.contains(banned), isFalse, reason: 'banned wording "$banned"');
  }
}

void main() {
  group('placement and states (SIMULATED)', () {
    testWidgets(
        '1. calm state: everything passed and nothing optional applies -> '
        'one hedged "nothing to suggest" message, no items, no buttons',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);

      expect(find.byKey(const Key('security_center_recommendations')),
          findsOneWidget);
      expect(find.byKey(const Key('sc_rec_all_clear')), findsOneWidget);
      expect(_inRec(find.text(_Card.allClearTitle)), findsOneWidget);
      expect(
        _Card.allClearMessage,
        'Every check Smart App Lock can run passed on the last check, and '
        'there are no suggested changes for your apps or re-lock setting. '
        'Some phone controls, such as manufacturer battery managers, cannot '
        'be checked.',
      );
      expect(_inRec(find.text(_Card.allClearMessage)), findsOneWidget);
      expect(_itemIds(tester), isEmpty);
      expect(_inRec(find.byType(TextButton)), findsNothing);
      _expectCalmWording(tester);

      // Inside the Security Center, below the health card and the score;
      // every existing Security tab control is still present.
      expect(
        find.descendant(
          of: find.byKey(const Key('security_center')),
          matching: find.byKey(const Key('security_center_recommendations')),
        ),
        findsOneWidget,
      );
      final double health =
          tester.getTopLeft(find.byKey(const Key('security_center_health'))).dy;
      final double score =
          tester.getTopLeft(find.byKey(const Key('security_center_score'))).dy;
      final double rec = tester
          .getTopLeft(find.byKey(const Key('security_center_recommendations')))
          .dy;
      expect(health < score && score < rec, isTrue);
      expect(find.byKey(const Key('grace_selector')), findsOneWidget);
      expect(find.text(SecurityScreen.changePinTitle), findsWidgets);
    });

    for (final Brightness brightness in Brightness.values) {
      testWidgets(
          '2. 320 dp, 2x text (${brightness.name}): problems + optional items '
          'render without overflow; header and level lines are announced',
          (WidgetTester tester) async {
        final _Fx fx = await _Fx.create(
          <String, AppSecurityLevel>{_wa: _L.standard, _chat: _L.standard},
          grace: const Duration(minutes: 5),
        );
        fx.installed.usageAccessGranted = false; // ATTENTION item
        await fx.c.protectionBootstrap.synchronize();
        _view(tester, width: 320);
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
        expect(tester.takeException(), isNull, reason: 'no overflow');

        final List<String> ids = _itemIds(tester);
        expect(ids.first, startsWith('health.'));
        expect(ids.sublist(1), <String>[_R.levelsId, _R.relockId]);
        expect(find.bySemanticsLabel(_Card.heading), findsOneWidget);
        expect(
          find.bySemanticsLabel(
            'whatsapp: now Standard, suggested Sensitive. '
            '${SensitiveAppCategory.privacy.reason}',
          ),
          findsOneWidget,
        );
        expect(
          _inKey('sc_rec_relock_values',
              find.text('Now: 5 minutes · Suggested: 1 minute')),
          findsOneWidget,
        );
        _expectCalmWording(tester);
        semantics.dispose();
        await fx.c.capabilityMonitor.dispose();
      });
    }

    testWidgets(
        '3. first-time setup: setup steps (no failure wording); "Show PIN and '
        'pattern" scrolls to Authentication, "Choose apps" opens Apps',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
        const <String, AppSecurityLevel>{},
        withPin: false,
      );
      await _pumpApp(tester, fx, sync: false, height: 800);
      await _openSecurity(tester);
      final Finder card =
          find.byKey(const Key('security_center_recommendations'));
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();

      expect(_itemIds(tester), <String>[_R.setupCredentialId, _R.setupAppsId]);
      expect(_inRec(find.text(_Card.setupTag)), findsNWidgets(2));
      final String all = _recTexts(tester).join(' ').toLowerCase();
      for (final String failure in <String>[
        'offline',
        'not working',
        'fail',
        'problem',
        'may not work',
      ]) {
        expect(all.contains(failure), isFalse, reason: failure);
      }
      expect(find.byKey(Key('sc_rec_dismiss_${_R.setupAppsId}')), findsNothing,
          reason: 'setup steps are not dismissible');
      _expectCalmWording(tester);

      final Finder showAuth =
          find.byKey(Key('sc_rec_action_${_R.setupCredentialId}'));
      expect(
          _inKey('sc_rec_action_${_R.setupCredentialId}',
              find.text('Show PIN and pattern')),
          findsOneWidget);
      await tester.ensureVisible(showAuth);
      await tester.pumpAndSettle();
      await tester.tap(showAuth);
      await tester.pumpAndSettle();
      final Finder authTitle = find.text('Authentication');
      expect(authTitle, findsWidgets);
      final double top = tester.getTopLeft(authTitle.first).dy;
      expect(top >= 0 && top < 800, isTrue, reason: 'Authentication shown');

      await _scrollTo(
          tester, find.byKey(Key('sc_rec_action_${_R.setupAppsId}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('sc_rec_action_${_R.setupAppsId}')));
      await tester.pumpAndSettle();
      expect(find.text(AppsScreen.description), findsOneWidget);
      expect(fx.watcher.authorizePackageCalls, 0);
    });

    testWidgets(
        '4. assessing while the saved data loads: never all-clear, never '
        'items; then ready', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await fx.c.protectionBootstrap.synchronize();
      final Completer<void> gate = Completer<void>();
      fx.db.readGates.add(gate);
      await _pumpSection(tester, fx, settle: false);
      await tester.pump();
      expect(find.byKey(const Key('sc_rec_assessing')), findsOneWidget);
      expect(_inRec(find.text(_Card.assessingTitle)), findsOneWidget);
      expect(find.byKey(const Key('sc_rec_all_clear')), findsNothing);
      expect(_itemIds(tester), isEmpty);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sc_rec_assessing')), findsNothing);
      expect(find.byKey(const Key('sc_rec_all_clear')), findsOneWidget);
    });

    testWidgets(
        '5. failed health check -> unavailable (not all-clear, no items), '
        'with Check again; never a failure shown as current',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
        <String, AppSecurityLevel>{_wa: _L.standard},
        grace: const Duration(minutes: 5),
      );
      await _pumpSection(tester, fx, monitor: _FailingMonitor(fx.c));
      expect(find.byKey(const Key('sc_rec_unavailable')), findsOneWidget);
      expect(
        _inRec(find.text(_Card.unavailableMessage(
            RecommendationsUnavailableReason.healthFailed))),
        findsOneWidget,
      );
      expect(find.byKey(const Key('sc_rec_all_clear')), findsNothing);
      expect(_itemIds(tester), isEmpty,
          reason: 'no optional items without a current check');
      expect(_points(tester), isNull);
    });

    testWidgets(
        '6. a failed apps read -> unavailable (apps unreadable); Try again '
        'recovers', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      expect(find.byKey(const Key('sc_rec_all_clear')), findsOneWidget);

      fx.db.readError = StateError('simulated read failure');
      await _go(tester, 'nav_apps');
      await _openSecurity(tester);
      expect(find.byKey(const Key('sc_rec_unavailable')), findsOneWidget);
      expect(
        _inRec(find.text(_Card.unavailableMessage(
            RecommendationsUnavailableReason.appsUnreadable))),
        findsOneWidget,
      );
      expect(find.byKey(const Key('sc_rec_all_clear')), findsNothing);

      fx.db.readError = null;
      await tester.tap(find.byKey(const Key('sc_rec_retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sc_rec_unavailable')), findsNothing);
      // The failed read also left health unable to confirm protection
      // (shared Phase 7 health); recommendations follow the health card.
      await tester.tap(find.byKey(const Key('sc_check_again')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sc_rec_all_clear')), findsOneWidget);
    });

    testWidgets(
        '7. the card renders each state of a given assessment exactly '
        '(optional suggestions unreadable, unavailable buttons)',
        (WidgetTester tester) async {
      final List<SecurityCenterRecommendation> acted =
          <SecurityCenterRecommendation>[];
      int retries = 0;
      int checks = 0;
      Future<void> show(RecommendationsAssessment a) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark,
            home: Scaffold(
              body: SingleChildScrollView(
                child: _Card(
                  assessment: a,
                  onAction: acted.add,
                  onDismiss: acted.add,
                  onRetry: () => retries++,
                  onCheckAgain: () => checks++,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      final ProtectionHealthReport secure = ProtectionHealthEngine.evaluate(
        HealthSignals(
          observedAt: DateTime(2026, 11, 3),
          protectionConfigured: true,
          credentialConfigured: true,
          hasProtectedApps: true,
          nativeProtectionEnabled: true,
          overlayGranted: true,
          overlayEverGranted: true,
          accessibilityEnabled: true,
          accessibilityEverGranted: true,
          accessibilityConnected: true,
          usageAccessGranted: true,
          usageAccessEverGranted: true,
          nativeHealthAvailable: true,
          watcherRunning: true,
          shieldArmed: true,
          notificationsGranted: true,
          backgroundRestricted: false,
          sdkInt: 34,
          powerSaveMode: false,
          biometricUnlockEnabled: false,
          biometricHardwarePresent: true,
          biometricEnrolled: true,
        ),
        now: DateTime(2026, 11, 3),
      );
      SecurityScoreInputs inputs({
        ScoreSourceState apps = ScoreSourceState.loaded,
        ScoreSourceState grace = ScoreSourceState.loaded,
        ProtectionHealthReport? health,
        bool failed = false,
      }) =>
          SecurityScoreInputs(
            appsState: apps,
            apps: <ProtectedApp>[
              ProtectedApp(
                packageName: _wa,
                label: 'WhatsApp',
                addedAt: DateTime(2026, 11, 1),
                securityLevel: _L.standard,
              ),
            ],
            nativeLevelFor: (String _) => _L.standard,
            graceState: grace,
            grace: grace == ScoreSourceState.loaded
                ? const Duration(minutes: 5)
                : null,
            health: health,
            healthChecking: false,
            healthFailed: failed,
          );

      // Dismissals unreadable: problems would still show, optional items are
      // withheld with a note, never an all-clear.
      await show(_R.assess(
          RecommendationInputs(base: inputs(health: secure), dismissed: null)));
      expect(
          find.byKey(const Key('sc_rec_optional_unavailable')), findsOneWidget);
      expect(find.text(_Card.optionalUnavailableMessage), findsOneWidget);
      expect(find.byKey(const Key('sc_rec_all_clear')), findsNothing);
      expect(_itemIds(tester), isEmpty);
      await tester.tap(find.byKey(const Key('sc_rec_retry')));
      expect(retries, 1);

      // Each unavailable reason: re-read for saved data, Check again for
      // health.
      for (final (RecommendationsAssessment a, String button)
          in <(RecommendationsAssessment, String)>[
        (
          _R.assess(RecommendationInputs(
              base: inputs(apps: ScoreSourceState.failed, health: secure),
              dismissed: const <String>{})),
          'sc_rec_retry'
        ),
        (
          _R.assess(RecommendationInputs(
              base: inputs(grace: ScoreSourceState.failed, health: secure),
              dismissed: const <String>{})),
          'sc_rec_retry'
        ),
        (
          _R.assess(RecommendationInputs(
              base: inputs(failed: true), dismissed: const <String>{})),
          'sc_rec_check'
        ),
        (
          _R.assess(RecommendationInputs(
              base: inputs(), dismissed: const <String>{})),
          'sc_rec_check'
        ),
      ]) {
        await show(a);
        expect(a.status, RecommendationsStatus.unavailable);
        expect(find.text(_Card.unavailableMessage(a.reason!)), findsOneWidget);
        expect(find.byKey(Key(button)), findsOneWidget, reason: '${a.reason}');
        expect(_itemIds(tester), isEmpty);
        expect(find.byKey(const Key('sc_rec_all_clear')), findsNothing);
      }
      await tester.tap(find.byKey(const Key('sc_rec_check')));
      expect(checks, 1);

      // Ready with optional items: buttons call back with the item.
      await show(_R.assess(RecommendationInputs(
          base: inputs(health: secure), dismissed: const <String>{})));
      expect(_itemIds(tester), <String>[_R.levelsId, _R.relockId]);
      await tester.tap(find.byKey(Key('sc_rec_action_${_R.relockId}')));
      await tester.tap(find.byKey(Key('sc_rec_dismiss_${_R.levelsId}')));
      expect(acted.map((SecurityCenterRecommendation r) => r.id),
          <String>[_R.relockId, _R.levelsId]);
      expect(
        find.text('WhatsApp: Standard → Sensitive'),
        findsOneWidget,
      );
    });
  });

  group('health recommendations (SIMULATED)', () {
    testWidgets(
        '8. permission issue -> recommendation from the Phase 7 issue; Review '
        'opens Health Details; restoring the permission removes it',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      fx.installed.usageAccessGranted = false;
      await _pumpApp(tester, fx);
      await _openSecurity(tester);

      final List<String> ids = _itemIds(tester);
      expect(ids, hasLength(1));
      expect(ids.single, startsWith('health.'));
      expect(ids.single, contains('usage'));
      expect(find.byKey(Key('sc_rec_dismiss_${ids.single}')), findsNothing,
          reason: 'problems are never dismissible');
      expect(
        _inKey('sc_rec_action_${ids.single}',
            find.text('Review in Health Details')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(Key('sc_rec_action_${ids.single}')));
      await tester.pumpAndSettle();
      expect(find.byType(ProtectionHealthScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      // The user grants it in Android Settings and returns.
      fx.installed.usageAccessGranted = true;
      await _resume(tester);
      expect(_itemIds(tester), isEmpty);
      expect(find.byKey(const Key('sc_rec_all_clear')), findsOneWidget);
      expect(fx.watcher.authorizePackageCalls, 0);
    });

    testWidgets(
        '9. Critical + overlay revoked (OFFLINE): the protection problem is '
        'listed first, optional items after it; no false safety claims',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
        <String, AppSecurityLevel>{
          _bank: _L.critical,
          _wa: _L.standard,
        },
        grace: const Duration(minutes: 5),
      );
      fx.overlay.overlayGranted = false;
      await _pumpApp(tester, fx);
      await _openSecurity(tester);

      final List<String> ids = _itemIds(tester);
      expect(ids.first, startsWith('health.'));
      expect(ids.first, contains('overlay'));
      expect(ids.sublist(ids.length - 2), <String>[_R.levelsId, _R.relockId]);
      final String all = _recTexts(tester).join(' ').toLowerCase();
      for (final String claim in <String>[
        'secure',
        'is protected',
        'are protected',
        'working',
        'safe',
      ]) {
        expect(all.contains(claim), isFalse, reason: claim);
      }
      _expectCalmWording(tester);

      // Restored: the problem leaves, the optional items stay.
      fx.overlay.overlayGranted = true;
      await _resume(tester);
      expect(_itemIds(tester), <String>[_R.levelsId, _R.relockId]);
    });
  });

  group('optional improvements (SIMULATED)', () {
    testWidgets(
        '10. level suggestion: current -> recommended, opens Apps; nothing is '
        'changed without the user (no auto-upgrade)',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _wa: _L.standard,
        _bank: _L.critical,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);

      expect(_itemIds(tester), <String>[_R.levelsId]);
      expect(
        _inKey(
            'sc_rec_level_$_wa', find.text('whatsapp: Standard → Sensitive')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('sc_rec_level_$_bank')), findsNothing);
      expect(
        _inKey('sc_rec_action_${_R.levelsId}', find.text('Review in Apps')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(Key('sc_rec_action_${_R.levelsId}')));
      await tester.pumpAndSettle();
      expect(find.text(AppsScreen.description), findsOneWidget);
      expect(find.byKey(const Key('app_suggestion_$_wa')), findsOneWidget,
          reason: 'the same Phase 8 suggestion, applied only in Apps');

      expect(fx.db.writes, 0);
      expect(await fx.levels(),
          <String, AppSecurityLevel>{_wa: _L.standard, _bank: _L.critical});
      expect(fx.watcher.authorizePackageCalls, 0);
    });

    testWidgets(
        '11. dismissing a level suggestion hides it, writes the shared Phase 8 '
        'preference, leaves the score unchanged, and stays hidden',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
        <String, AppSecurityLevel>{_wa: _L.standard},
        grace: const Duration(minutes: 5),
      );
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      final int? before = _points(tester);
      expect(before, 70);
      expect(_itemIds(tester), <String>[_R.levelsId, _R.relockId]);
      await _go(tester, 'nav_apps');
      expect(find.byKey(const Key('app_suggestion_$_wa')), findsOneWidget,
          reason: 'the Apps tab shows the same suggestion before dismissal');
      await _openSecurity(tester);

      await tester.tap(find.byKey(Key('sc_rec_dismiss_${_R.levelsId}')));
      await tester.pumpAndSettle();
      expect(_itemIds(tester), <String>[_R.relockId]);
      expect(_points(tester), before, reason: 'dismissal is not a score input');
      expect(await fx.dismissed(), <String>{
        SecurityRecommendations.forApp(_wa, _L.standard)!.dismissalKey
      });
      expect(await fx.levels(), <String, AppSecurityLevel>{_wa: _L.standard});

      // Shared with the Apps tab (no duplicate nagging) and kept on return.
      await _go(tester, 'nav_apps');
      expect(find.byKey(const Key('app_suggestion_$_wa')), findsNothing);
      await _openSecurity(tester);
      expect(_itemIds(tester), <String>[_R.relockId]);
      expect(_points(tester), before);
    });

    testWidgets(
        '12. re-lock: current and proposed values; "Show Grace period" '
        'scrolls to the selector; the user\'s own change updates the score '
        'and the proposal', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
        <String, AppSecurityLevel>{_chat: _L.standard},
        grace: const Duration(minutes: 5),
      );
      await _pumpApp(tester, fx, height: 500);
      await _openSecurity(tester);
      expect(_points(tester), 70);
      final Finder show = find.byKey(Key('sc_rec_action_${_R.relockId}'));
      await _scrollTo(tester, show, by: 100);
      await tester.pumpAndSettle();
      expect(_itemIds(tester), <String>[_R.relockId]);
      expect(
        tester.widget<Text>(find.byKey(const Key('sc_rec_relock_values'))).data,
        'Now: 5 minutes · Suggested: 1 minute',
      );
      final String reason = _recTexts(tester).join(' ').toLowerCase();
      expect(reason.contains('guarantee'), isFalse);

      expect(
          _inKey(
              'sc_rec_action_${_R.relockId}', find.text('Show Grace period')),
          findsOneWidget);
      // Precondition: the Re-lock section is not built at all yet (not
      // even in the lazy list's cache), so the button must scroll to it.
      expect(find.byKey(const Key('grace_selector'), skipOffstage: false),
          findsNothing);
      await tester.tap(show);
      await tester.pumpAndSettle();
      final Finder selector = find.byKey(const Key('grace_selector'));
      expect(selector, findsOneWidget);
      final Rect r = tester.getRect(selector);
      expect(r.top >= 0 && r.bottom <= 500, isTrue,
          reason: 'the Grace period selector is on screen: $r');
      expect(fx.db.settingWrites, 0, reason: 'showing changes nothing');
      expect(fx.watcher.gracePeriod, const Duration(minutes: 5));

      // The user's own choice through the existing selector.
      await tester.tap(_inKey('grace_selector', find.text('1 minute')));
      await tester.pumpAndSettle();
      expect(fx.watcher.gracePeriod, const Duration(minutes: 1));
      await _scrollTo(tester, find.byKey(const Key('sc_score_value')));
      await tester.pumpAndSettle();
      expect(_points(tester), 80);
      await _scrollTo(tester, find.byKey(const Key('sc_rec_relock_values')),
          by: 300);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('sc_rec_relock_values'))).data,
        'Now: 1 minute · Suggested: 30 seconds',
      );
    });

    testWidgets(
        '13. dismissing the re-lock suggestion is bound to the current value: '
        'score unchanged; a later different value can be suggested again',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
        <String, AppSecurityLevel>{_chat: _L.standard},
        grace: const Duration(minutes: 5),
      );
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      expect(_points(tester), 70);

      await tester.tap(find.byKey(Key('sc_rec_dismiss_${_R.relockId}')));
      await tester.pumpAndSettle();
      expect(_itemIds(tester), isEmpty);
      expect(find.byKey(const Key('sc_rec_all_clear')), findsOneWidget);
      expect(_points(tester), 70);
      expect(await fx.dismissed(),
          <String>{_R.relockDismissalKey(const Duration(minutes: 5))});
      expect(fx.watcher.gracePeriod, const Duration(minutes: 5));
      expect(fx.db.settingWrites, 0);

      await tester.tap(_inKey('grace_selector', find.text('1 minute')));
      await tester.pumpAndSettle();
      expect(_points(tester), 80);
      expect(_itemIds(tester), <String>[_R.relockId]);
      expect(
        tester.widget<Text>(find.byKey(const Key('sc_rec_relock_values'))).data,
        'Now: 1 minute · Suggested: 30 seconds',
      );
    });
  });

  group('refresh and boundaries (SIMULATED)', () {
    testWidgets(
        '18. one shared dismissal: "Don\'t suggest again" in the Apps tab '
        'also removes the Security Center item on tab return',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _wa: _L.standard,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      expect(_itemIds(tester), <String>[_R.levelsId]);
      final int? before = _points(tester);

      await _go(tester, 'nav_apps');
      await tester.tap(find.byKey(const Key('app_tile_$_wa')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const Key('security_level_recommendation_dismiss')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app_suggestion_$_wa')), findsNothing);

      await _openSecurity(tester);
      expect(_itemIds(tester), isEmpty);
      expect(find.byKey(const Key('sc_rec_all_clear')), findsOneWidget);
      expect(_points(tester), before);
      expect(await fx.levels(), <String, AppSecurityLevel>{_wa: _L.standard});
    });

    testWidgets(
        '14. protect/unprotect and level changes elsewhere are reflected on '
        'tab return', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      expect(_itemIds(tester), isEmpty);

      await fx.c.protectedApps.add(ProtectedApp(
        packageName: _wa,
        label: 'whatsapp',
        addedAt: DateTime(2026, 11, 2),
      ));
      await fx.c.protectionBootstrap.synchronize();
      await _go(tester, 'nav_apps');
      await _openSecurity(tester);
      expect(_itemIds(tester), <String>[_R.levelsId]);

      // Raised to the suggested level by the user elsewhere: gone.
      await fx.c.protectedApps.setSecurityLevel(_wa, _L.sensitive);
      await fx.c.protectionBootstrap.synchronize();
      await _go(tester, 'nav_apps');
      await _openSecurity(tester);
      expect(_itemIds(tester), isEmpty);

      await fx.c.protectedApps.remove(_wa);
      await fx.c.protectedApps.remove(_bank);
      await fx.c.protectionBootstrap.synchronize();
      await _go(tester, 'nav_apps');
      await _openSecurity(tester);
      expect(_itemIds(tester), <String>[_R.setupAppsId]);
    });

    testWidgets(
        '15. rapid refresh: an older read completing last never replaces the '
        'newer list', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await fx.c.protectionBootstrap.synchronize();
      final ValueNotifier<int> revision = ValueNotifier<int>(0);
      await _pumpSection(tester, fx, revision: revision);
      expect(_itemIds(tester), isEmpty);

      // Read 1 captures the OLD list (bank only) and waits.
      final Completer<void> older = Completer<void>();
      final Completer<void> newer = Completer<void>();
      fx.db.readGates.add(older);
      revision.value++;
      await tester.pump();
      expect(fx.db.readGates, isEmpty, reason: 'read 1 is waiting');
      // WhatsApp is protected at Standard; read 2 captures it.
      await fx.c.protectedApps.add(ProtectedApp(
        packageName: _wa,
        label: 'whatsapp',
        addedAt: DateTime(2026, 11, 2),
      ));
      await fx.c.protectionBootstrap.synchronize();
      fx.db.readGates.add(newer);
      revision.value++;
      await tester.pump();
      expect(fx.db.readGates, isEmpty, reason: 'read 2 is waiting');

      newer.complete();
      await tester.pumpAndSettle();
      expect(_itemIds(tester), <String>[_R.levelsId]);
      older.complete();
      await tester.pumpAndSettle();
      expect(_itemIds(tester), <String>[_R.levelsId],
          reason: 'the stale read (without WhatsApp) is ignored');
    });

    testWidgets(
        '16. a pending PIN challenge survives recommendation navigation, '
        'resume and tab return; only the exact PIN grants',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
        <String, AppSecurityLevel>{_bank: _L.critical, _wa: _L.standard},
      );
      fx.installed.usageAccessGranted = false;
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      final String healthId = _itemIds(tester).first;
      expect(healthId, startsWith('health.'));

      // Into Health Details from the recommendation; the bank opens.
      await tester.tap(find.byKey(Key('sc_rec_action_$healthId')));
      await tester.pumpAndSettle();
      expect(find.byType(ProtectionHealthScreen), findsOneWidget);
      fx.accessibility.emitForegroundPackage(_bank);
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      // Returning from Settings (resume) re-assesses underneath; the
      // challenge stays on top with no session or authorization.
      fx.installed.usageAccessGranted = true;
      await _resume(tester);
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      final Route<dynamic>? top =
          ModalRoute.of(tester.element(find.byType(PinUnlockScreen)));
      expect(top?.isCurrent, isTrue);
      expect(fx.access.sessionFor(_bank), isNull);
      expect(fx.watcher.authorizePackageCalls, 0);

      // A wrong PIN never grants.
      for (final String digit in '1357'.split('')) {
        await tester.tap(find.byKey(Key('pin_key_$digit')));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(fx.access.sessionFor(_bank), isNull);

      for (final String digit in _pin.split('')) {
        await tester.tap(find.byKey(Key('pin_key_$digit')));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(fx.access.sessionFor(_bank), isNotNull);
    });

    testWidgets(
        '17. read-only: every action and dismissal writes no level, '
        'protection or setting, syncs nothing and authorizes nothing',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
        <String, AppSecurityLevel>{_bank: _L.critical, _wa: _L.standard},
        grace: const Duration(minutes: 5),
      );
      fx.installed.usageAccessGranted = false;
      await _pumpApp(tester, fx);
      final int configures = fx.watcher.configureCalls;
      final int graceCalls = fx.watcher.setGracePeriodCalls;
      fx.db.writes = 0;
      fx.db.settingWrites = 0;
      await _openSecurity(tester);

      final List<String> ids = _itemIds(tester);
      expect(ids.sublist(1), <String>[_R.levelsId, _R.relockId]);
      await tester.tap(find.byKey(Key('sc_rec_action_${ids.first}')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('sc_rec_action_${_R.relockId}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('sc_rec_dismiss_${_R.relockId}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('sc_rec_dismiss_${_R.levelsId}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('sc_rec_action_${ids.first}')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(fx.db.writes, 0, reason: 'no level/protection writes');
      expect(fx.db.settingWrites, 0, reason: 'no settings writes');
      expect(fx.watcher.configureCalls, configures, reason: 'no policy sync');
      expect(fx.watcher.setGracePeriodCalls, graceCalls);
      expect(fx.watcher.authorizePackageCalls, 0);
      expect(fx.access.sessionFor(_bank), isNull);
      expect(fx.access.sessionFor(_wa), isNull);
      expect(
        (await fx.c.lockSettings.getGracePeriod()).valueOrNull,
        const Duration(minutes: 5),
      );
      expect(await fx.levels(),
          <String, AppSecurityLevel>{_bank: _L.critical, _wa: _L.standard});
    });
  });

  group('dismissal persistence (SIMULATED)', () {
    const String notSaved = SecurityRecommendations.dismissNotSavedMessage;

    testWidgets(
        '19. a saved dismissal: hidden only after the save, confirmed, and '
        'still hidden after a restart in the Security Center and Apps tab',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
        <String, AppSecurityLevel>{_wa: _L.standard},
        grace: const Duration(minutes: 5),
      );
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      expect(_itemIds(tester), <String>[_R.levelsId, _R.relockId]);

      await tester.tap(find.byKey(Key('sc_rec_dismiss_${_R.levelsId}')));
      await tester.pumpAndSettle();
      expect(_itemIds(tester), <String>[_R.relockId]);
      expect(find.text(_Card.dismissedMessage), findsOneWidget);
      expect(find.text(notSaved), findsNothing);
      expect(await fx.dismissed(), <String>{
        SecurityRecommendations.forApp(_wa, _L.standard)!.dismissalKey
      });
      expect(_points(tester), 70);

      final _Fx after = await _restart(tester, fx);
      await _openSecurity(tester);
      expect(_itemIds(tester), <String>[_R.relockId]);
      expect(_points(tester), 70);
      await _go(tester, 'nav_apps');
      expect(find.byKey(const Key('app_suggestion_$_wa')), findsNothing);
      expect(
          await after.levels(), <String, AppSecurityLevel>{_wa: _L.standard});
    });

    testWidgets(
        '20. a failed save: the suggestion stays, the message says it was not '
        'saved; score, levels, settings and native untouched; Apps tab '
        'consistent; still shown after a restart', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
        <String, AppSecurityLevel>{_wa: _L.standard},
        grace: const Duration(minutes: 5),
      );
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      final int configures = fx.watcher.configureCalls;
      final int graceCalls = fx.watcher.setGracePeriodCalls;
      fx.db.writes = 0;
      fx.db.settingWrites = 0;
      expect(_points(tester), 70);

      fx.kv.failDismissals = true;
      await tester.tap(find.byKey(Key('sc_rec_dismiss_${_R.relockId}')));
      await tester.pumpAndSettle();
      expect(_itemIds(tester), <String>[_R.levelsId, _R.relockId],
          reason: 'never hidden as if saved');
      expect(find.text(notSaved), findsOneWidget);
      expect(
        find.widgetWithText(
            SnackBarAction, SecurityRecommendations.dismissRetryLabel),
        findsOneWidget,
      );
      expect(find.text(_Card.dismissedMessage), findsNothing);
      expect(await fx.dismissed(), isEmpty,
          reason: 'no unsaved dismissal is left in memory');
      expect(_points(tester), 70);
      expect(fx.db.writes, 0);
      expect(fx.db.settingWrites, 0);
      expect(fx.watcher.configureCalls, configures);
      expect(fx.watcher.setGracePeriodCalls, graceCalls);
      expect(fx.watcher.gracePeriod, const Duration(minutes: 5));
      expect(fx.watcher.authorizePackageCalls, 0);
      expect(await fx.levels(), <String, AppSecurityLevel>{_wa: _L.standard});

      // The level suggestion fails the same way; the Apps tab agrees.
      await tester.tap(find.byKey(Key('sc_rec_dismiss_${_R.levelsId}')));
      await tester.pumpAndSettle();
      expect(_itemIds(tester), <String>[_R.levelsId, _R.relockId]);
      await _go(tester, 'nav_apps');
      expect(find.byKey(const Key('app_suggestion_$_wa')), findsOneWidget);
      await _openSecurity(tester);
      expect(_itemIds(tester), <String>[_R.levelsId, _R.relockId]);

      // Nothing was claimed as saved, so a restart shows the same.
      final _Fx after = await _restart(tester, fx);
      await _openSecurity(tester);
      expect(_itemIds(tester), <String>[_R.levelsId, _R.relockId]);
      expect(_points(tester), 70);
      await _go(tester, 'nav_apps');
      expect(find.byKey(const Key('app_suggestion_$_wa')), findsOneWidget);
      expect(
          await after.levels(), <String, AppSecurityLevel>{_wa: _L.standard});
    });

    testWidgets(
        '21. Try again after a failed save: saved, hidden, confirmed; the '
        'Apps tab hint is gone on tab return and after a restart',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _wa: _L.standard,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      fx.kv.failDismissals = true;
      await tester.tap(find.byKey(Key('sc_rec_dismiss_${_R.levelsId}')));
      await tester.pumpAndSettle();
      expect(_itemIds(tester), <String>[_R.levelsId]);
      expect(find.text(notSaved), findsOneWidget);

      fx.kv.failDismissals = false;
      await tester.tap(find.widgetWithText(
          SnackBarAction, SecurityRecommendations.dismissRetryLabel));
      await tester.pumpAndSettle();
      expect(_itemIds(tester), isEmpty);
      expect(find.byKey(const Key('sc_rec_all_clear')), findsOneWidget);
      expect(find.text(_Card.dismissedMessage), findsOneWidget);
      expect(find.text(notSaved), findsNothing);
      await _go(tester, 'nav_apps');
      expect(find.byKey(const Key('app_suggestion_$_wa')), findsNothing);

      await _restart(tester, fx);
      await _openSecurity(tester);
      expect(_itemIds(tester), isEmpty);
    });

    testWidgets(
        '22. grouped level item, save fails part-way: only the saved app is '
        'hidden; the other stays with the not-saved message',
        (WidgetTester tester) async {
      const String bw = 'com.x8bit.bitwarden';
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _wa: _L.standard,
        bw: _L.standard,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      // Saved in on-screen order: the first line's key is saved, then the
      // second save fails.
      final List<String> order = <String>[
        _wa,
        bw
      ]..sort((String a, String b) => tester
          .getTopLeft(find.byKey(Key('sc_rec_level_$a')))
          .dy
          .compareTo(tester.getTopLeft(find.byKey(Key('sc_rec_level_$b'))).dy));
      final String first = order.first;
      final String second = order.last;

      fx.kv
        ..failDismissals = true
        ..succeedFirst = 1;
      await tester.tap(find.byKey(Key('sc_rec_dismiss_${_R.levelsId}')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('sc_rec_level_$first')), findsNothing);
      expect(find.byKey(Key('sc_rec_level_$second')), findsOneWidget);
      expect(find.text(notSaved), findsOneWidget);
      expect(find.text(_Card.dismissedMessage), findsNothing);
      expect(await fx.dismissed(), <String>{
        SecurityRecommendations.forApp(first, _L.standard)!.dismissalKey,
      });
      expect(await fx.levels(),
          <String, AppSecurityLevel>{_wa: _L.standard, bw: _L.standard});
    });

    testWidgets(
        '23. Apps tab, failed save: the hint stays with the not-saved message '
        '(no "hidden" claim); the Security Center agrees; Try again saves '
        'for both', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _wa: _L.standard,
      });
      await _pumpApp(tester, fx);
      await _go(tester, 'nav_apps');
      fx.kv.failDismissals = true;
      await tester.tap(find.byKey(const Key('app_tile_$_wa')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const Key('security_level_recommendation_dismiss')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app_suggestion_$_wa')), findsOneWidget);
      expect(find.text(notSaved), findsOneWidget);
      expect(find.text(AppsScreen.suggestionDismissedMessage), findsNothing);
      expect(await fx.dismissed(), isEmpty);
      expect(await fx.levels(), <String, AppSecurityLevel>{_wa: _L.standard});
      expect(fx.db.writes, 0);

      fx.kv.failDismissals = false;
      await tester.tap(find.widgetWithText(
          SnackBarAction, SecurityRecommendations.dismissRetryLabel));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app_suggestion_$_wa')), findsNothing);
      expect(find.text(AppsScreen.suggestionDismissedMessage), findsOneWidget);
      await _openSecurity(tester);
      expect(_itemIds(tester), isEmpty);
      expect(fx.db.writes, 0);
    });

    testWidgets(
        '24. Apps tab failure, then the Security Center: the suggestion is '
        'still listed there (no tab hides what was not saved)',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _wa: _L.standard,
      });
      await _pumpApp(tester, fx);
      await _go(tester, 'nav_apps');
      fx.kv.failDismissals = true;
      await tester.tap(find.byKey(const Key('app_tile_$_wa')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const Key('security_level_recommendation_dismiss')));
      await tester.pumpAndSettle();
      await _openSecurity(tester);
      expect(_itemIds(tester), <String>[_R.levelsId]);
      await _go(tester, 'nav_apps');
      expect(find.byKey(const Key('app_suggestion_$_wa')), findsOneWidget);
    });
  });
}
