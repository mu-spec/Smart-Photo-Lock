import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/router.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/credentials/biometric_options.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_change_screen.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_setup_screen.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_change_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_setup_screen.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/security/security_screen.dart';

/// Phase 2K: the authentication settings surface — dynamic PIN/pattern
/// rows (set up vs change), the pattern-visibility toggle, plus the
/// randomized-keypad and biometric rows from earlier phases.

/// Routes the Security tab can push into. Deliberately excludes '/'
/// (MainShell) — a MaterialApp with `home:` may not also define '/'.
/// Every value is a proper WidgetBuilder closure — `(context) => Widget`.
final Map<String, WidgetBuilder> kSecurityTabRoutes = <String, WidgetBuilder>{
  RouteNames.pinSetup: (BuildContext context) => const PinSetupScreen(),
  RouteNames.pinUnlock: (BuildContext context) => const PinUnlockScreen(),
  RouteNames.pinChange: (BuildContext context) => const PinChangeScreen(),
  RouteNames.patternSetup:
      (BuildContext context) => const PatternSetupScreen(),
  RouteNames.patternUnlock:
      (BuildContext context) => const PatternUnlockScreen(),
  RouteNames.patternChange:
      (BuildContext context) => const PatternChangeScreen(),
};

void main() {
  /// Pumps the Security tab inside an [AppScope]. Pass an existing
  /// [container] to re-pump with the same state (e.g. after enrolling).
  Future<AppContainer> pumpWithScope(
    WidgetTester tester, {
    AppContainer? container,
  }) async {
    final AppContainer c = container ?? AppContainer.inMemory();
    await tester.pumpWidget(
      AppScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.dark,
          routes: kSecurityTabRoutes,
          home: const Scaffold(body: SecurityScreen()),
        ),
      ),
    );
    // Let the async settings load complete.
    await tester.pump();
    return c;
  }

  // -------------------------------------------------------------------
  // PIN row
  // -------------------------------------------------------------------
  testWidgets('PIN row reads Set up PIN when nothing is enrolled',
      (WidgetTester tester) async {
    await pumpWithScope(tester);
    expect(find.text(SecurityScreen.setPinTitle), findsOneWidget);
    expect(find.text(SecurityScreen.changePinTitle), findsNothing);
  });

  testWidgets('PIN row reads Change PIN when a PIN is enrolled',
      (WidgetTester tester) async {
    final AppContainer container = await pumpWithScope(tester);
    await container.auth.enrollPin('1234');
    await pumpWithScope(tester, container: container);
    expect(find.text(SecurityScreen.changePinTitle), findsOneWidget);
  });

  testWidgets('tapping Change PIN opens the change flow (verify first)',
      (WidgetTester tester) async {
    final AppContainer container = await pumpWithScope(tester);
    await container.auth.enrollPin('1234');
    await pumpWithScope(tester, container: container);

    await tester.tap(find.text(SecurityScreen.changePinTitle));
    await tester.pumpAndSettle();

    // The change flow pushes the current-PIN verification first.
    expect(find.text('Enter current PIN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------
  // Pattern row
  // -------------------------------------------------------------------
  testWidgets('pattern row opens the pattern setup route when not enrolled',
      (WidgetTester tester) async {
    await pumpWithScope(tester);

    expect(find.text(SecurityScreen.setPatternTitle), findsOneWidget);
    await tester.tap(find.text(SecurityScreen.setPatternTitle));
    await tester.pumpAndSettle();

    expect(find.text(PatternSetupScreen.enterTitle), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pattern row opens the change flow when a pattern is enrolled',
      (WidgetTester tester) async {
    final AppContainer container = await pumpWithScope(tester);
    await container.auth.enrollPattern(const <int>[1, 2, 3, 6]);
    await pumpWithScope(tester, container: container);

    expect(find.text(SecurityScreen.changePatternTitle), findsOneWidget);
    await tester.tap(find.text(SecurityScreen.changePatternTitle));
    await tester.pumpAndSettle();

    // Change flow: current-pattern verification first.
    expect(find.text('Enter current pattern'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------
  // Pattern visibility toggle (Phase 2K)
  // -------------------------------------------------------------------
  testWidgets('visible-pattern toggle defaults on and persists off',
      (WidgetTester tester) async {
    final AppContainer container = await pumpWithScope(tester);

    expect(find.text(SecurityScreen.patternVisibilityTitle), findsOneWidget);
    final Finder switches = find.byType(Switch);
    // Switches: [Visible pattern, Randomized keypad]
    expect(switches, findsNWidgets(2));
    expect(tester.widget<Switch>(switches.first).value, isTrue);

    await tester.tap(switches.first);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(switches.first).value, isFalse);

    final state = (await container.auth.status()).valueOrNull!;
    expect(state.patternVisibilityEnabled, isFalse);
    final settings =
        (await container.securitySettings.getSettings()).valueOrNull!;
    expect(settings.patternVisibilityEnabled, isFalse);
  });

  testWidgets('visible-pattern toggle renders inert without a container',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const Scaffold(body: SecurityScreen()),
      ),
    );
    await tester.pump();

    final Switch toggle = tester.widget<Switch>(find.byType(Switch).first);
    expect(toggle.onChanged, isNull);
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------
  // Randomized keypad (Phase 2G)
  // -------------------------------------------------------------------
  testWidgets('randomized keypad toggle persists through the manager',
      (WidgetTester tester) async {
    final AppContainer container = await pumpWithScope(tester);

    final Switch toggle = tester.widget<Switch>(find.byType(Switch).at(1));
    expect(toggle.value, isFalse);

    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Switch>(find.byType(Switch).at(1)).value,
      isTrue,
    );

    final state = (await container.auth.status()).valueOrNull!;
    expect(state.randomizedKeypadEnabled, isTrue);
  });

  // -------------------------------------------------------------------
  // Biometric row (Phase 2J)
  // -------------------------------------------------------------------
  testWidgets('biometric row renders not-set by default',
      (WidgetTester tester) async {
    await pumpWithScope(tester);
    expect(find.text('Biometric unlock'), findsOneWidget);
    expect(find.text('Enabled'), findsNothing);
  });

  testWidgets('biometric row requires a primary credential first',
      (WidgetTester tester) async {
    await pumpWithScope(tester);

    await tester.tap(find.text('Biometric unlock'));
    await tester.pumpAndSettle();
    expect(find.text('Set up a PIN or pattern first.'), findsOneWidget);
  });

  testWidgets('biometric row disables an enrolled biometric unlock',
      (WidgetTester tester) async {
    final AppContainer container = await pumpWithScope(tester);
    await container.auth.enrollPin('1234');
    await container.auth.updateBiometricOptions(BiometricOptions.defaults);
    await pumpWithScope(tester, container: container);

    expect(find.text('Enabled'), findsOneWidget);

    await tester.tap(find.text('Biometric unlock'));
    await tester.pumpAndSettle();

    expect(find.text('Biometric unlock disabled.'), findsOneWidget);
    expect(find.text('Enabled'), findsNothing);
    final state = (await container.auth.status()).valueOrNull!;
    expect(state.hasEnrolled(AuthType.biometric), isFalse);
  });

  testWidgets('biometric row reports unsupported hardware without a platform',
      (WidgetTester tester) async {
    final AppContainer container = await pumpWithScope(tester);
    await container.auth.enrollPin('1234');
    await pumpWithScope(tester, container: container);

    await tester.tap(find.text('Biometric unlock'));
    await tester.pumpAndSettle();
    expect(
      find.text('Biometric authentication is not available on this device.'),
      findsOneWidget,
    );
  });
}
