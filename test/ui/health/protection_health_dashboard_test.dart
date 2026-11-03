// Phase 7 / M2 — Health Dashboard, Issue Details and Fix Protection.
//
// SIMULATED: production widgets, router, Phase 7 / M1 engine + monitor and
// the in-memory container's static services. No Android Settings screen,
// permission grant or OEM behaviour is observed; physical-device QA for
// these flows is pending (docs/regression.md, Phase 7 / M2).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/router.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/security/credentials/biometric_options.dart';
import 'package:smart_app_lock/services/biometric_service.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/services/watcher_service.dart';
import 'package:smart_app_lock/ui/screens/apps/apps_screen.dart';
import 'package:smart_app_lock/ui/screens/health/health_presentation.dart';
import 'package:smart_app_lock/ui/screens/health/protection_health_screen.dart';
import 'package:smart_app_lock/ui/screens/home/home_screen.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/permissions/accessibility_setup_screen.dart';
import 'package:smart_app_lock/ui/screens/permissions/overlay_setup_screen.dart';
import 'package:smart_app_lock/ui/screens/permissions/usage_access_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/security/security_screen.dart';
import 'package:smart_app_lock/utilities/result.dart';

const String _pkg = 'com.example.private';

class _Bio implements BiometricService {
  bool hardware = true;
  bool enrolled = true;
  int authenticateCalls = 0;

  @override
  Future<Result<bool>> isSupported() async => Result.success(hardware);

  @override
  Future<Result<Set<BiometricKind>>> availableKinds() async =>
      Result.success(<BiometricKind>{if (enrolled) BiometricKind.strong});

  @override
  Future<Result<bool>> authenticate({
    required String reason,
    BiometricOptions? options,
  }) async {
    authenticateCalls++;
    return Result.success(false);
  }
}

class _Fx {
  _Fx(this.container, this.bio);

  final AppContainer container;
  final _Bio bio;

  StaticWatcherService get watcher => container.watcher as StaticWatcherService;
  StaticOverlayLockService get overlay =>
      container.overlay as StaticOverlayLockService;
  StaticAccessibilityLockService get accessibility =>
      container.accessibility as StaticAccessibilityLockService;
  StaticInstalledAppsService get installed =>
      container.installedAppsService as StaticInstalledAppsService;

  /// A healthy simulated device; [pin]/[app] control configuration.
  static Future<_Fx> create({bool pin = true, bool app = true}) async {
    final _Bio bio = _Bio();
    final AppContainer c = AppContainer.inMemory(
      biometrics: bio,
      accessibilityEnabled: true,
      overlayGranted: true,
    );
    if (pin) await c.auth.enrollPin('2468');
    if (app) {
      await c.protectedApps.add(
        ProtectedApp(
          packageName: _pkg,
          label: 'Private',
          addedAt: DateTime(2026, 11, 1),
        ),
      );
    }
    (c.watcher as StaticWatcherService)
      ..protectionConfigured = pin && app
      ..running = true
      ..accessibilityServiceConnected = true
      ..shieldArmed = true
      ..challengePending = false
      ..backgroundRestricted = false
      ..powerSaveMode = false
      ..ignoringBatteryOptimizations = false
      ..sdkInt = 34;
    return _Fx(c, bio);
  }
}

Future<void> _pumpShell(WidgetTester tester, AppContainer? container) async {
  tester.view.physicalSize = const Size(1080, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final Widget app = MaterialApp(
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    onGenerateRoute: AppRouter.onGenerateRoute,
    onGenerateInitialRoutes: AppRouter.onGenerateInitialRoutes,
  );
  await tester.pumpWidget(
    container == null ? app : AppScope(container: container, child: app),
  );
  await tester.pumpAndSettle();
}

Finder _inHome(Finder matching) => find.descendant(
      of: find.byKey(const Key('home_protection_status')),
      matching: matching,
    );

Finder _inDetails(Finder matching) => find.descendant(
      of: find.byType(ProtectionHealthScreen),
      matching: matching,
    );

Future<void> _checkAgainOnHome(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('home_check_again')));
  await tester.pumpAndSettle();
}

Future<void> _openDetails(WidgetTester tester) async {
  final Finder fix = _inHome(find.text('Fix protection'));
  final Finder button =
      fix.evaluate().isEmpty ? _inHome(find.text('View details')) : fix;
  await tester.tap(button);
  await tester.pumpAndSettle();
  expect(find.byType(ProtectionHealthScreen), findsOneWidget);
}

Future<void> _tapKey(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

/// Draws [nodes] on the production pattern grid (mirrors the helper in
/// test/ui/lock_challenge_test.dart: bounds-derived node centres, a small
/// horizontal arena-winning move, then micro-stepped strokes).
Future<void> _drawPattern(WidgetTester tester, List<int> nodes) async {
  await tester.pump(const Duration(milliseconds: 450));
  final Rect bounds = tester.getRect(find.byType(DsPatternGrid));
  final double pad = bounds.width * 0.10;
  final double step = (bounds.width - 2 * pad) / 2;
  Offset center(int node) => Offset(
        bounds.left + pad + ((node - 1) % 3) * step,
        bounds.top + pad + ((node - 1) ~/ 3) * step,
      );
  final TestGesture gesture = await tester.startGesture(center(nodes.first));
  await tester.pump();
  await gesture.moveBy(const Offset(20, 0));
  await tester.pump();
  Offset current = center(nodes.first).translate(20, 0);
  for (final int node in nodes.skip(1)) {
    final Offset target = center(node);
    for (int s = 1; s <= 6; s++) {
      await gesture.moveTo(Offset(
        current.dx + (target.dx - current.dx) * s / 6,
        current.dy + (target.dy - current.dy) * s / 6,
      ));
      await tester.pump();
    }
    current = target;
  }
  await gesture.up();
  await tester.pump();
}

String? _notice(WidgetTester tester) {
  final Finder f = find.descendant(
    of: find.byKey(const Key('health_repair_notice')),
    matching: find.byType(Text),
  );
  return f.evaluate().isEmpty ? null : tester.widget<Text>(f.first).data;
}

void main() {
  group('Health Dashboard on Home', () {
    testWidgets('SECURE renders calmly from the real M1 report',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pumpShell(tester, fx.container);

      expect(_inHome(find.text('PROTECTION STATUS')), findsOneWidget);
      expect(
          _inHome(find.text(HealthPresentation.secureTitle)), findsOneWidget);
      expect(
        _inHome(find.text('All protection checks passed on the last check.')),
        findsOneWidget,
      );
      expect(_inHome(find.text('View details')), findsOneWidget);
      expect(find.byKey(const Key('home_top_issue')), findsNothing);
      expect(find.textContaining('100%'), findsNothing);
      // The old hard-coded placeholder rows are gone.
      expect(find.text('Unlock PIN'), findsNothing);
      expect(find.text('Active profile'), findsNothing);
    });

    testWidgets('ATTENTION REQUIRED names the top issue and offers a fix',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      fx.accessibility.enabled = false;
      await _pumpShell(tester, fx.container);

      expect(
        _inHome(find.text(HealthPresentation.attentionTitle)),
        findsOneWidget,
      );
      expect(_inHome(find.text('Fix protection')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('home_top_issue'))).data,
        'Accessibility service is not turned on',
      );
      expect(_inHome(find.text(HealthPresentation.secureTitle)), findsNothing);
    });

    testWidgets('PROTECTION OFFLINE when configured protection is unavailable',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await fx.container.preferences.markCapabilityEverGranted('overlay');
      fx.overlay.overlayGranted = false;
      await _pumpShell(tester, fx.container);

      expect(
          _inHome(find.text(HealthPresentation.offlineTitle)), findsOneWidget);
      expect(
        _inHome(find.text(HealthPresentation.offlineMessage)),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('home_top_issue'))).data,
        'Display over other apps was turned off',
      );
    });

    testWidgets('first-time setup is OFFLINE but worded as setup, not failure',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(pin: false, app: false);
      await _pumpShell(tester, fx.container);

      expect(
          _inHome(find.text(HealthPresentation.offlineTitle)), findsOneWidget);
      expect(_inHome(find.textContaining('Setup is not finished')),
          findsOneWidget);
      expect(find.textContaining('may not work'), findsNothing);
      await _openDetails(tester);
      expect(_inDetails(find.text('Setup needed')), findsOneWidget);
      expect(_inDetails(find.text('Finish setting up protection')),
          findsOneWidget);
      expect(_inDetails(find.text('Stopped')), findsNothing);
    });

    testWidgets('a revoked capability is worded differently from never set up',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      fx.overlay.overlayGranted = false; // never granted: setup
      await _pumpShell(tester, fx.container);
      await _openDetails(tester);
      expect(
          _inDetails(find.text('Display over other apps is not allowed yet')),
          findsOneWidget);
      expect(_inDetails(find.text('Setup needed')), findsOneWidget);

      await fx.container.preferences.markCapabilityEverGranted('overlay');
      await _tapKey(tester, const Key('health_check_again'));
      expect(_inDetails(find.text('Display over other apps was turned off')),
          findsOneWidget);
      expect(_inDetails(find.text('Permission turned off')), findsOneWidget);
    });

    testWidgets('no protected apps reads as the user\'s choice',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(app: false);
      await _pumpShell(tester, fx.container);
      expect(_inHome(find.textContaining('No apps are protected right now')),
          findsOneWidget);
      await _openDetails(tester);
      expect(_inDetails(find.text('Your choice')), findsOneWidget);
      expect(_inDetails(find.text('Choose apps')), findsOneWidget);
    });

    testWidgets('UNKNOWN native health is never shown as SECURE',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      fx.watcher.getHealthError = StateError('bridge down');
      await _pumpShell(tester, fx.container);

      expect(
        _inHome(find.text(HealthPresentation.attentionTitle)),
        findsOneWidget,
      );
      expect(_inHome(find.text(HealthPresentation.secureTitle)), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const Key('home_top_issue'))).data,
        'Could not confirm the protection engine',
      );
      expect(find.textContaining('bridge down'), findsNothing,
          reason: 'no raw technical error text');
    });

    testWidgets(
        'loading shows a neutral placeholder, never SECURE; repeated '
        'taps share one probe', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      fx.watcher.getHealthGate = Completer<void>();
      await _pumpShell(tester, fx.container);

      expect(
          _inHome(find.text(HealthPresentation.checkingTitle)), findsOneWidget);
      expect(_inHome(find.text(HealthPresentation.secureTitle)), findsNothing);
      final TextButton check =
          tester.widget<TextButton>(find.byKey(const Key('home_check_again')));
      expect(check.onPressed, isNull, reason: 'disabled while checking');
      final int calls = fx.watcher.getHealthCalls;

      fx.watcher.getHealthGate!.complete();
      fx.watcher.getHealthGate = null;
      await tester.pumpAndSettle();
      expect(
          _inHome(find.text(HealthPresentation.secureTitle)), findsOneWidget);
      expect(fx.watcher.getHealthCalls, calls, reason: 'one shared probe');
    });

    testWidgets(
        'Home refreshes when its tab becomes visible again, not while '
        'hidden (no polling)', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pumpShell(tester, fx.container);
      final int afterStart = fx.watcher.getHealthCalls;

      await tester.tap(find.byKey(const Key('nav_settings')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(minutes: 2));
      final int hidden = fx.watcher.getHealthCalls;

      await tester.tap(find.byKey(const Key('nav_home')));
      await tester.pumpAndSettle();
      expect(fx.watcher.getHealthCalls, greaterThan(hidden));
      expect(hidden - afterStart, lessThanOrEqualTo(1),
          reason: 'at most the Security tab sync read, no timer probes');
    });

    testWidgets(
        'MainShell isActive wiring: tab switches keep every tab State and '
        'probe exactly once per return to Home', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pumpShell(tester, fx.container);
      State<StatefulWidget> stateOf(Type type) =>
          tester.state(find.byType(type, skipOffstage: false));
      final State<StatefulWidget> home = stateOf(HomeScreen);
      final State<StatefulWidget> apps = stateOf(AppsScreen);
      final State<StatefulWidget> security = stateOf(SecurityScreen);
      final int probes = fx.watcher.getHealthCalls;
      final int configures = fx.watcher.configureCalls;

      for (final String tab in <String>[
        'nav_apps',
        'nav_security',
        'nav_settings',
        'nav_smart',
        'nav_smart', // re-selecting the visible tab
      ]) {
        await tester.tap(find.byKey(Key(tab)));
        await tester.pumpAndSettle();
      }
      // Phase 9 / M1 (intentionally updated): opening the Security tab is
      // now its own refresh point (the Security Center checks health once
      // per activation). Home still never probes while hidden, and no
      // other tab, re-selection or shell rebuild probes.
      expect(fx.watcher.getHealthCalls, probes + 1,
          reason: 'one probe from the Security tab activation only');

      await tester.tap(find.byKey(const Key('nav_home')));
      await tester.pumpAndSettle();
      expect(fx.watcher.getHealthCalls, probes + 2);
      await tester.tap(find.byKey(const Key('nav_home')));
      await tester.pumpAndSettle();
      expect(fx.watcher.getHealthCalls, probes + 2);

      expect(identical(stateOf(HomeScreen), home), isTrue);
      expect(identical(stateOf(AppsScreen), apps), isTrue);
      expect(identical(stateOf(SecurityScreen), security), isTrue);
      expect(fx.watcher.configureCalls, configures,
          reason: 'Security was not recreated (its initState re-syncs)');
    });

    testWidgets('a disposed dashboard ignores a late refresh result',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      fx.watcher.getHealthGate = Completer<void>();
      await _pumpShell(tester, fx.container);
      await tester.pumpWidget(const SizedBox());
      fx.watcher.getHealthGate!.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('without a container the status is unavailable, never SECURE',
        (WidgetTester tester) async {
      await _pumpShell(tester, null);
      expect(_inHome(find.text(HealthPresentation.unavailableTitle)),
          findsOneWidget);
      expect(_inHome(find.text(HealthPresentation.secureTitle)), findsNothing);
      expect(find.byKey(const Key('home_check_again')), findsNothing);
    });
  });

  group('Issue Details', () {
    testWidgets(
        'Home → details shows every issue ordered by severity; back '
        'refreshes Home', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await fx.container.preferences.markCapabilityEverGranted('overlay');
      fx.overlay.overlayGranted = false; // offline
      fx.watcher.notificationPermissionGranted = false; // attention
      fx.watcher.powerSaveMode = true; // advisory
      await _pumpShell(tester, fx.container);

      expect(
        tester.widget<Text>(find.byKey(const Key('home_top_issue'))).data,
        'Display over other apps was turned off (+1 more)',
      );
      await _openDetails(tester);
      expect(_inDetails(find.text(HealthPresentation.offlineTitle)),
          findsOneWidget);
      expect(_inDetails(find.text('Issues (2)')), findsOneWidget);
      expect(_inDetails(find.text('Advisories')), findsOneWidget);

      double y(String key) =>
          tester.getTopLeft(find.byKey(ValueKey<String>(key))).dy;
      final double overlay = y('health_issue_overlay_unavailable_overlay');
      final double notif =
          y('health_issue_notifications_disabled_notifications');
      final double saver = y('health_issue_battery_saver_on_battery_saver');
      expect(overlay, lessThan(notif), reason: 'offline before attention');
      expect(notif, lessThan(saver), reason: 'attention before advisory');
      expect(find.byKey(const Key('health_scope_note')), findsOneWidget);

      final int before = fx.watcher.getHealthCalls;
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ProtectionHealthScreen), findsNothing);
      expect(fx.watcher.getHealthCalls, greaterThan(before));
    });

    testWidgets('a failed fresh check reports unknown, not success',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      fx.accessibility.enabled = false;
      await _pumpShell(tester, fx.container);
      await _openDetails(tester);
      fx.watcher.getHealthError = StateError('down');
      await _tapKey(tester, const Key('health_check_again'));
      expect(
          _inDetails(find.text(HealthPresentation.secureTitle)), findsNothing);
      expect(
        _inDetails(find.text('Could not confirm the protection engine')),
        findsOneWidget,
      );
    });
  });

  group('Fix Protection', () {
    testWidgets(
        'overlay repair opens the existing setup screen; the result '
        'comes only from a fresh check', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await fx.container.preferences.markCapabilityEverGranted('overlay');
      fx.overlay.overlayGranted = false;
      await _pumpShell(tester, fx.container);
      await _openDetails(tester);

      await _tapKey(tester, const Key('health_repair_overlay_unavailable'));
      expect(find.byType(OverlaySetupScreen), findsOneWidget);
      expect(fx.overlay.overlayGranted, isFalse, reason: 'never auto-granted');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(_notice(tester), contains('still reports'));

      await _tapKey(tester, const Key('health_repair_overlay_unavailable'));
      fx.overlay.overlayGranted = true; // the user granted it in Settings
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(_notice(tester), contains('no longer reports'));
      expect(_inDetails(find.text(HealthPresentation.secureTitle)),
          findsOneWidget);
    });

    testWidgets(
        'Accessibility and Usage Access repairs route to their setup '
        'screens', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      fx.accessibility.enabled = false;
      fx.installed.usageAccessGranted = false;
      await _pumpShell(tester, fx.container);
      await _openDetails(tester);

      await _tapKey(tester, const Key('health_repair_detection_offline'));
      expect(find.byType(AccessibilitySetupScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await _tapKey(
        tester,
        const Key('health_repair_usage_access_unavailable'),
      );
      expect(find.byType(UsageAccessScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(fx.accessibility.enabled, isFalse);
      expect(fx.installed.usageAccessGranted, isFalse);
    });

    testWidgets('first-time setup repair continues on the Security tab',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(pin: false, app: false);
      await _pumpShell(tester, fx.container);
      await _openDetails(tester);
      await _tapKey(
        tester,
        const Key('health_repair_protection_not_configured'),
      );
      expect(find.byType(ProtectionHealthScreen), findsNothing);
      expect(find.text(SecurityScreen.description), findsOneWidget);
    });

    testWidgets('no-protected-apps repair continues on the Apps tab',
        (WidgetTester tester) async {
      final _Fx noApps = await _Fx.create(app: false);
      await _pumpShell(tester, noApps.container);
      await _openDetails(tester);
      await _tapKey(
        tester,
        const Key('health_repair_protection_not_configured'),
      );
      expect(find.text(AppsScreen.description), findsOneWidget);
    });

    testWidgets(
        'notification repair opens Android Settings and never claims '
        'success', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      fx.watcher.notificationPermissionGranted = false;
      await _pumpShell(tester, fx.container);
      await _openDetails(tester);

      await _tapKey(tester, const Key('health_repair_notifications_disabled'));
      expect(fx.watcher.openedSettings, <ProtectionSettingsTarget>[
        ProtectionSettingsTarget.notifications,
      ]);
      expect(_notice(tester), ProtectionHealthScreen.settingsOpenedNotice);
      expect(fx.watcher.notificationPermissionGranted, isFalse);
      expect(_inDetails(find.text(HealthPresentation.attentionTitle)),
          findsOneWidget);
    });

    testWidgets(
        'background restriction: App info link plus OEM guidance; a '
        'failed open falls back to manual steps', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      fx.watcher.backgroundRestricted = true;
      fx.watcher.settingsOpenResult = false;
      await _pumpShell(tester, fx.container);
      await _openDetails(tester);

      expect(
        tester
            .widget<Text>(
              find.byKey(
                const ValueKey<String>('health_guidance_background_restricted'),
              ),
            )
            .data,
        contains('ColorOS'),
      );
      await _tapKey(tester, const Key('health_repair_background_restricted'));
      expect(fx.watcher.openedSettings, <ProtectionSettingsTarget>[
        ProtectionSettingsTarget.appDetails,
      ]);
      expect(_notice(tester), ProtectionHealthScreen.settingsFailedNotice);
    });

    testWidgets(
        'watcher stopped: one user-initiated restart through the '
        'existing synchronization, confirmed by a fresh check',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pumpShell(tester, fx.container);
      fx.watcher.running = false;
      await _checkAgainOnHome(tester);
      expect(
        tester.widget<Text>(find.byKey(const Key('home_top_issue'))).data,
        'Protection service stopped',
      );
      await _openDetails(tester);
      final int starts = fx.watcher.startCalls;
      final int configures = fx.watcher.configureCalls;
      final int authorizations = fx.watcher.authorizePackageCalls;
      final int revocations = fx.watcher.revokeAllAuthorizationsCalls;

      await _tapKey(tester, const Key('health_repair_watcher_not_running'));
      expect(fx.watcher.startCalls, starts + 1, reason: 'exactly one restart');
      expect(
        fx.watcher.configureCalls,
        configures + 1,
        reason: 'one synchronization per tap',
      );
      expect(_notice(tester), contains('no longer reports'));
      expect(fx.watcher.authorizePackageCalls, authorizations);
      expect(fx.watcher.revokeAllAuthorizationsCalls, revocations);

      // No automatic retries afterwards.
      await tester.pump(const Duration(minutes: 1));
      expect(fx.watcher.startCalls, starts + 1);
      expect(fx.watcher.configureCalls, configures + 1);
    });

    testWidgets('a restart that does not help is reported honestly',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await _pumpShell(tester, fx.container);
      fx.watcher.shieldArmed = false;
      await _checkAgainOnHome(tester);
      await _openDetails(tester);
      await _tapKey(tester, const Key('health_repair_shield_not_armed'));
      expect(_notice(tester), contains('still reports'));
    });

    testWidgets('biometric absence is advisory guidance with no fake action',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      await fx.container.auth.updateBiometricOptions(BiometricOptions.defaults);
      fx.bio.enrolled = false;
      await _pumpShell(tester, fx.container);

      expect(_inHome(find.text(HealthPresentation.secureTitle)), findsOneWidget,
          reason: 'advisory never changes the state');
      await _openDetails(tester);
      expect(
          _inDetails(find.text('No fingerprint is enrolled')), findsOneWidget);
      expect(_inDetails(find.text('Advisory')), findsOneWidget);
      expect(
        find.byKey(
            const ValueKey<String>('health_repair_biometric_unavailable')),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey<String>('health_guidance_biometric_unavailable'),
        ),
        findsOneWidget,
      );
      expect(fx.bio.authenticateCalls, 0, reason: 'never prompts');
    });

    testWidgets(
        'Restart protection and a Settings repair keep a pending ticket and '
        'never authorize, mark ready or touch the challenge',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      fx.watcher.notificationPermissionGranted = false;
      await _pumpShell(tester, fx.container);
      fx.watcher
        ..shieldArmed = false
        ..pendingChallenge = _pkg
        ..pendingChallengeGeneration = 7;
      await _checkAgainOnHome(tester);
      await _openDetails(tester);

      await _tapKey(tester, const Key('health_repair_shield_not_armed'));
      expect(_notice(tester), contains('still reports'));
      await _tapKey(tester, const Key('health_repair_notifications_disabled'));
      expect(_notice(tester), ProtectionHealthScreen.settingsOpenedNotice);

      expect(fx.watcher.pendingChallenge, _pkg);
      expect(fx.watcher.pendingChallengeGeneration, 7);
      expect(fx.watcher.authorizedPackages, isEmpty);
      expect(fx.watcher.authorizePackageCalls, 0);
      expect(fx.watcher.revokeAllAuthorizationsCalls, 0);
      expect(fx.overlay.markChallengeReadyCalls, 0);
      expect(fx.overlay.showLockChallengeCalls, 0);
      expect(fx.overlay.hideLockChallengeCalls, 0);
      expect(
        (fx.container.accessController as DefaultAccessController)
            .sessionFor(_pkg),
        isNull,
      );
    });

    testWidgets('viewing health and refreshing grants nothing',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      fx.accessibility.enabled = false;
      fx.overlay.overlayGranted = false;
      fx.installed.usageAccessGranted = false;
      await _pumpShell(tester, fx.container);
      final int configures = fx.watcher.configureCalls;
      final int starts = fx.watcher.startCalls;
      await _openDetails(tester);
      for (int i = 0; i < 3; i++) {
        await _tapKey(tester, const Key('health_check_again'));
      }
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(fx.overlay.overlayGranted, isFalse);
      expect(fx.overlay.requestCalls, 0);
      expect(fx.accessibility.enabled, isFalse);
      expect(fx.accessibility.requestServiceEnableCalls, 0);
      expect(fx.installed.usageAccessGranted, isFalse);
      expect(fx.installed.requestUsageAccessCalls, 0);
      expect(fx.watcher.openedSettings, isEmpty);
      expect(fx.watcher.authorizePackageCalls, 0);
      expect(fx.watcher.configureCalls, configures);
      expect(fx.watcher.startCalls, starts);
    });
  });

  group('PIN / pattern challenge stays unaffected (SIMULATED)', () {
    Future<AppContainer> pumpApp(WidgetTester tester, _Fx fx) async {
      tester.view.physicalSize = const Size(1080, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(SmartAppLockApp(container: fx.container));
      await tester.pumpAndSettle();
      return fx.container;
    }

    testWidgets(
        'a protected app opened while health details are shown is '
        'challenged on top; only the exact PIN grants',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      final AppContainer c = await pumpApp(tester, fx);
      await c.protectionBootstrap.synchronize();
      await _openDetails(tester);
      final String? pendingBefore = fx.watcher.pendingChallenge;

      fx.accessibility.emitForegroundPackage(_pkg);
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      final Route<dynamic>? top =
          ModalRoute.of(tester.element(find.byType(PinUnlockScreen)));
      expect(top?.isCurrent, isTrue, reason: 'the challenge is on top');
      expect(
        (c.accessController as DefaultAccessController).sessionFor(_pkg),
        isNull,
      );
      expect(pendingBefore, isNull);

      for (final String digit in '2468'.split('')) {
        await tester.tap(find.byKey(Key('pin_key_$digit')));
        await tester.pumpAndSettle();
      }
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(
        (c.accessController as DefaultAccessController).sessionFor(_pkg),
        isNotNull,
      );
      expect(find.byType(ProtectionHealthScreen), findsOneWidget,
          reason: 'health details are still underneath');
    });

    testWidgets(
        'a pattern challenge over health details still works: a wrong '
        'pattern keeps it, only the exact pattern grants',
        (WidgetTester tester) async {
      final _Fx fx = await _Fx.create(pin: false);
      await fx.container.auth.enrollPattern(const <int>[3, 6, 9, 8]);
      final AppContainer c = await pumpApp(tester, fx);
      await c.protectionBootstrap.synchronize();
      await _openDetails(tester);

      fx.accessibility.emitForegroundPackage(_pkg);
      await tester.pumpAndSettle();
      expect(find.byType(PatternUnlockScreen), findsOneWidget);

      await _drawPattern(tester, const <int>[1, 2, 3, 5]);
      await tester.pumpAndSettle();
      expect(find.byType(PatternUnlockScreen), findsOneWidget);
      expect(
        (c.accessController as DefaultAccessController).sessionFor(_pkg),
        isNull,
      );

      await _drawPattern(tester, const <int>[3, 6, 9, 8]);
      await tester.pumpAndSettle();
      expect(find.byType(PatternUnlockScreen), findsNothing);
      expect(
        (c.accessController as DefaultAccessController).sessionFor(_pkg),
        isNotNull,
      );
      expect(find.byType(ProtectionHealthScreen), findsOneWidget,
          reason: 'health details are still underneath');
    });

    testWidgets(
        'opening Android Settings from a repair and returning does '
        'not unlock a protected app', (WidgetTester tester) async {
      final _Fx fx = await _Fx.create();
      fx.watcher.notificationPermissionGranted = false;
      final AppContainer c = await pumpApp(tester, fx);
      await c.protectionBootstrap.synchronize();
      await _openDetails(tester);

      await _tapKey(tester, const Key('health_repair_notifications_disabled'));
      expect(fx.watcher.openedSettings, isNotEmpty);
      expect(fx.watcher.authorizePackageCalls, 0);

      fx.accessibility.emitForegroundPackage(_pkg);
      await tester.pumpAndSettle();
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(
        (c.accessController as DefaultAccessController).sessionFor(_pkg),
        isNull,
        reason: 'no session without the PIN',
      );
      expect(fx.watcher.authorizePackageCalls, 0);
    });
  });
}
