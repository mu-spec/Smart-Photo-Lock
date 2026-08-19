import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/router.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/credentials/biometric_options.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_setup_screen.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_unlock_screen.dart';
import 'package:smart_app_lock/ui/screens/security/security_screen.dart';

/// Phase 2G: the Security tab's randomized-keypad toggle reflects and
/// persists the setting through the credential manager.
void main() {
  Future<AppContainer> pumpWithScope(WidgetTester tester) async {
    final AppContainer container = AppContainer.inMemory();
    await tester.pumpWidget(
      AppScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(body: SecurityScreen()),
        ),
      ),
    );
    // Let the async settings load complete.
    await tester.pump();
    return container;
  }

  testWidgets('toggle renders off by default (accessible default)',
      (WidgetTester tester) async {
    await pumpWithScope(tester);

    expect(find.text(SecurityScreen.randomizedTitle), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('toggling persists the setting through the manager',
      (WidgetTester tester) async {
    final AppContainer container = await pumpWithScope(tester);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    final state = (await container.auth.status()).valueOrNull!;
    expect(state.randomizedKeypadEnabled, isTrue);
    final settings =
        (await container.securitySettings.getSettings()).valueOrNull!;
    expect(settings.randomizedKeypadEnabled, isTrue);

    // Toggle back off.
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    final off = (await container.auth.status()).valueOrNull!;
    expect(off.randomizedKeypadEnabled, isFalse);
  });

  testWidgets('toggle is disabled without a container in scope',
      (WidgetTester tester) async {
    // Pure widget test (no AppScope): the switch must render inert rather
    // than crash.
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const Scaffold(body: SecurityScreen()),
      ),
    );
    await tester.pump();

    final Switch toggle = tester.widget<Switch>(find.byType(Switch));
    expect(toggle.onChanged, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pattern row opens the pattern setup route when not enrolled',
      (WidgetTester tester) async {
    final AppContainer container = AppContainer.inMemory();
    await tester.pumpWidget(
      AppScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          routes: <String, WidgetBuilder>{
            RouteNames.patternSetup: (_) => const PatternSetupScreen(),
          },
          home: const Scaffold(body: SecurityScreen()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Pattern unlock'), findsOneWidget);
    await tester.tap(find.text('Pattern unlock'));
    await tester.pumpAndSettle();

    // No pattern enrolled -> the setup flow opens.
    expect(find.text(PatternSetupScreen.enterTitle), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pattern row opens the unlock screen when a pattern is enrolled',
      (WidgetTester tester) async {
    final AppContainer container = AppContainer.inMemory();
    await container.auth.enrollPattern(const <int>[1, 2, 3, 6]);
    await tester.pumpWidget(
      AppScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          routes: <String, WidgetBuilder>{
            RouteNames.patternSetup: (_) => const PatternSetupScreen(),
            RouteNames.patternUnlock: (_) => const PatternUnlockScreen(),
          },
          home: const Scaffold(body: SecurityScreen()),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Pattern unlock'));
    await tester.pumpAndSettle();

    // Enrolled -> the unlock challenge opens instead of setup.
    expect(find.text(PatternUnlockScreen.readyHint), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------
  // Phase 2J — biometric row
  // -------------------------------------------------------------------
  testWidgets('biometric row renders not-set by default',
      (WidgetTester tester) async {
    final AppContainer container = AppContainer.inMemory();
    await tester.pumpWidget(
      AppScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(body: SecurityScreen()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Biometric unlock'), findsOneWidget);
    expect(find.text('Enabled'), findsNothing);
  });

  testWidgets('biometric row requires a primary credential first',
      (WidgetTester tester) async {
    final AppContainer container = AppContainer.inMemory();
    await tester.pumpWidget(
      AppScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(body: SecurityScreen()),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Biometric unlock'));
    await tester.pumpAndSettle();
    expect(find.text('Set up a PIN or pattern first.'), findsOneWidget);
  });

  testWidgets('biometric row disables an enrolled biometric unlock',
      (WidgetTester tester) async {
    final AppContainer container = AppContainer.inMemory();
    await container.auth.enrollPin('1234');
    await container.auth.updateBiometricOptions(BiometricOptions.defaults);
    await tester.pumpWidget(
      AppScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(body: SecurityScreen()),
        ),
      ),
    );
    await tester.pump();

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
    final AppContainer container = AppContainer.inMemory();
    await container.auth.enrollPin('1234');
    await tester.pumpWidget(
      AppScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(body: SecurityScreen()),
        ),
      ),
    );
    await tester.pump();

    // flutter test has no platform plugin -> the real service fails closed.
    await tester.tap(find.text('Biometric unlock'));
    await tester.pumpAndSettle();
    expect(
      find.text('Biometric authentication is not available on this device.'),
      findsOneWidget,
    );
  });
}
