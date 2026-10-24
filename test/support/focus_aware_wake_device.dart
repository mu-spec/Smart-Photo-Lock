import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_native_challenge_contract.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_screen_state_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';

/// Phase 5 / Milestone 3 — Fix #3: a device harness whose Flutter lifecycle
/// follows window focus, as the real Android embedding does.
///
/// Flutter's `LifecycleChannel` (engine revision used by Flutter 3.47.7)
/// maps Android state plus window focus as follows:
///
/// | Android Activity | Window focused | Flutter state |
/// |------------------|----------------|---------------|
/// | resumed          | true           | resumed       |
/// | resumed          | false          | inactive      |
/// | paused           | any            | inactive      |
/// | stopped          | any            | paused        |
///
/// `FlutterFragment` (used by `FlutterFragmentActivity`) reports focus of
/// the Activity window only. The native protection shield is a separate,
/// FOCUSABLE overlay window. While it is visible it owns input focus, so
/// the Activity window is unfocused; the keyguard owns focus while it is
/// locked. This harness therefore NEVER delivers `resumed` while the
/// shield is visible or the keyguard is locked. It only reaches `resumed`
/// after native has hidden the shield (an accepted ready handoff) and the
/// keyguard is gone. Every lifecycle change steps through the legal ladder
/// (resumed <-> inactive <-> hidden <-> paused), as the framework does.
enum AndroidActivityState { resumed, paused, stopped }

/// One Flutter lifecycle delivery, with the window/native state observed
/// at the instant it was delivered (before any Dart reaction ran).
class LifecycleDelivery {
  const LifecycleDelivery({
    required this.state,
    required this.shieldVisible,
    required this.keyguardLocked,
    required this.activityWindowFocused,
    required this.readyAcceptedBefore,
  });

  final AppLifecycleState state;
  final bool shieldVisible;
  final bool keyguardLocked;
  final bool activityWindowFocused;
  final int readyAcceptedBefore;

  @override
  String toString() => '${state.name}(shield=$shieldVisible, '
      'keyguard=$keyguardLocked, focused=$activityWindowFocused)';
}

const String launcherPackage = 'com.oppo.launcher';
const String systemUiPackage = 'com.android.systemui';

class FocusAwareWakeDevice {
  FocusAwareWakeDevice._(
    this.tester,
    this.container,
    this.native,
    this.protectedPackage,
  );

  final WidgetTester tester;
  final AppContainer container;
  final StaticNativeChallengeContract native;
  final String protectedPackage;

  AndroidActivityState _android = AndroidActivityState.resumed;
  AppLifecycleState _flutter = AppLifecycleState.resumed;

  /// Every Flutter lifecycle state delivered to the app, in order.
  final List<AppLifecycleState> deliveredStates = <AppLifecycleState>[];

  /// Every delivery with the focus/shield/keyguard state at that instant.
  final List<LifecycleDelivery> deliveries = <LifecycleDelivery>[];

  static const List<AppLifecycleState> _ladder = <AppLifecycleState>[
    AppLifecycleState.resumed,
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ];

  AndroidActivityState get androidState => _android;
  AppLifecycleState get flutterState => _flutter;

  /// Whether the MainActivity window owns input focus.
  bool get activityWindowFocused =>
      _android == AndroidActivityState.resumed &&
      !native.shieldVisible &&
      !native.keyguardLocked;

  AppLifecycleState get _expectedFlutterState {
    switch (_android) {
      case AndroidActivityState.resumed:
        return activityWindowFocused
            ? AppLifecycleState.resumed
            : AppLifecycleState.inactive;
      case AndroidActivityState.paused:
        return AppLifecycleState.inactive;
      case AndroidActivityState.stopped:
        return AppLifecycleState.paused;
    }
  }

  /// Moves the Flutter lifecycle to the state implied by the Android
  /// state and current window focus.
  ///
  /// One engine message (for example `paused -> inactive`) is expanded
  /// into the legal ladder steps and delivered synchronously, as the
  /// framework does (`paused -> hidden -> inactive`). A frame is pumped
  /// afterwards; if Dart's reaction changed focus (for example, an
  /// accepted handoff hid the shield), the next engine message follows.
  /// The target is derived from focus at the instant of delivery, so a
  /// `resumed` is never delivered while the shield or keyguard owns focus.
  Future<void> syncLifecycle() async {
    for (int guard = 0; guard < 8; guard++) {
      final AppLifecycleState target = _expectedFlutterState;
      if (target == _flutter) return;
      while (_flutter != target) {
        final int index = _ladder.indexOf(_flutter);
        final int goal = _ladder.indexOf(target);
        _flutter = _ladder[index + (goal > index ? 1 : -1)];
        deliveredStates.add(_flutter);
        deliveries.add(LifecycleDelivery(
          state: _flutter,
          shieldVisible: native.shieldVisible,
          keyguardLocked: native.keyguardLocked,
          activityWindowFocused: activityWindowFocused,
          readyAcceptedBefore: native.readyAccepted,
        ));
        tester.binding.handleAppLifecycleStateChanged(_flutter);
      }
      await tester.pump();
    }
  }

  /// Deliveries of `resumed` made while the Activity window was NOT
  /// focused (shield or keyguard visible). Must always be empty.
  List<LifecycleDelivery> get resumedWhileUnfocused => deliveries
      .where((LifecycleDelivery d) =>
          d.state == AppLifecycleState.resumed &&
          (d.shieldVisible || d.keyguardLocked || !d.activityWindowFocused))
      .toList();

  /// Advances fake time in [step]s, re-deriving focus after each step, so
  /// a shield hidden by an accepted handoff is followed by `resumed`.
  Future<void> pumpFor(
    Duration total, {
    Duration step = const Duration(milliseconds: 100),
  }) async {
    Duration elapsed = Duration.zero;
    while (elapsed < total) {
      await tester.pump(step);
      await syncLifecycle();
      elapsed += step;
    }
  }

  StaticScreenStateService get _screen =>
      container.screenState as StaticScreenStateService;

  StaticAccessibilityLockService get _accessibility =>
      container.accessibility as StaticAccessibilityLockService;

  StaticInstalledAppsService get apps =>
      container.installedAppsService as StaticInstalledAppsService;

  StaticOverlayLockService get overlay =>
      container.overlay as StaticOverlayLockService;

  /// Native and Dart both observe a foreground package (Accessibility).
  Future<void> reportForeground(String packageName) async {
    native.reportForeground(packageName);
    _accessibility.emitForegroundPackage(packageName);
    await tester.pump();
  }

  /// The user leaves Smart App Lock for the launcher (Activity stops).
  Future<void> leaveToLauncher() async {
    native.onActivityPaused();
    _android = AndroidActivityState.stopped;
    await syncLifecycle();
    await reportForeground(launcherPackage);
    await pumpFor(const Duration(milliseconds: 300));
  }

  /// The user opens the protected app from the launcher. Detection
  /// raises the shield and promotes Smart App Lock's task; the Activity
  /// resumes afterwards ([activityResumes]).
  Future<void> openProtectedApp() async {
    apps.foregroundPackage = protectedPackage;
    await reportForeground(protectedPackage);
    await pumpFor(const Duration(milliseconds: 300));
  }

  /// MainActivity.onResume. Native marks the Activity resumed and
  /// re-asserts the shield for a pending ticket; Flutter then follows
  /// focus (inactive behind the shield or the keyguard).
  Future<void> activityResumes({
    Duration settle = const Duration(milliseconds: 300),
  }) async {
    native.onActivityResumed();
    _android = AndroidActivityState.resumed;
    await syncLifecycle();
    if (settle > Duration.zero) await pumpFor(settle);
  }

  /// MainActivity.onPause then onStop (for example, the task is covered).
  Future<void> activityStops() async {
    native.onActivityPaused();
    _android = AndroidActivityState.stopped;
    await syncLifecycle();
  }

  /// Power button: Activity pauses and stops, the native receiver issues
  /// a fresh wake generation and raises the shield, Dart is told too.
  Future<void> screenOff() async {
    native.onActivityPaused();
    _android = AndroidActivityState.stopped;
    await syncLifecycle();
    native.screenOff();
    _screen.emitScreenOff();
    await tester.pump();
    native.lockKeyguard();
    await tester.pump();
  }

  /// Display on behind the keyguard. Detection sees only System UI and
  /// usage events report nothing: no protected package is observed.
  Future<void> screenOnBehindKeyguard() async {
    apps.foregroundPackage = null;
    native.screenOn();
    _screen.emitScreenOn();
    await tester.pump();
    _accessibility.emitForegroundPackage(systemUiPackage);
    await tester.pump();
  }

  /// The device credential is accepted; USER_PRESENT recovery runs.
  Future<void> dismissKeyguard() async {
    native.dismissKeyguard();
    await syncLifecycle();
    await tester.pump();
  }

  /// System Home: the Activity pauses and stops, the launcher is
  /// reported. The native shield is not touched by this harness.
  Future<void> pressHome() async {
    native.onActivityPaused();
    _android = AndroidActivityState.stopped;
    await syncLifecycle();
    apps.foregroundPackage = launcherPackage;
    await reportForeground(launcherPackage);
    await pumpFor(const Duration(milliseconds: 300));
  }

  Future<void> enterPin(String pin) async {
    for (final String digit in pin.split('')) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pump();
      await pumpFor(const Duration(milliseconds: 400));
    }
  }

  /// Whether a challenge route sits above the shell route.
  bool challengeRouteOnStack() =>
      tester.state<NavigatorState>(find.byType(Navigator).first).canPop();

  Object? dartSession() =>
      (container.accessController as DefaultAccessController)
          .sessionFor(protectedPackage);
}

/// Launches the app with [pin] enrolled and [protectedPackage] protected
/// before the host mounts (as in production, which arms the heartbeat),
/// with both bridges bound to the strict native contract.
Future<FocusAwareWakeDevice> launchFocusAwareDevice(
  WidgetTester tester, {
  required String protectedPackage,
  required String label,
  required String pin,
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final AppContainer container = AppContainer.inMemory();
  final StaticNativeChallengeContract native =
      StaticNativeChallengeContract.bind(
    overlay: container.overlay as StaticOverlayLockService,
    watcher: container.watcher as StaticWatcherService,
  );
  await container.auth.enrollPin(pin);
  await container.protectedApps.add(
    ProtectedApp(
      packageName: protectedPackage,
      label: label,
      addedAt: DateTime(2026, 10, 24),
    ),
  );
  await container.protectionBootstrap.synchronize();
  expect(native.isProtected(protectedPackage), isTrue);

  await tester.pumpWidget(SmartAppLockApp(container: container));
  await tester.pumpAndSettle();
  final FocusAwareWakeDevice device = FocusAwareWakeDevice._(
    tester,
    container,
    native,
    protectedPackage,
  );
  await device.syncLifecycle();
  return device;
}
