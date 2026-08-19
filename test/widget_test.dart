import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/ui/screens/apps/apps_screen.dart';
import 'package:smart_app_lock/ui/screens/home/home_screen.dart';
import 'package:smart_app_lock/ui/screens/security/security_screen.dart';
import 'package:smart_app_lock/ui/screens/settings/settings_screen.dart';
import 'package:smart_app_lock/ui/screens/smart/smart_screen.dart';

/// Phase 1C navigation tests: the five-tab shell must switch between
/// Home / Apps / Smart / Security / Settings.
void main() {
  Future<void> openTab(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('home tab is shown first, other tabs are offstage',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SmartAppLockApp());

    expect(find.text(HomeScreen.phaseLabel), findsOneWidget);
    expect(find.text(AppsScreen.description), findsNothing);
    expect(find.text(SettingsScreen.description), findsNothing);
  });

  testWidgets('bottom navigation switches between all five tabs',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SmartAppLockApp());

    await openTab(tester, 'nav_apps');
    expect(find.text(AppsScreen.description), findsOneWidget);

    await openTab(tester, 'nav_smart');
    expect(find.text(SmartScreen.description), findsOneWidget);

    await openTab(tester, 'nav_security');
    expect(find.text(SecurityScreen.description), findsOneWidget);

    await openTab(tester, 'nav_settings');
    expect(find.text(SettingsScreen.description), findsOneWidget);

    await openTab(tester, 'nav_home');
    expect(find.text(HomeScreen.phaseLabel), findsOneWidget);
    expect(find.text(SettingsScreen.description), findsNothing);
  });

  testWidgets('quick access tiles jump to their tab',
      (WidgetTester tester) async {
    // Larger logical surface so all home tiles are visible & tappable.
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const SmartAppLockApp());

    await tester.tap(find.byKey(const Key('quick_access_security')));
    await tester.pumpAndSettle();
    expect(find.text(SecurityScreen.description), findsOneWidget);

    await openTab(tester, 'nav_home');

    await tester.tap(find.byKey(const Key('quick_access_settings')));
    await tester.pumpAndSettle();
    expect(find.text(SettingsScreen.description), findsOneWidget);
  });
}
