import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/ui/screens/apps/apps_screen.dart';

/// Phase 3B: the Apps tab lists installed apps with icon, name and
/// protection status.
void main() {
  // A minimal valid 1x1 PNG (transparent pixel).
  final Uint8List tinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
    'AAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  const List<AppEntry> seed = <AppEntry>[
    AppEntry(packageName: 'com.whatsapp', label: 'WhatsApp'),
    AppEntry(packageName: 'com.instagram', label: 'Instagram'),
    AppEntry(
      packageName: 'com.android.settings',
      label: 'Settings',
      isSystemApp: true,
    ),
  ];

  Future<AppContainer> pumpApps(
    WidgetTester tester, {
    List<AppEntry> apps = seed,
    Map<String, Uint8List> appIcons = const <String, Uint8List>{},
    AppContainer? container,
  }) async {
    final AppContainer c =
        container ?? AppContainer.inMemory(apps: apps, appIcons: appIcons);
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

  testWidgets('lists user apps with names, icons and protection status',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApps(tester);

    // Protect WhatsApp via the container, then rebuild the SAME container
    // so the screen re-reads the protection state.
    await container.protectedApps.add(
      ProtectedApp(
        packageName: 'com.whatsapp',
        label: 'WhatsApp',
        addedAt: DateTime(2026, 8, 20),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpApps(tester, container: container);

    expect(find.text(AppsScreen.title), findsOneWidget);
    expect(find.text(AppsScreen.description), findsOneWidget);
    expect(find.text('2 apps'), findsOneWidget);

    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('Instagram'), findsOneWidget);
    expect(find.text('Settings'), findsNothing); // system app filtered

    expect(find.text(AppsScreen.protectedLabel), findsOneWidget);
    expect(find.text(AppsScreen.unlockedLabel), findsOneWidget);

    // Fallback icons render for both rows (no PNGs seeded).
    expect(find.byIcon(Icons.android), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders real icon bytes when the platform provides them',
      (WidgetTester tester) async {
    await pumpApps(
      tester,
      appIcons: <String, Uint8List>{'com.whatsapp': tinyPng},
    );

    expect(find.byType(Image), findsOneWidget); // WhatsApp icon
    expect(find.byIcon(Icons.android), findsOneWidget); // Instagram fallback
  });

  testWidgets('empty catalog shows the empty state', (WidgetTester tester) async {
    await pumpApps(tester, apps: const <AppEntry>[]);

    expect(find.text(AppsScreen.emptyTitle), findsOneWidget);
    expect(find.text(AppsScreen.emptyMessage), findsOneWidget);
    expect(find.text(AppsScreen.retryLabel), findsOneWidget);
  });

  testWidgets('missing container shows the error state with Retry',
      (WidgetTester tester) async {
    // No AppScope in the tree -> the screen reports the error state and
    // the retry button does not crash.
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const Scaffold(body: AppsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(AppsScreen.errorTitle), findsOneWidget);
    expect(find.text(AppsScreen.unavailableMessage), findsOneWidget);
    await tester.tap(find.text(AppsScreen.retryLabel));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('protection status reflects the protected-apps repository',
      (WidgetTester tester) async {
    final AppContainer container = await pumpApps(tester);

    // Nothing protected yet: two "Not locked" pills.
    expect(find.text(AppsScreen.unlockedLabel), findsNWidgets(2));
    expect(find.text(AppsScreen.protectedLabel), findsNothing);

    // Protect Instagram through the repository, rebuild the SAME
    // container, and the status flips to Protected.
    await container.protectedApps.add(
      ProtectedApp(
        packageName: 'com.instagram',
        label: 'Instagram',
        addedAt: DateTime(2026, 8, 20),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpApps(tester, container: container);
    expect(find.text(AppsScreen.protectedLabel), findsOneWidget);
    expect(find.text(AppsScreen.unlockedLabel), findsOneWidget);
  });
}
