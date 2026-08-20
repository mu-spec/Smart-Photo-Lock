import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/ui/screens/apps/apps_screen.dart';

/// Phase 3D: All / Protected / Unprotected group filters.
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

  /// The three filter segments, scoped to the segmented control (the list
  /// pills also use words like 'Locked'/'Unlocked' — segments stay unique).
  Finder segment(String label) => find.descendant(
        of: find.byType(DsSegmented<AppsFilter>),
        matching: find.text(label),
      );

  testWidgets('renders All / Protected / Unprotected segments',
      (WidgetTester tester) async {
    await pumpApps(tester);

    expect(segment('All'), findsOneWidget);
    expect(segment('Protected'), findsOneWidget);
    expect(segment('Unprotected'), findsOneWidget);
    expect(find.text('3 apps'), findsOneWidget);
  });

  testWidgets('All is the default and shows every app',
      (WidgetTester tester) async {
    await pumpApps(tester);

    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('Instagram'), findsOneWidget);
    expect(find.text('Gmail'), findsOneWidget);
    expect(find.text('3 apps'), findsOneWidget);
  });

  testWidgets('Protected filter shows only protected apps',
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

    await tester.tap(segment('Protected'));
    await tester.pumpAndSettle();

    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('Instagram'), findsNothing);
    expect(find.text('Gmail'), findsNothing);
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('Unprotected filter shows only unprotected apps',
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

    await tester.tap(segment('Unprotected'));
    await tester.pumpAndSettle();

    expect(find.text('WhatsApp'), findsNothing);
    expect(find.text('Instagram'), findsOneWidget);
    expect(find.text('Gmail'), findsOneWidget);
    expect(find.text('2 / 3'), findsOneWidget);
  });

  testWidgets('filter combines with the name search', (WidgetTester tester) async {
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

    await tester.enterText(
      find.byKey(const Key('apps_search_field')),
      'what',
    );
    await tester.pumpAndSettle();
    await tester.tap(segment('Protected'));
    await tester.pumpAndSettle();

    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('1 / 3'), findsOneWidget);

    // Same query under Unprotected: no match -> filter-empty state.
    await tester.tap(segment('Unprotected'));
    await tester.pumpAndSettle();
    expect(find.text(AppsScreen.allProtectedTitle), findsNothing);
    expect(find.text('WhatsApp'), findsNothing);
  });

  testWidgets('no protected apps shows the filter-empty state with Show all',
      (WidgetTester tester) async {
    await pumpApps(tester); // nothing protected yet

    await tester.tap(segment('Protected'));
    await tester.pumpAndSettle();

    expect(find.text(AppsScreen.noProtectedTitle), findsOneWidget);
    expect(find.text(AppsScreen.noProtectedMessage), findsOneWidget);

    await tester.tap(find.text(AppsScreen.showAllLabel));
    await tester.pumpAndSettle();
    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('Instagram'), findsOneWidget);
    expect(find.text('Gmail'), findsOneWidget);
  });

  testWidgets('everything protected shows the all-protected state',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApps(tester);
    for (final AppEntry app in seed) {
      await container.protectedApps.add(
        ProtectedApp(
          packageName: app.packageName,
          label: app.label,
          addedAt: DateTime(2026, 8, 20),
        ),
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpApps(tester, container: container);

    await tester.tap(segment('Unprotected'));
    await tester.pumpAndSettle();

    expect(find.text(AppsScreen.allProtectedTitle), findsOneWidget);
    expect(find.text(AppsScreen.allProtectedMessage), findsOneWidget);

    await tester.tap(find.text(AppsScreen.showAllLabel));
    await tester.pumpAndSettle();
    expect(find.text('3 apps'), findsOneWidget);
    expect(find.text('WhatsApp'), findsOneWidget);
  });
}
