import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/main.dart';

/// Phase 1A smoke test: the scaffold widget tree must build and render.
void main() {
  testWidgets('Phase 1A scaffold renders', (WidgetTester tester) async {
    await tester.pumpWidget(const SmartAppLockApp());

    expect(find.text('Smart App Lock'), findsWidgets);
    expect(find.text('Phase 1A complete'), findsOneWidget);
    expect(find.text('com.smartapplock.app'), findsOneWidget);
  });
}
