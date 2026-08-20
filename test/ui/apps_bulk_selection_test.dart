import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/design_system/design_system.dart';
import 'package:smart_app_lock/ui/screens/apps/apps_screen.dart';

/// Phase 3G: sensible multi-select operations — select-all (filter-aware),
/// bulk Protect, bulk Unprotect, cancel.
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

  Future<void> enterSelection(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('apps_select_button')));
    await tester.pumpAndSettle();
  }

  Finder checkFor(String packageName) =>
      find.byKey(Key('app_check_$packageName'));

  testWidgets('Select enters selection mode with checkboxes and bulk bar',
      (WidgetTester tester) async {
    await pumpApps(tester);

    // Normal mode: switches, no checkboxes, no bulk bar.
    expect(find.byType(Switch), findsNWidgets(3));
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byKey(const Key('apps_bulk_protect')), findsNothing);

    await enterSelection(tester);

    // Selection mode: checkboxes replace switches; the bulk bar appears.
    expect(find.byType(Checkbox), findsNWidgets(3));
    expect(find.byType(Switch), findsNothing);
    expect(find.byKey(const Key('apps_bulk_protect')), findsOneWidget);
    expect(find.byKey(const Key('apps_bulk_unprotect')), findsOneWidget);
    expect(find.byKey(const Key('apps_select_all')), findsOneWidget);
    expect(find.text('0 selected'), findsOneWidget);
    expect(find.text(AppsScreen.cancelLabel), findsOneWidget);
  });

  testWidgets('row taps toggle selection and the count updates',
      (WidgetTester tester) async {
    await pumpApps(tester);
    await enterSelection(tester);

    await tester.tap(checkFor('com.whatsapp'));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tap(checkFor('com.gmail'));
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);

    // Toggling off decrements.
    await tester.tap(checkFor('com.whatsapp'));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
  });

  testWidgets('bulk Protect marks selected apps protected and persists',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApps(tester);
    await enterSelection(tester);

    await tester.tap(checkFor('com.whatsapp'));
    await tester.pump();
    await tester.tap(checkFor('com.gmail'));
    await tester.pump();

    await tester.tap(find.byKey(const Key('apps_bulk_protect')));
    await tester.pumpAndSettle();

    expect(find.text('2 apps protected ✓'), findsOneWidget); // snackbar
    expect((await container.protectedApps.count()).valueOrNull, 2);
    expect(
      (await container.protectedApps.isProtected('com.whatsapp')).valueOrNull,
      isTrue,
    );
    expect(
      (await container.protectedApps.isProtected('com.gmail')).valueOrNull,
      isTrue,
    );
    expect(
      (await container.protectedApps.isProtected('com.instagram')).valueOrNull,
      isFalse,
    );

    // Selection mode exits; switches are back and reflect the new state.
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(Switch), findsNWidgets(3));
    expect(find.text(AppsScreen.protectedLabel), findsNWidgets(2));
  });

  testWidgets('bulk Protect skips apps that are already protected',
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

    await enterSelection(tester);
    await tester.tap(checkFor('com.whatsapp'));
    await tester.pump();
    await tester.tap(checkFor('com.instagram'));
    await tester.pump();

    await tester.tap(find.byKey(const Key('apps_bulk_protect')));
    await tester.pumpAndSettle();

    // Only Instagram changed; WhatsApp stayed protected.
    expect(find.text('1 app protected ✓'), findsOneWidget);
    expect((await container.protectedApps.count()).valueOrNull, 2);
  });

  testWidgets('bulk Unprotect removes protection from selected apps',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApps(tester);
    for (final String pkg in <String>['com.whatsapp', 'com.instagram']) {
      await container.protectedApps.add(
        ProtectedApp(
          packageName: pkg,
          label: pkg,
          addedAt: DateTime(2026, 8, 20),
        ),
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpApps(tester, container: container);

    await enterSelection(tester);
    await tester.tap(checkFor('com.whatsapp'));
    await tester.pump();
    await tester.tap(checkFor('com.instagram'));
    await tester.pump();

    await tester.tap(find.byKey(const Key('apps_bulk_unprotect')));
    await tester.pumpAndSettle();

    expect(find.text('2 apps unprotected'), findsOneWidget);
    expect((await container.protectedApps.count()).valueOrNull, 0);
  });

  testWidgets('select all respects the active filter', (WidgetTester tester) async {
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

    // Protected filter: only WhatsApp is visible.
    await tester.tap(find.text('Protected').first);
    await tester.pumpAndSettle();
    await enterSelection(tester);

    await tester.tap(find.byKey(const Key('apps_select_all')));
    await tester.pumpAndSettle();

    expect(find.text('1 selected'), findsOneWidget);
    expect(
      tester.widget<Checkbox>(checkFor('com.whatsapp')).value,
      isTrue,
    );

    // Unprotect everything via bulk.
    await tester.tap(find.byKey(const Key('apps_bulk_unprotect')));
    await tester.pumpAndSettle();
    expect((await container.protectedApps.count()).valueOrNull, 0);
  });

  testWidgets('bulk actions are disabled when nothing is selected',
      (WidgetTester tester) async {
    await pumpApps(tester);
    await enterSelection(tester);

    final DsButton protect = tester.widget<DsButton>(
      find.byKey(const Key('apps_bulk_protect')),
    );
    final DsButton unprotect = tester.widget<DsButton>(
      find.byKey(const Key('apps_bulk_unprotect')),
    );
    expect(protect.onPressed, isNull);
    expect(unprotect.onPressed, isNull);

    await tester.tap(checkFor('com.whatsapp'));
    await tester.pump();
    expect(
      tester
          .widget<DsButton>(find.byKey(const Key('apps_bulk_protect')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('Cancel exits selection mode without changing anything',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApps(tester);
    await enterSelection(tester);

    await tester.tap(checkFor('com.whatsapp'));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tap(find.text(AppsScreen.cancelLabel));
    await tester.pumpAndSettle();

    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(Switch), findsNWidgets(3));
    expect((await container.protectedApps.count()).valueOrNull, 0);
  });
}
