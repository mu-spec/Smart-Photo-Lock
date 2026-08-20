import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/ui/screens/apps/apps_screen.dart';

/// Phase 3C: search by application name on the Apps tab.
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

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(
      find.byKey(const Key('apps_search_field')),
      query,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('search field is present with the hint', (WidgetTester tester) async {
    await pumpApps(tester);
    expect(find.byKey(const Key('apps_search_field')), findsOneWidget);
    expect(find.text(AppsScreen.searchHint), findsOneWidget);
    expect(find.text('3 apps'), findsOneWidget);
  });

  testWidgets('typing filters the list by name', (WidgetTester tester) async {
    await pumpApps(tester);

    await search(tester, 'insta');
    expect(find.text('Instagram'), findsOneWidget);
    expect(find.text('WhatsApp'), findsNothing);
    expect(find.text('Gmail'), findsNothing);
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('search is case-insensitive', (WidgetTester tester) async {
    await pumpApps(tester);

    await search(tester, 'WHATSAPP');
    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('Instagram'), findsNothing);
  });

  testWidgets('partial names match (substring)', (WidgetTester tester) async {
    await pumpApps(tester);

    await search(tester, 'mail');
    expect(find.text('Gmail'), findsOneWidget);
    expect(find.text('WhatsApp'), findsNothing);
  });

  testWidgets('no matches shows the empty-search state with clear action',
      (WidgetTester tester) async {
    await pumpApps(tester);

    await search(tester, 'zzz');
    expect(find.text(AppsScreen.noMatchTitle), findsOneWidget);
    expect(find.text(AppsScreen.noMatchMessage), findsOneWidget);
    expect(find.text('WhatsApp'), findsNothing);

    await tester.tap(find.text(AppsScreen.clearSearchLabel));
    await tester.pumpAndSettle();
    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('Instagram'), findsOneWidget);
    expect(find.text('Gmail'), findsOneWidget);
    expect(find.text('3 apps'), findsOneWidget);
  });

  testWidgets('the clear icon empties the field and restores the list',
      (WidgetTester tester) async {
    await pumpApps(tester);

    await search(tester, 'what');
    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('Gmail'), findsNothing);

    expect(find.byKey(const Key('apps_search_clear')), findsOneWidget);
    await tester.tap(find.byKey(const Key('apps_search_clear')));
    await tester.pumpAndSettle();

    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('Instagram'), findsOneWidget);
    expect(find.text('Gmail'), findsOneWidget);
    expect(find.byKey(const Key('apps_search_clear')), findsNothing);
  });

  testWidgets('protection pills still render in filtered results',
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

    await search(tester, 'what');
    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text(AppsScreen.protectedLabel), findsOneWidget);
    expect(find.text(AppsScreen.unlockedLabel), findsNothing);
  });
}
