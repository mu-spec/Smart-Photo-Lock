import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/router.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/ui/screens/pattern/pattern_setup_screen.dart';
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
}
