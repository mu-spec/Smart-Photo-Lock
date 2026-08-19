import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/design_system/design_system.dart';

void main() {
  Widget wrap(Widget child) =>
      MaterialApp(theme: AppTheme.dark, home: Scaffold(body: child));

  group('DsCard', () {
    testWidgets('renders title, subtitle and child', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(
          const DsCard(
            title: 'Protection status',
            subtitle: 'Summary of your locks',
            child: Text('content'),
          ),
        ),
      );
      expect(find.text('Protection status'), findsOneWidget);
      expect(find.text('Summary of your locks'), findsOneWidget);
      expect(find.text('content'), findsOneWidget);
    });

    testWidgets('onTap fires', (WidgetTester tester) async {
      bool tapped = false;
      await tester.pumpWidget(
        wrap(DsCard(onTap: () => tapped = true, child: const Text('tappable'))),
      );
      await tester.tap(find.text('tappable'));
      expect(tapped, isTrue);
    });

    testWidgets('trailing widget renders in the header', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(
          DsCard(
            title: 'Profile',
            trailing: const DsStatusPill(label: 'Active', tone: DsTone.success),
          ),
        ),
      );
      expect(find.text('Profile'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);
    });
  });

  group('DsSectionTitle', () {
    testWidgets('renders title and optional action', (WidgetTester tester) async {
      bool acted = false;
      await tester.pumpWidget(
        wrap(
          DsSectionTitle(
            'Protection controls',
            actionLabel: 'Edit',
            onAction: () => acted = true,
          ),
        ),
      );
      expect(find.text('Protection controls'), findsOneWidget);
      await tester.tap(find.text('Edit'));
      expect(acted, isTrue);
    });
  });
}
