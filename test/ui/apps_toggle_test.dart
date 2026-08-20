import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/ui/screens/apps/apps_screen.dart';

/// Phase 3E: individual apps can be marked Protected / Unprotected via
/// the row switch, persisted through the protected-apps repository.
/// (No actual locking yet.)
void main() {
  const List<AppEntry> seed = <AppEntry>[
    AppEntry(packageName: 'com.whatsapp', label: 'WhatsApp'),
    AppEntry(packageName: 'com.instagram', label: 'Instagram'),
    AppEntry(packageName: 'com.gmail', label: 'Gmail'),
  ];

  Future<AppContainer> pumpApps(
    WidgetTester tester, {
    AppContainer? container,
  }) async {
    final AppContainer c = container ?? AppContainer.inMemory(apps: seed);
    await tester.pumpWidget(
      AppScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(body: AppsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  Finder switchFor(String packageName) =>
      find.byKey(Key('app_toggle_$packageName'));

  testWidgets('every row renders a switch, all off by default',
      (WidgetTester tester) async {
    await pumpApps(tester);

    expect(find.byType(Switch), findsNWidgets(3));
    expect(tester.widget<Switch>(switchFor('com.whatsapp')).value, isFalse);
    expect(tester.widget<Switch>(switchFor('com.instagram')).value, isFalse);
    expect(tester.widget<Switch>(switchFor('com.gmail')).value, isFalse);
    // All rows show the unlocked status text.
    expect(find.text(AppsScreen.unlockedLabel), findsNWidgets(3));
  });

  testWidgets('toggling a switch protects the app and persists it',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApps(tester);

    await tester.tap(switchFor('com.whatsapp'));
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(switchFor('com.whatsapp')).value, isTrue);
    expect(find.text('WhatsApp protected ✓'), findsOneWidget); // snackbar
    expect(find.text(AppsScreen.protectedLabel), findsOneWidget);
    expect(find.text(AppsScreen.unlockedLabel), findsNWidgets(2));

    // Persisted through the repository.
    expect((await container.protectedApps.count()).valueOrNull, 1);
    expect(
      (await container.protectedApps.isProtected('com.whatsapp')).valueOrNull,
      isTrue,
    );
  });

  testWidgets('toggling a protected app off unprotects it',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApps(tester);
    await container.protectedApps.add(
      ProtectedApp(
        packageName: 'com.whatsapp',
        label: 'WhatsApp',
        addedAt: DateTime(2026, 8, 20),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpApps(tester, container: container);

    expect(tester.widget<Switch>(switchFor('com.whatsapp')).value, isTrue);

    await tester.tap(switchFor('com.whatsapp'));
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(switchFor('com.whatsapp')).value, isFalse);
    expect(find.text('WhatsApp unprotected'), findsOneWidget); // snackbar
    expect((await container.protectedApps.count()).valueOrNull, 0);
  });

  testWidgets('toggle state survives a screen rebuild', (WidgetTester tester) async {
    final AppContainer container = await pumpApps(tester);

    await tester.tap(switchFor('com.instagram'));
    await tester.pumpAndSettle();
    expect((await container.protectedApps.count()).valueOrNull, 1);

    // Rebuild the same container: the switch stays on.
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpApps(tester, container: container);
    expect(tester.widget<Switch>(switchFor('com.instagram')).value, isTrue);
    expect(find.text(AppsScreen.protectedLabel), findsOneWidget);
  });

  testWidgets('toggling off inside the Protected filter removes the row',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApps(tester);
    await container.protectedApps.add(
      ProtectedApp(
        packageName: 'com.whatsapp',
        label: 'WhatsApp',
        addedAt: DateTime(2026, 8, 20),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpApps(tester, container: container);

    // Switch to the Protected filter: only WhatsApp is visible.
    await tester.tap(find.text('Protected').first);
    await tester.pumpAndSettle();
    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('Instagram'), findsNothing);

    // Toggle it off -> the row leaves the filtered list; the filter-empty
    // state appears because nothing is protected anymore.
    await tester.tap(switchFor('com.whatsapp'));
    await tester.pumpAndSettle();
    expect(find.text('WhatsApp'), findsNothing);
    expect(find.text(AppsScreen.noProtectedTitle), findsOneWidget);
    expect((await container.protectedApps.count()).valueOrNull, 0);
  });

  testWidgets('protected status counts flow into the filtered pill',
      (WidgetTester tester) async {
    await pumpApps(tester);

    await tester.tap(switchFor('com.whatsapp'));
    await tester.pumpAndSettle();
    await tester.tap(switchFor('com.gmail'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Protected').first);
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('Gmail'), findsOneWidget);
    expect(find.text('Instagram'), findsNothing);
  });
}
