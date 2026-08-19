import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/design_system/design_system.dart';

void main() {
  Widget wrap(Widget child) =>
      MaterialApp(theme: AppTheme.dark, home: Scaffold(body: child));

  group('SecurityStatusPill', () {
    testWidgets('shows the default label for every level', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(
          const Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SecurityStatusPill(level: SecurityLevel.secured),
              SecurityStatusPill(level: SecurityLevel.atRisk),
              SecurityStatusPill(level: SecurityLevel.vulnerable),
              SecurityStatusPill(level: SecurityLevel.notSet),
            ],
          ),
        ),
      );
      expect(find.text('Protected'), findsOneWidget);
      expect(find.text('Needs attention'), findsOneWidget);
      expect(find.text('At risk'), findsOneWidget);
      expect(find.text('Not set'), findsOneWidget);
    });

    testWidgets('custom label overrides the default', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(const SecurityStatusPill(level: SecurityLevel.notSet, label: '0 apps')),
      );
      expect(find.text('0 apps'), findsOneWidget);
      expect(find.text('Not set'), findsNothing);
    });
  });

  group('SecurityStatusItem', () {
    testWidgets('renders icon, title, subtitle and status', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(
          const SecurityStatusItem(
            icon: Icons.lock_outline,
            title: 'Unlock PIN',
            subtitle: 'Required to open protected apps',
            level: SecurityLevel.notSet,
          ),
        ),
      );
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.text('Unlock PIN'), findsOneWidget);
      expect(find.text('Required to open protected apps'), findsOneWidget);
      expect(find.text('Not set'), findsOneWidget);
    });
  });

  group('SecurityStatusBanner', () {
    testWidgets('renders content and fires its action', (WidgetTester tester) async {
      bool acted = false;
      await tester.pumpWidget(
        wrap(
          SecurityStatusBanner(
            level: SecurityLevel.atRisk,
            title: 'Set up your PIN',
            message: 'Your apps are not protected yet.',
            actionLabel: 'Set up now',
            onAction: () => acted = true,
          ),
        ),
      );
      expect(find.text('Set up your PIN'), findsOneWidget);
      expect(find.text('Your apps are not protected yet.'), findsOneWidget);
      await tester.tap(find.text('Set up now'));
      expect(acted, isTrue);
    });

    testWidgets('renders without an action', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(
          const SecurityStatusBanner(
            level: SecurityLevel.secured,
            title: 'All good',
            message: 'Everything is protected.',
          ),
        ),
      );
      expect(find.text('All good'), findsOneWidget);
      expect(find.byType(DsButton), findsNothing);
    });
  });
}
