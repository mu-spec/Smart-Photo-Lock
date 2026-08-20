import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_scope.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/ui/screens/apps/apps_screen.dart';

/// Phase 3H: the Apps tab stays responsive with large installed-app lists
/// (real devices commonly expose 100-500+ packages).
///
/// 1,000 synthetic apps are used to prove:
///  * lazy row construction (ListView.builder builds only visible rows),
///  * fast-scroll correctness (bottom rows render without exceptions),
///  * search/filter stay O(n)-on-action, not O(n)-per-frame.
void main() {
  List<AppEntry> bigCatalog() => List<AppEntry>.generate(
        1000,
        (int i) => AppEntry(
          packageName: 'com.example.app$i',
          label: 'Example App ${i.toString().padLeft(4, '0')}',
        ),
      );

  Future<void> pumpBig(WidgetTester tester) async {
    final AppContainer container =
        AppContainer.inMemory(apps: bigCatalog());
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
  }

  testWidgets('renders lazily: far fewer rows than the 1000-app catalog',
      (WidgetTester tester) async {
    await pumpBig(tester);

    expect(find.text('1000 apps'), findsOneWidget);
    // Only the viewport's rows (+ cache extent) exist at once.
    final int builtRows =
        tester.widgetList(find.byType(ListTile, skipOffstage: false)).length;
    expect(builtRows, lessThan(40));
    expect(builtRows, greaterThan(0));
  });

  testWidgets('scrolling to the bottom renders the last rows without errors',
      (WidgetTester tester) async {
    await pumpBig(tester);

    // Programmatic flings through the catalog (several viewports' worth).
    await tester.fling(find.byType(ListView), const Offset(0, -2000), 6000);
    await tester.pumpAndSettle();
    await tester.fling(find.byType(ListView), const Offset(0, -2000), 6000);
    await tester.pumpAndSettle();
    await tester.fling(find.byType(ListView), const Offset(0, -2000), 6000);
    await tester.pumpAndSettle();

    // The tail of the catalog becomes reachable and rows stay consistent:
    // one large drag reaches the bottom of the ~72,000px list (drag deltas
    // are not screen-clamped and the scroll clamps at the edge).
    await tester.drag(find.byType(ListView), const Offset(0, -80000));
    await tester.pumpAndSettle();

    expect(find.text('Example App 0999'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search across 1000 apps is instant and precise',
      (WidgetTester tester) async {
    await pumpBig(tester);

    await tester.enterText(
      find.byKey(const Key('apps_search_field')),
      'App 0999',
    );
    await tester.pumpAndSettle();

    expect(find.text('Example App 0999'), findsOneWidget);
    expect(find.text('1 / 1000'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('filter + search combination stays correct at scale',
      (WidgetTester tester) async {
    await pumpBig(tester);

    // Search for a range of apps, then switch to the Unprotected filter:
    // all of them are unprotected, so the count must match the query.
    await tester.enterText(
      find.byKey(const Key('apps_search_field')),
      'Example App 00',
    );
    await tester.pumpAndSettle();
    expect(find.text('100 / 1000'), findsOneWidget);

    await tester.tap(find.text('Unprotected'));
    await tester.pumpAndSettle();
    expect(find.text('100 / 1000'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection mode works on a large list',
      (WidgetTester tester) async {
    await pumpBig(tester);

    await tester.tap(find.byKey(const Key('apps_select_button')));
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);

    await tester.tap(find.byKey(const Key('apps_select_all')));
    await tester.pumpAndSettle();
    expect(find.text('1000 selected'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
