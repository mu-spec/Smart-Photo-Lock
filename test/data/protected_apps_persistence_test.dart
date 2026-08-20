import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/impl/protected_apps_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/protected_apps_repository.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/ui/screens/apps/apps_screen.dart';

/// Phase 3F: protection selections survive app restart, process
/// recreation and device restart.
///
/// In production the durable layer is the SQLite file inside the app's
/// private databases directory (`getDatabasesPath()`), which the OS keeps
/// across all three scenarios. These tests hold the same durable store
/// (the stand-in for that file) while recreating every layer above it —
/// exactly what a restart does to the real app.
void main() {
  // -------------------------------------------------------------------
  // Repository-level: process recreation over the same durable store
  // -------------------------------------------------------------------
  group('repository persistence across recreation', () {
    test('selections written by one repository instance are read by another',
        () async {
      final InMemoryLocalDatabase store = InMemoryLocalDatabase();
      final ProtectedAppsRepository processA =
          ProtectedAppsRepositoryImpl(store);

      await processA.add(
        ProtectedApp(
          packageName: 'com.whatsapp',
          label: 'WhatsApp',
          addedAt: DateTime(2026, 8, 20, 10, 0),
        ),
      );
      await processA.add(
        ProtectedApp(
          packageName: 'com.instagram',
          label: 'Instagram',
          addedAt: DateTime(2026, 8, 20, 10, 5),
        ),
      );

      // "Process recreation": a brand-new repository over the SAME store.
      final ProtectedAppsRepository processB =
          ProtectedAppsRepositoryImpl(store);
      final List<ProtectedApp> restored =
          (await processB.getProtectedApps()).valueOrNull!;

      expect(restored, hasLength(2));
      expect(
        restored.map((ProtectedApp a) => a.packageName).toSet(),
        <String>{'com.whatsapp', 'com.instagram'},
      );
    });

    test('removals by one instance are visible to the next', () async {
      final InMemoryLocalDatabase store = InMemoryLocalDatabase();
      final ProtectedAppsRepository processA =
          ProtectedAppsRepositoryImpl(store);
      await processA.add(
        ProtectedApp(
          packageName: 'com.whatsapp',
          label: 'WhatsApp',
          addedAt: DateTime(2026, 8, 20),
        ),
      );

      await processA.remove('com.whatsapp');

      final ProtectedAppsRepository processB =
          ProtectedAppsRepositoryImpl(store);
      expect((await processB.count()).valueOrNull, 0);
    });

    test('ordering (sortOrder, then label) survives recreation', () async {
      final InMemoryLocalDatabase store = InMemoryLocalDatabase();
      final ProtectedAppsRepository processA =
          ProtectedAppsRepositoryImpl(store);
      await processA.add(
        ProtectedApp(
          packageName: 'com.gmail',
          label: 'Gmail',
          addedAt: DateTime(2026, 8, 20),
          sortOrder: 2,
        ),
      );
      await processA.add(
        ProtectedApp(
          packageName: 'com.whatsapp',
          label: 'WhatsApp',
          addedAt: DateTime(2026, 8, 20),
        ),
      );
      await processA.add(
        ProtectedApp(
          packageName: 'com.instagram',
          label: 'Instagram',
          addedAt: DateTime(2026, 8, 20),
          sortOrder: 1,
        ),
      );

      final ProtectedAppsRepository processB =
          ProtectedAppsRepositoryImpl(store);
      final List<String> order = (await processB.getProtectedApps())
          .valueOrNull!
          .map((ProtectedApp a) => a.packageName)
          .toList();

      expect(order, <String>['com.whatsapp', 'com.instagram', 'com.gmail']);
    });

    test('label updates (upsert) by one instance survive for the next',
        () async {
      final InMemoryLocalDatabase store = InMemoryLocalDatabase();
      final ProtectedAppsRepository processA =
          ProtectedAppsRepositoryImpl(store);
      await processA.add(
        ProtectedApp(
          packageName: 'com.whatsapp',
          label: 'WhatsApp',
          addedAt: DateTime(2026, 8, 20),
        ),
      );
      await processA.add(
        ProtectedApp(
          packageName: 'com.whatsapp',
          label: 'WhatsApp Messenger',
          addedAt: DateTime(2026, 8, 20),
        ),
      );

      final ProtectedAppsRepository processB =
          ProtectedAppsRepositoryImpl(store);
      expect((await processB.count()).valueOrNull, 1);
      expect(
        (await processB.getProtectedApps()).valueOrNull!.single.label,
        'WhatsApp Messenger',
      );
    });
  });

  // -------------------------------------------------------------------
  // Screen-level: resume re-syncs from the persisted store (Phase 3F)
  // -------------------------------------------------------------------
  group('AppsScreen resume refresh', () {
    testWidgets('protection changes in the store appear on resume',
        (WidgetTester tester) async {
      final AppContainer container = AppContainer.inMemory(
        apps: const <AppEntry>[
          AppEntry(packageName: 'com.whatsapp', label: 'WhatsApp'),
        ],
      );
      await tester.pumpWidget(
        AppScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark,
            home: const Scaffold(body: AppsScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Switch>(find.byKey(const Key('app_toggle_com.whatsapp')))
            .value,
        isFalse,
      );

      // Simulate another layer/process changing the persisted store while
      // the screen was in the background.
      await container.protectedApps.add(
        ProtectedApp(
          packageName: 'com.whatsapp',
          label: 'WhatsApp',
          addedAt: DateTime(2026, 8, 20),
        ),
      );

      // Background then resume the app: the screen re-reads the store.
      // The legal lifecycle chain must pass through `inactive` (a direct
      // paused -> resumed transition is rejected by the framework).
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Switch>(find.byKey(const Key('app_toggle_com.whatsapp')))
            .value,
        isTrue,
      );
      expect(find.text(AppsScreen.protectedLabel), findsOneWidget);
    });

    testWidgets('resume without store changes keeps the current state',
        (WidgetTester tester) async {
      final AppContainer container = AppContainer.inMemory(
        apps: const <AppEntry>[
          AppEntry(packageName: 'com.whatsapp', label: 'WhatsApp'),
        ],
      );
      await tester.pumpWidget(
        AppScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark,
            home: const Scaffold(body: AppsScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Legal lifecycle chain: paused -> inactive -> resumed.
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Switch>(find.byKey(const Key('app_toggle_com.whatsapp')))
            .value,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
