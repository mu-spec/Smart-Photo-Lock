import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/protection/foreground_app_monitor.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';

/// Phase 5A: foreground detection merges the usage-stats primary path
/// (polled) with the accessibility fallback (events), emits ONLY real
/// transitions (deduplicated across sources) and stays fail-closed —
/// failures and unknown states are never fabricated into transitions.
void main() {
  late StaticInstalledAppsService installed;
  late StaticAccessibilityLockService accessibility;
  late ForegroundAppMonitor monitor;
  late List<ForegroundAppChange> changes;

  setUp(() {
    installed = StaticInstalledAppsService(const <AppEntry>[]);
    accessibility = StaticAccessibilityLockService(enabled: true);
    monitor = ForegroundAppMonitor(
      installedApps: installed,
      accessibility: accessibility,
      now: () => DateTime(2026, 8, 21, 9, 0),
    );
    changes = <ForegroundAppChange>[];
    monitor.changes.listen(changes.add);
  });

  tearDown(() async {
    await monitor.dispose();
  });

  group('usage-stats primary path', () {
    test('a probe reports the foreground package', () async {
      installed.foregroundPackage = 'com.example.chat';
      await monitor.probe();

      expect(changes, hasLength(1));
      expect(changes.single.packageName, 'com.example.chat');
      expect(changes.single.source, ForegroundDetectionSource.usageStats);
      expect(monitor.currentPackage, 'com.example.chat');
    });

    test('the same package is never reported twice (dedupe)', () async {
      installed.foregroundPackage = 'com.example.chat';
      await monitor.probe();
      await monitor.probe();
      await monitor.probe();

      expect(changes, hasLength(1));
    });

    test('a switch between packages emits exactly one new change',
        () async {
      installed.foregroundPackage = 'com.example.chat';
      await monitor.probe();
      installed.foregroundPackage = 'com.example.maps';
      await monitor.probe();
      installed.foregroundPackage = 'com.example.chat';
      await monitor.probe();

      expect(changes, hasLength(3));
      expect(changes.map((ForegroundAppChange c) => c.packageName), <String>[
        'com.example.chat',
        'com.example.maps',
        'com.example.chat',
      ]);
    });

    test('a null probe (usage access missing) is ignored — fail-closed',
        () async {
      installed.foregroundPackage = null;
      await monitor.probe();

      expect(changes, isEmpty);
      expect(monitor.currentPackage, isNull);
    });
  });

  group('accessibility fallback path', () {
    test('window-state events report transitions and dedupe', () async {
      accessibility.emitForegroundPackage('com.example.chat');
      await Future<void>.delayed(Duration.zero);
      accessibility.emitForegroundPackage('com.example.chat');
      await Future<void>.delayed(Duration.zero);

      expect(changes, hasLength(1));
      expect(changes.single.source, ForegroundDetectionSource.accessibility);

      accessibility.emitForegroundPackage('com.example.maps');
      await Future<void>.delayed(Duration.zero);

      expect(changes, hasLength(2));
      expect(changes.last.packageName, 'com.example.maps');
      expect(changes.last.source, ForegroundDetectionSource.accessibility);
    });
  });

  group('merged sources', () {
    test('both paths share one deduplicated transition chain', () async {
      installed.foregroundPackage = 'com.example.chat';
      await monitor.probe(); // usage: chat
      accessibility.emitForegroundPackage('com.example.maps');
      await Future<void>.delayed(Duration.zero); // accessibility: maps
      installed.foregroundPackage = 'com.example.chat';
      await monitor.probe(); // usage: chat again (real switch back)

      expect(changes, hasLength(3));
      expect(changes.map((ForegroundAppChange c) => c.source),
          <ForegroundDetectionSource>[
        ForegroundDetectionSource.usageStats,
        ForegroundDetectionSource.accessibility,
        ForegroundDetectionSource.usageStats,
      ]);
    });

    test('the same package reported by the OTHER source is not a new '
        'transition', () async {
      installed.foregroundPackage = 'com.example.chat';
      await monitor.probe();
      accessibility.emitForegroundPackage('com.example.chat');
      await Future<void>.delayed(Duration.zero);

      expect(changes, hasLength(1));
      expect(monitor.currentPackage, 'com.example.chat');
    });
  });

  group('lifecycle', () {
    testWidgets('start polls periodically; stop cancels the timer',
        (WidgetTester tester) async {
      installed.foregroundPackage = 'com.example.chat';
      await monitor.start();
      await tester.pump(); // baseline probe already ran
      expect(changes, hasLength(1));
      expect(installed.getForegroundPackageCalls, 1);

      installed.foregroundPackage = 'com.example.maps';
      await tester.pump(monitor.pollInterval); // next poll tick
      expect(changes, hasLength(2));
      expect(installed.getForegroundPackageCalls, 2);

      await monitor.stop();
      installed.foregroundPackage = 'com.example.chat';
      await tester.pump(monitor.pollInterval); // no timer -> no probe
      expect(installed.getForegroundPackageCalls, 2);
      // No pending-timer failure at teardown proves stop() cancelled it.
    });

    test('start is idempotent (one poll cycle only)', () async {
      await monitor.start();
      await monitor.start();
      expect(installed.getForegroundPackageCalls, 1);
      await monitor.stop();
    });
  });
}
