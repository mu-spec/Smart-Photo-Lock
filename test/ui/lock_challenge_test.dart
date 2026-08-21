import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_overlay_lock_service.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';

/// Phase 5D: the basic lock trigger end-to-end — when a protected
/// application becomes active, Smart App Lock presents the unlock
/// challenge through the production app wiring (monitor -> matcher ->
/// access controller -> challenge host -> router -> unlock screen).
void main() {
  Future<AppContainer> pumpApp(
    WidgetTester tester, {
    AppContainer? container,
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final AppContainer c = container ?? AppContainer.inMemory();
    await tester.pumpWidget(SmartAppLockApp(container: c));
    await tester.pumpAndSettle();
    return c;
  }

  /// The user opens another app: the detection-only accessibility
  /// service reports a window-state change (production fallback path).
  Future<void> openApp(
    WidgetTester tester,
    AppContainer container,
    String package,
  ) async {
    (container.accessibility as StaticAccessibilityLockService)
        .emitForegroundPackage(package);
    await tester.pumpAndSettle();
  }

  Future<void> protect(AppContainer container, String package) =>
      container.protectedApps.add(
        ProtectedApp(
          packageName: package,
          label: package,
          addedAt: DateTime(2026, 8, 21),
        ),
      );

  testWidgets(
      'a protected app becoming active presents the PIN challenge; a '
      'correct PIN unlocks the session', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');

    // The challenge is up.
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(find.text(PinUnlockScreen.wrongPinPrefix), findsNothing);
    final StaticOverlayLockService overlay =
        container.overlay as StaticOverlayLockService;
    expect(overlay.showLockChallengeCalls, 1);
    expect(overlay.lastLockPackage, 'com.whatsapp');

    // Correct PIN -> the screen pops and the session is granted.
    for (final String digit in <String>['1', '2', '3', '4']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }
    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(overlay.hideLockChallengeCalls, 1);

    // The open unlock window suppresses an immediate re-challenge.
    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsNothing);
  });

  testWidgets('an unprotected app produces no challenge',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');

    await openApp(tester, container, 'com.example.chat');

    expect(find.byType(PinUnlockScreen), findsNothing);
    final StaticOverlayLockService overlay =
        container.overlay as StaticOverlayLockService;
    expect(overlay.showLockChallengeCalls, 0);
  });

  testWidgets('no enrolled credential: no challenge (fail-safe)',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');

    expect(find.byType(PinUnlockScreen), findsNothing);
    expect(find.byType(PatternUnlockScreen), findsNothing);
  });

  testWidgets('a pattern-only user is challenged with the pattern screen',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPattern(const <int>[1, 2, 3, 6]);
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');

    expect(find.byType(PatternUnlockScreen), findsOneWidget);
    expect(find.byType(PinUnlockScreen), findsNothing);
  });

  testWidgets('a wrong PIN keeps the challenge up', (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');

    await openApp(tester, container, 'com.whatsapp');
    expect(find.byType(PinUnlockScreen), findsOneWidget);

    for (final String digit in <String>['9', '9', '9', '9']) {
      await tester.tap(find.byKey(Key('pin_key_$digit')));
      await tester.pumpAndSettle();
    }

    // Still locked: the screen stays, the error is visible.
    expect(find.byType(PinUnlockScreen), findsOneWidget);
    expect(find.textContaining(PinUnlockScreen.wrongPinPrefix),
        findsOneWidget);
  });

  testWidgets('a failed bring-to-front presents no challenge',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApp(tester);
    await container.auth.enrollPin('1234');
    await protect(container, 'com.whatsapp');
    (container.overlay as StaticOverlayLockService).showLockChallengeSucceeds =
        false;

    await openApp(tester, container, 'com.whatsapp');

    expect(find.byType(PinUnlockScreen), findsNothing);
  });
}
