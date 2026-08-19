import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app.dart';

/// Phase 1B smoke test: the architecture dashboard must build and render.
void main() {
  testWidgets('home dashboard renders all eight architecture modules',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SmartAppLockApp());

    expect(find.text('Smart App Lock'), findsWidgets);
    expect(find.text('Phase 1B — Core Architecture'), findsOneWidget);
    expect(find.text('Scaffolded'), findsNWidgets(8));
    expect(find.text('lib/protection'), findsOneWidget);
    expect(find.text('com.smartapplock.app'), findsOneWidget);
  });
}
