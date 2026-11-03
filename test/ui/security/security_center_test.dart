// Phase 9 / M1 — Security Center: dashboard and protection summaries.
//
// SIMULATED: production widgets, MainShell, router, the Phase 7 health
// engine + monitor + controller, the real protected-app repository over an
// in-memory database, and the container's static platform services. No
// Android device, Settings screen, OEM behaviour or native enforcement is
// observed; physical QA is pending (docs/regression.md, Phase 9 / M1).
//
// Numbers refer to the Phase 9 / M1 brief's test list (1–20).

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
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/health/protection_health_engine.dart';
import 'package:smart_app_lock/protection/health/protection_health_monitor.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/ui/screens/apps/apps_screen.dart';
import 'package:smart_app_lock/ui/screens/health/health_presentation.dart';
import 'package:smart_app_lock/ui/screens/health/protection_health_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/security/security_center_section.dart';
import 'package:smart_app_lock/ui/screens/security/security_center_summary.dart';
import 'package:smart_app_lock/ui/screens/security/security_screen.dart';

typedef _L = AppSecurityLevel;
typedef _S = SecurityCenterSection;

const String _pin = '2468';
const String _bank = 'com.example.bank';
const String _chat = 'com.example.chat';
const String _photos = 'com.example.photos';
const String _mail = 'com.example.mail';
const String _notes = 'com.example.notes';

/// Read gate / failure and write counters over the real in-memory store.
class _Db extends InMemoryLocalDatabase {
  Completer<void>? readGate;
  Object? readError;
  int reads = 0;
  int writes = 0;

  @override
  Future<List<ProtectedApp>> getProtectedApps() async {
    reads++;
    final Completer<void>? gate = readGate;
    if (gate != null) await gate.future;
    final Object? error = readError;
    if (error != null) throw error;
    return super.getProtectedApps();
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

/// A health source whose refresh fails as a whole (the controller then
/// reports "Status unavailable").
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

  /// A simulated-healthy device with a PIN and [protect]ed apps.
  static Future<_Fx> create(
    Map<String, AppSecurityLevel> protect, {
    List<AppEntry> installed = const <AppEntry>[],
  }) async {
    final _Db db = _Db();
    final AppContainer c = AppContainer.inMemory(
      apps: installed,
      database: db,
      accessibilityEnabled: true,
      overlayGranted: true,
    );
    await c.auth.enrollPin(_pin);
    for (final MapEntry<String, AppSecurityLevel> e in protect.entries) {
      await c.protectedApps.add(
        ProtectedApp(
          packageName: e.key,
          label: _labelOf(e.key),
          addedAt: DateTime(2026, 11, 1),
          securityLevel: e.value,
        ),
      );
    }
    (c.watcher as StaticWatcherService)
      ..protectionConfigured = protect.isNotEmpty
      ..running = true
      ..accessibilityServiceConnected = true
      ..shieldArmed = true
      ..challengePending = false
      ..backgroundRestricted = false
      ..powerSaveMode = false
      ..ignoringBatteryOptimizations = false
      ..sdkInt = 34;
    db.writes = 0;
    return _Fx(c, db);
  }
}

String _labelOf(String pkg) => switch (pkg) {
      _bank => 'Bank',
      _chat => 'Chat',
      _photos => 'Photos',
      _mail => 'Mail',
      _notes => 'Notes',
      _ => pkg,
    };

Future<void> _pumpApp(WidgetTester tester, _Fx fx) async {
  tester.view.physicalSize = const Size(1080, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(fx.c.capabilityMonitor.dispose);
  await tester.pumpWidget(SmartAppLockApp(container: fx.c));
  await tester.pumpAndSettle();
}

Future<void> _go(WidgetTester tester, String tab) async {
  await tester.tap(find.byKey(Key(tab)));
  await tester.pumpAndSettle();
}

Future<void> _openSecurity(WidgetTester tester) => _go(tester, 'nav_security');

Finder _inKey(String key, Finder f) =>
    find.descendant(of: find.byKey(Key(key)), matching: f, matchRoot: true);

Finder _healthTitle(String title) =>
    _inKey('sc_health_banner', find.text(title));

void _expectCount(AppSecurityLevel level, int n) {
  expect(
    _inKey('sc_count_${level.storageId}', find.text('$n')),
    findsOneWidget,
    reason: '${level.storageId} should be $n',
  );
}

void _expectDistribution(int total, int standard, int sensitive, int critical) {
  expect(_inKey('sc_total', find.text(_S.totalLabel(total))), findsOneWidget);
  _expectCount(_L.standard, standard);
  _expectCount(_L.sensitive, sensitive);
  _expectCount(_L.critical, critical);
}

Finder _criticalStatus(CriticalProtectionStatus s) =>
    _inKey('sc_critical_status', find.text(_S.criticalStatusLabel(s)));

/// Every string the Security Center renders.
List<String> _centerTexts(WidgetTester tester) => find
        .descendant(
          of: find.byKey(const Key('security_center')),
          matching: find.byType(Text),
        )
        .evaluate()
        .map((Element e) {
      final Text t = e.widget as Text;
      return t.data ?? t.textSpan?.toPlainText() ?? '';
    }).toList();

/// PRD 9A/9C: no absolute claims, fake scores or artificial urgency.
void _expectNoAbsoluteClaims(WidgetTester tester) {
  final String all = _centerTexts(tester).join(' | ').toLowerCase();
  for (final String banned in const <String>[
    '100%',
    '%',
    'guarantee',
    'impossible',
    'bypass',
    'fully secured',
    'fully secure',
    'unhackable',
    'all critical apps are safe',
    'score',
    'immediately',
    'urgent',
  ]) {
    expect(all.contains(banned), isFalse, reason: 'banned wording "$banned"');
  }
}

void main() {
  group('9A presentation (SIMULATED)', () {
    for (final Brightness brightness in Brightness.values) {
      testWidgets(
          'renders without overflow at 320 dp with 2x text '
          '(${brightness.name}); health and counts are labelled for screen '
          'readers', (WidgetTester tester) async {
        final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
          _bank: _L.critical,
          _chat: _L.sensitive,
          _photos: _L.standard,
        });
        fx.installed.usageAccessGranted = false; // ATTENTION: longest copy
        tester.view.physicalSize = const Size(320, 6000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
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
        expect(
            find.byKey(const Key('security_center_critical')), findsOneWidget);
        expect(
          find.bySemanticsLabel(
            RegExp('^Protection health: ${HealthPresentation.attentionTitle}'),
          ),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel('Critical: 1'), findsOneWidget);
        semantics.dispose();
        await fx.c.capabilityMonitor.dispose();
      });
    }
  });

  group('9B protected-apps summary (SIMULATED)', () {
    testWidgets('1. shows real repository values per level',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
        _chat: _L.sensitive,
        _photos: _L.standard,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);

      _expectDistribution(3, 1, 1, 1);
      expect(
        _inKey('sc_critical_assigned', find.text(_S.criticalAssignedLabel(1))),
        findsOneWidget,
      );
      expect(_inKey('sc_critical_names', find.text('Bank')), findsOneWidget);
    });

    testWidgets(
        '2. empty state: guidance and a working link to the Apps tab; '
        'no counts, no Critical claim', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(const <String, AppSecurityLevel>{});
      await _pumpApp(tester, fx);
      await _openSecurity(tester);

      expect(find.byKey(const Key('sc_apps_empty')), findsOneWidget);
      expect(find.text(_S.emptyTitle), findsOneWidget);
      expect(find.byKey(const Key('sc_total')), findsNothing);
      expect(find.byKey(const Key('sc_critical_none')), findsOneWidget);
      expect(find.byKey(const Key('sc_critical_status')), findsNothing);

      await tester.tap(find.byKey(const Key('sc_choose_apps')));
      await tester.pumpAndSettle();
      expect(find.text(AppsScreen.description), findsOneWidget);
    });

    testWidgets('3. one protected app', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.standard,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);

      _expectDistribution(1, 1, 0, 0);
      expect(find.text('1 app protected'), findsOneWidget);
      expect(find.byKey(const Key('sc_critical_none')), findsOneWidget);
    });

    testWidgets('4. mixed levels sum to the total; Critical names listed',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
        _mail: _L.critical,
        _chat: _L.sensitive,
        _photos: _L.standard,
        _notes: _L.standard,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);

      _expectDistribution(5, 2, 1, 2);
      expect(
          _inKey('sc_critical_names', find.text('Bank, Mail')), findsOneWidget);
    });

    testWidgets(
        '5. no duplicates: re-protecting keeps one record; installed but '
        'unprotected apps are not counted', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(
        <String, AppSecurityLevel>{_bank: _L.sensitive},
        installed: const <AppEntry>[
          AppEntry(packageName: _bank, label: 'Bank'),
          AppEntry(packageName: _chat, label: 'Chat'),
          AppEntry(packageName: _photos, label: 'Photos'),
          AppEntry(packageName: _mail, label: 'Mail'),
        ],
      );
      // Protecting the same app again (upsert) keeps one record and its
      // level (Phase 8 / M1).
      await fx.c.protectedApps.add(
        ProtectedApp(
          packageName: _bank,
          label: 'Bank',
          addedAt: DateTime(2026, 11, 2),
        ),
      );
      await _pumpApp(tester, fx);
      await _openSecurity(tester);

      _expectDistribution(1, 0, 1, 0);
    });

    testWidgets(
        '6. protect / unprotect on another tab: returning updates the counts',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.standard,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      _expectDistribution(1, 1, 0, 0);

      // The change is made while the Apps tab is visible (through the same
      // repository the Apps tab uses), then the user returns.
      await _go(tester, 'nav_apps');
      await fx.c.protectedApps.add(
        ProtectedApp(
          packageName: _chat,
          label: 'Chat',
          addedAt: DateTime(2026, 11, 2),
        ),
      );
      await _openSecurity(tester);
      _expectDistribution(2, 2, 0, 0);

      await _go(tester, 'nav_apps');
      await fx.c.protectedApps.remove(_bank);
      await fx.c.protectedApps.remove(_chat);
      await _openSecurity(tester);
      expect(find.byKey(const Key('sc_apps_empty')), findsOneWidget);
      expect(find.byKey(const Key('sc_total')), findsNothing);
    });

    testWidgets(
        '7. level changes move apps between levels without changing the '
        'total', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.standard,
        _chat: _L.standard,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      _expectDistribution(2, 2, 0, 0);
      expect(find.byKey(const Key('sc_critical_none')), findsOneWidget);

      await _go(tester, 'nav_apps');
      await fx.c.protectedApps.setSecurityLevel(_bank, _L.critical);
      await fx.c.protectedApps.setSecurityLevel(_chat, _L.sensitive);
      await _openSecurity(tester);
      _expectDistribution(2, 0, 1, 1);
      expect(
        _inKey('sc_critical_assigned', find.text(_S.criticalAssignedLabel(1))),
        findsOneWidget,
      );

      await _go(tester, 'nav_apps');
      await fx.c.protectedApps.setSecurityLevel(_bank, _L.standard);
      await _openSecurity(tester);
      _expectDistribution(2, 1, 1, 0);
      expect(find.byKey(const Key('sc_critical_none')), findsOneWidget);
    });
  });

  group('9C Critical summary vs 9D health (SIMULATED)', () {
    testWidgets(
        '8. Critical + SECURE: "Checks passed" on the last check; no '
        'absolute claim, no repair prompt', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);

      expect(_healthTitle(HealthPresentation.secureTitle), findsOneWidget);
      expect(_criticalStatus(CriticalProtectionStatus.checksPassed),
          findsOneWidget);
      expect(find.byKey(const Key('sc_critical_fix')), findsNothing);
      expect(find.text(_S.assignmentNote), findsOneWidget);
      _expectNoAbsoluteClaims(tester);
    });

    testWidgets(
        '9. Critical + ATTENTION REQUIRED: assignment kept, status needs '
        'attention, Fix protection opens Health Details',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      fx.installed.usageAccessGranted = false;
      await _pumpApp(tester, fx);
      await _openSecurity(tester);

      expect(_healthTitle(HealthPresentation.attentionTitle), findsOneWidget);
      expect(
        _inKey('sc_critical_assigned', find.text(_S.criticalAssignedLabel(1))),
        findsOneWidget,
      );
      expect(
          _criticalStatus(CriticalProtectionStatus.attention), findsOneWidget);
      _expectNoAbsoluteClaims(tester);

      await tester.tap(find.byKey(const Key('sc_critical_fix')));
      await tester.pumpAndSettle();
      expect(find.byType(ProtectionHealthScreen), findsOneWidget);
    });

    testWidgets(
        '10. Critical + PROTECTION OFFLINE: never "working"; the offline '
        'message is distinct and not absolute', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
        _chat: _L.standard,
      });
      fx.overlay.overlayGranted = false;
      await _pumpApp(tester, fx);
      await _openSecurity(tester);

      expect(_healthTitle(HealthPresentation.offlineTitle), findsOneWidget);
      expect(_criticalStatus(CriticalProtectionStatus.offline), findsOneWidget);
      expect(
        _inKey(
          'sc_critical_message',
          find.text(_S.criticalStatusMessage(CriticalProtectionStatus.offline)),
        ),
        findsOneWidget,
      );
      expect(
          _criticalStatus(CriticalProtectionStatus.checksPassed), findsNothing);
      // Approved wording (Phase 9 / M1 review): hedged, not absolute, and
      // distinct from the SECURE and ATTENTION messages.
      expect(
        _S.criticalStatusMessage(CriticalProtectionStatus.offline),
        'Protection is offline. App locking may not work until protection '
        'is restored.',
      );
      expect(
        <String>{
          _S.criticalStatusMessage(CriticalProtectionStatus.offline),
          _S.criticalStatusMessage(CriticalProtectionStatus.attention),
          _S.criticalStatusMessage(CriticalProtectionStatus.checksPassed),
        },
        hasLength(3),
      );
      expect(
        _inKey('security_center_critical',
            find.textContaining('can open without a lock')),
        findsNothing,
      );
      // Counts stay the saved assignment: offline does not change them.
      _expectDistribution(2, 1, 0, 1);
      _expectNoAbsoluteClaims(tester);
    });

    testWidgets(
        '11. a stale report is never SECURE: once the last SECURE check is '
        'older than the freshness limit it reads ATTENTION REQUIRED and '
        'Critical is no longer "Checks passed"', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      // The shared Phase 7 monitor over the same services, with a test
      // clock (the container's monitor uses the wall clock).
      // Anchored at the wall clock: the controller times its one-shot
      // stale re-render from the real clock.
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
      tester.view.physicalSize = const Size(1080, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        AppScope(
          container: fx.c,
          child: MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(
              body: SingleChildScrollView(
                child: SecurityCenterSection(healthMonitor: monitor),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_healthTitle(HealthPresentation.secureTitle), findsOneWidget);
      expect(_criticalStatus(CriticalProtectionStatus.checksPassed),
          findsOneWidget);
      final int probes = fx.watcher.getHealthCalls;

      // Time passes with no new check; the controller's stale re-render
      // (a one-shot timer, not polling) shows the aged result.
      now = now.add(
        ProtectionHealthEngine.defaultMaxAge + const Duration(seconds: 1),
      );
      await tester.pump(
        ProtectionHealthEngine.defaultMaxAge + const Duration(seconds: 1),
      );
      await tester.pump();

      expect(_healthTitle(HealthPresentation.secureTitle), findsNothing);
      expect(_healthTitle(HealthPresentation.attentionTitle), findsOneWidget);
      expect(
          _criticalStatus(CriticalProtectionStatus.attention), findsOneWidget);
      expect(
          _criticalStatus(CriticalProtectionStatus.checksPassed), findsNothing);
      expect(fx.watcher.getHealthCalls, probes,
          reason: 'staleness is shown without a new probe (no polling)');
    });

    testWidgets(
        '11b. unknown while checking is never SECURE: an earlier SECURE is '
        'hidden during Check again; Critical is "Not confirmed"',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      expect(_healthTitle(HealthPresentation.secureTitle), findsOneWidget);

      fx.watcher.getHealthGate = Completer<void>();
      await tester.tap(find.byKey(const Key('sc_check_again')));
      await tester.pump();
      await tester.pump();
      expect(_healthTitle(HealthPresentation.secureTitle), findsNothing);
      expect(_healthTitle(HealthPresentation.checkingTitle), findsOneWidget);
      expect(_criticalStatus(CriticalProtectionStatus.unconfirmed),
          findsOneWidget);

      fx.watcher.getHealthGate!.complete();
      await tester.pumpAndSettle();
      expect(_healthTitle(HealthPresentation.secureTitle), findsOneWidget);
    });
  });

  group('failures (SIMULATED)', () {
    testWidgets(
        '12. repository read failure shows "unavailable", never zero, and '
        'drops earlier counts; Try again recovers',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
        _chat: _L.standard,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      _expectDistribution(2, 1, 0, 1);

      fx.db.readError = StateError('simulated read failure');
      await _go(tester, 'nav_apps');
      await _openSecurity(tester);

      expect(find.byKey(const Key('sc_apps_unavailable')), findsOneWidget);
      expect(find.text(_S.appsUnavailableTitle), findsOneWidget);
      expect(find.byKey(const Key('sc_total')), findsNothing);
      expect(find.text(_S.totalLabel(0)), findsNothing);
      expect(find.text(_S.totalLabel(2)), findsNothing);
      expect(find.byKey(const Key('security_center_critical')), findsNothing);
      expect(find.byKey(const Key('sc_apps_empty')), findsNothing);

      fx.db.readError = null;
      await tester.tap(find.byKey(const Key('sc_retry_apps')));
      await tester.pumpAndSettle();
      _expectDistribution(2, 1, 0, 1);
    });

    testWidgets(
        '12b. while the read is pending a loading state is shown, not zero',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.standard,
      });
      await _pumpApp(tester, fx);
      fx.db.readGate = Completer<void>();
      await tester.tap(find.byKey(const Key('nav_security')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('sc_apps_loading')), findsOneWidget);
      expect(find.byKey(const Key('sc_total')), findsNothing);
      expect(find.byKey(const Key('sc_apps_empty')), findsNothing);

      fx.db.readGate!.complete();
      fx.db.readGate = null;
      await tester.pumpAndSettle();
      _expectDistribution(1, 1, 0, 0);
    });

    testWidgets(
        '13. native health unreadable: ATTENTION REQUIRED (could not '
        'confirm), Critical "Needs attention", never SECURE',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      fx.watcher.getHealthError = StateError('simulated bridge failure');
      await _pumpApp(tester, fx);
      await _openSecurity(tester);

      expect(_healthTitle(HealthPresentation.attentionTitle), findsOneWidget);
      expect(_healthTitle(HealthPresentation.secureTitle), findsNothing);
      expect(
        _inKey('sc_top_issue',
            find.text('Could not confirm the protection engine')),
        findsOneWidget,
      );
      expect(find.textContaining('simulated bridge failure'), findsNothing,
          reason: 'no raw technical error text');
      expect(
          _criticalStatus(CriticalProtectionStatus.attention), findsOneWidget);
      // Saved counts are still shown: they come from the repository.
      _expectDistribution(1, 0, 0, 1);
    });

    testWidgets(
        '13b. the health check itself fails: "Status unavailable", Critical '
        '"Not confirmed", never SECURE; no source at all is unavailable too',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      tester.view.physicalSize = const Size(1080, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      Widget host(Widget child, {AppContainer? container}) {
        final Widget app = MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(body: SingleChildScrollView(child: child)),
        );
        return container == null
            ? app
            : AppScope(container: container, child: app);
      }

      await tester.pumpWidget(
        host(
          SecurityCenterSection(healthMonitor: _FailingMonitor(fx.c)),
          container: fx.c,
        ),
      );
      await tester.pumpAndSettle();
      expect(_healthTitle(HealthPresentation.unavailableTitle), findsOneWidget);
      expect(_healthTitle(HealthPresentation.secureTitle), findsNothing);
      expect(_criticalStatus(CriticalProtectionStatus.unconfirmed),
          findsOneWidget);
      _expectDistribution(1, 0, 0, 1);

      // No container (no health source, no repository): both unavailable.
      await tester.pumpWidget(host(const SecurityCenterSection(key: Key('x'))));
      await tester.pumpAndSettle();
      expect(_healthTitle(HealthPresentation.unavailableTitle), findsOneWidget);
      expect(find.byKey(const Key('sc_apps_unavailable')), findsOneWidget);
      expect(find.byKey(const Key('sc_check_again')), findsNothing);
    });
  });

  group('navigation (SIMULATED)', () {
    testWidgets('14. Manage apps opens the Apps tab',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);

      await tester.tap(find.byKey(const Key('sc_manage_apps')));
      await tester.pumpAndSettle();
      expect(find.text(AppsScreen.description), findsOneWidget);

      await _openSecurity(tester);
      await tester.tap(find.byKey(const Key('sc_critical_manage')));
      await tester.pumpAndSettle();
      expect(find.text(AppsScreen.description), findsOneWidget);
    });

    testWidgets(
        '15. View details opens Health Details; closing re-checks once; a '
        'repair that continues on the Apps tab lands there',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.standard,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);

      await tester.tap(
        _inKey('sc_health_action', find.text(_S.viewDetailsLabel)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ProtectionHealthScreen), findsOneWidget);
      final int probes = fx.watcher.getHealthCalls;

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ProtectionHealthScreen), findsNothing);
      expect(fx.watcher.getHealthCalls, probes + 1,
          reason: 'one re-check after returning, no loop');
      await tester.pump(const Duration(seconds: 5));
      expect(fx.watcher.getHealthCalls, probes + 1, reason: 'no polling');

      // No protected apps → the Phase 7 repair continues on the Apps tab.
      await fx.c.protectedApps.remove(_bank);
      fx.watcher.protectionConfigured = false;
      await tester.tap(find.byKey(const Key('sc_check_again')));
      await tester.pumpAndSettle();
      await tester.tap(
        _inKey('sc_health_action', find.text(_S.fixProtectionLabel)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('health_repair_protection_not_configured')),
      );
      await tester.tap(
        find.byKey(const Key('health_repair_protection_not_configured')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ProtectionHealthScreen), findsNothing);
      expect(find.text(AppsScreen.description), findsOneWidget);
    });

    testWidgets(
        '16. returning from Settings refreshes health; returning to the '
        'tab after a change does not need a restart',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await _pumpApp(tester, fx);
      await _openSecurity(tester);
      expect(_healthTitle(HealthPresentation.secureTitle), findsOneWidget);

      // Settings tab → user changes nothing here, but Android Settings
      // revokes overlay meanwhile; returning to Security re-checks.
      await _go(tester, 'nav_settings');
      fx.overlay.overlayGranted = false;
      await _openSecurity(tester);
      expect(_healthTitle(HealthPresentation.offlineTitle), findsOneWidget);

      // Android Settings round trip (app resumes while Security is shown).
      fx.overlay.overlayGranted = true;
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
      expect(_healthTitle(HealthPresentation.secureTitle), findsOneWidget);
    });

    testWidgets(
        '17. tab switches keep the Security State and a pending challenge '
        'stays on top; only the exact PIN grants', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await _pumpApp(tester, fx);
      await fx.c.protectionBootstrap.synchronize();
      await _openSecurity(tester);
      final State<StatefulWidget> security =
          tester.state(find.byType(SecurityScreen, skipOffstage: false));
      final State<StatefulWidget> center =
          tester.state(find.byType(SecurityCenterSection, skipOffstage: false));

      fx.accessibility.emitForegroundPackage(_bank);
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      final Route<dynamic>? top =
          ModalRoute.of(tester.element(find.byType(PinUnlockScreen)));
      expect(top?.isCurrent, isTrue, reason: 'the challenge is on top');
      expect(fx.access.sessionFor(_bank), isNull);

      for (final String digit in _pin.split('')) {
        await tester.tap(find.byKey(Key('pin_key_$digit')));
        await tester.pumpAndSettle();
      }
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(fx.access.sessionFor(_bank), isNotNull);

      for (final String tab in <String>[
        'nav_home',
        'nav_apps',
        'nav_security',
        'nav_settings',
        'nav_security',
      ]) {
        await _go(tester, tab);
      }
      expect(
        identical(
          tester.state(find.byType(SecurityScreen, skipOffstage: false)),
          security,
        ),
        isTrue,
      );
      expect(
        identical(
          tester.state(find.byType(SecurityCenterSection, skipOffstage: false)),
          center,
        ),
        isTrue,
      );
    });

    testWidgets(
        '18. disposal while a health probe and a summary read are pending '
        'is safe', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.standard,
      });
      fx.watcher.getHealthGate = Completer<void>();
      fx.db.readGate = Completer<void>();
      tester.view.physicalSize = const Size(1080, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        AppScope(
          container: fx.c,
          child: MaterialApp(
            theme: AppTheme.dark,
            home: const Scaffold(
              body: SingleChildScrollView(child: SecurityCenterSection()),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      fx.watcher.getHealthGate!.complete();
      fx.db.readGate!.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('read-only boundary (SIMULATED)', () {
    testWidgets(
        '19. using the Security Center never writes levels or records, '
        'authorizes, grants grace, touches a challenge or restarts the '
        'watcher', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
        _chat: _L.standard,
      });
      fx.installed.usageAccessGranted = false; // ATTENTION → Fix shown
      await _pumpApp(tester, fx);
      final int writes = fx.db.writes;
      final List<int> before = <int>[
        fx.watcher.authorizePackageCalls,
        fx.watcher.revokeAllAuthorizationsCalls,
        fx.watcher.setGracePeriodCalls,
        fx.watcher.startCalls,
        fx.watcher.stopCalls,
        fx.overlay.markChallengeReadyCalls,
        fx.overlay.showLockChallengeCalls,
        fx.overlay.hideLockChallengeCalls,
      ];

      await _openSecurity(tester);
      await tester.tap(find.byKey(const Key('sc_check_again')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sc_critical_fix')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await _go(tester, 'nav_home');
      await _openSecurity(tester);

      expect(fx.db.writes, writes, reason: 'no level / record writes');
      expect(<int>[
        fx.watcher.authorizePackageCalls,
        fx.watcher.revokeAllAuthorizationsCalls,
        fx.watcher.setGracePeriodCalls,
        fx.watcher.startCalls,
        fx.watcher.stopCalls,
        fx.overlay.markChallengeReadyCalls,
        fx.overlay.showLockChallengeCalls,
        fx.overlay.hideLockChallengeCalls,
      ], before);
      expect(fx.watcher.authorizedPackages, isEmpty);
      expect(fx.watcher.pendingChallenge, isNull);
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(fx.access.sessionFor(_bank), isNull);
      expect(fx.access.sessionFor(_chat), isNull);
      final List<ProtectedApp> saved =
          (await fx.c.protectedApps.getProtectedApps()).valueOrNull!;
      expect(
        <String, AppSecurityLevel>{
          for (final ProtectedApp a in saved) a.packageName: a.securityLevel,
        },
        <String, AppSecurityLevel>{_bank: _L.critical, _chat: _L.standard},
      );
    });

    testWidgets(
        '20. no CR-2 bypass: a downgrade is never applied from here and a '
        'stricter native level is reported as held, not hidden',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(<String, AppSecurityLevel>{
        _bank: _L.critical,
      });
      await _pumpApp(tester, fx);
      await fx.c.protectionBootstrap.synchronize();
      expect(fx.c.protectionBootstrap.nativeLevelFor(_bank), _L.critical);

      // A saved downgrade that native has not confirmed yet: written to the
      // repository without the authorized CR-2 sync (simulated), so native
      // still enforces Critical.
      await fx.c.protectedApps.setSecurityLevel(_bank, _L.standard);
      final int configures = fx.watcher.configureCalls;
      await _openSecurity(tester);

      // Counts show the SAVED level; the stricter native level is reported
      // as held, and the Security Center never pushes the downgrade.
      _expectDistribution(1, 1, 0, 0);
      expect(find.byKey(const Key('sc_held_stricter')), findsOneWidget);
      expect(find.text(_S.heldStricterLabel(1)), findsOneWidget);
      expect(fx.c.protectionBootstrap.nativeLevelFor(_bank), _L.critical);
      expect(fx.watcher.configureCalls, configures,
          reason: 'no policy sync from the Security Center');
      expect(fx.watcher.authorizePackageCalls, 0);
      expect(fx.access.sessionFor(_bank), isNull);
    });
  });
}
