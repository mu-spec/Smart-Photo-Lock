import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/data/models/app_entry.dart';
import 'package:smart_app_lock/protection/foreground_app_monitor.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/installed_apps_service.dart';
import 'package:smart_app_lock/utilities/result.dart';

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
      await pumpEventQueue();

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
      await pumpEventQueue();

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
      await pumpEventQueue();

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
      await pumpEventQueue();

      expect(changes, isEmpty);
      expect(monitor.currentPackage, isNull);
    });
  });

  group('accessibility fallback path', () {
    test('window-state events report transitions and dedupe', () async {
      // The fallback path is only live while the monitor is RUNNING:
      // start() establishes the accessibility subscription (in
      // production the lock trigger starts the monitor at app boot).
      // The baseline probe sees no foreground package and emits nothing.
      await monitor.start();
      accessibility.emitForegroundPackage('com.example.chat');
      await pumpEventQueue();
      accessibility.emitForegroundPackage('com.example.chat');
      await pumpEventQueue();

      expect(changes, hasLength(1));
      expect(changes.single.source, ForegroundDetectionSource.accessibility);

      accessibility.emitForegroundPackage('com.example.maps');
      await pumpEventQueue();

      expect(changes, hasLength(2));
      expect(changes.last.packageName, 'com.example.maps');
      expect(changes.last.source, ForegroundDetectionSource.accessibility);
    });
  });

  group('merged sources', () {
    test('both paths share one deduplicated transition chain', () async {
      await monitor.start(); // subscribe to the fallback; null baseline
      installed.foregroundPackage = 'com.example.chat';
      await monitor.probe(); // usage: chat
      accessibility.emitForegroundPackage('com.example.maps');
      await pumpEventQueue(); // accessibility: maps
      installed.foregroundPackage = 'com.example.chat';
      await monitor.probe(); // usage: chat again (real switch back)
      await pumpEventQueue();

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
      await monitor.start(); // subscribe to the fallback; null baseline
      installed.foregroundPackage = 'com.example.chat';
      await monitor.probe();
      await pumpEventQueue();
      accessibility.emitForegroundPackage('com.example.chat');
      await pumpEventQueue();

      expect(changes, hasLength(1));
      expect(monitor.currentPackage, 'com.example.chat');
    });
  });

  group('diagnostic counters', () {
    test('probes, nulls, accessibility events and failures are counted',
        () async {
      installed.foregroundPackage = null;
      await monitor.probe();
      expect(monitor.probeCount, 1);
      expect(monitor.nullProbeCount, 1);

      installed.foregroundPackage = 'com.example.chat';
      await monitor.probe();
      expect(monitor.probeCount, 2);
      expect(monitor.nullProbeCount, 1);

      // Subscribe to the fallback path before emitting (production
      // always runs the monitor via start()); the baseline probe sees
      // the already-reported package and adds no transition.
      await monitor.start();
      await pumpEventQueue();
      accessibility.emitForegroundPackage('com.example.maps');
      await pumpEventQueue();
      expect(monitor.accessibilityEventCount, 1);
      expect(monitor.failureCount, 0);
    });

    test('failed probes increment the failure counter, not detection',
        () async {
      final _FailingInstalledAppsService failing =
          _FailingInstalledAppsService();
      final ForegroundAppMonitor failingMonitor = ForegroundAppMonitor(
        installedApps: failing,
        accessibility: accessibility,
        now: () => DateTime(2026, 8, 21, 9, 0),
      );
      final List<ForegroundAppChange> changes = <ForegroundAppChange>[];
      failingMonitor.changes.listen(changes.add);

      await failingMonitor.probe();
      expect(failingMonitor.probeCount, 1);
      expect(failingMonitor.failureCount, 1);
      expect(changes, isEmpty);

      await failingMonitor.dispose();
    });
  });

  group('lifecycle', () {
    testWidgets('start polls periodically; stop cancels the timer',
        (WidgetTester tester) async {
      installed.foregroundPackage = 'com.example.chat';
      await monitor.start();
      await tester.pump(); // baseline probe already ran
      await pumpEventQueue();
      expect(changes, hasLength(1));
      expect(installed.getForegroundPackageCalls, 1);

      installed.foregroundPackage = 'com.example.maps';
      await tester.pump(monitor.pollInterval); // next poll tick
      await pumpEventQueue();
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

    test('repeated start/stop cycles are safe and detection keeps '
        'working', () async {
      for (int i = 0; i < 3; i++) {
        await monitor.start();
        await monitor.stop();
      }

      // After three full cycles the monitor still detects correctly.
      installed.foregroundPackage = 'com.example.chat';
      await monitor.probe();
      await pumpEventQueue();
      expect(changes, hasLength(1));
      expect(changes.single.packageName, 'com.example.chat');
      expect(monitor.probeCount, greaterThanOrEqualTo(1));

      await monitor.stop();
    });

    test('dispose is idempotent (double dispose is safe)', () async {
      await monitor.start();
      await monitor.dispose();
      await monitor.dispose(); // must not throw
    });

    test('start after dispose fails loudly (contract guard)', () async {
      await monitor.dispose();
      await expectLater(monitor.start(), throwsStateError);
    });

    testWidgets('dispose cancels the periodic timer even without stop',
        (WidgetTester tester) async {
      installed.foregroundPackage = 'com.example.chat';
      await monitor.start();
      await tester.pump();
      await pumpEventQueue();
      expect(changes, hasLength(1));

      // Dispose directly from the running state: the periodic timer must
      // die (the framework's pending-timer check at teardown proves it)
      // and no further poll may run.
      await monitor.dispose();
      await tester.pump(monitor.pollInterval * 3);
      expect(installed.getForegroundPackageCalls, 1);
    });
  });
}

/// [InstalledAppsService] whose foreground probe always fails — used to
/// prove the monitor's fail-quiet behavior and failure counter.
class _FailingInstalledAppsService implements InstalledAppsService {
  @override
  Future<Result<List<AppEntry>>> getInstalledApps({
    bool includeSystemApps = false,
  }) async =>
      Result.success(const <AppEntry>[]);

  @override
  Future<Result<Uint8List?>> getAppIcon(String packageName) async =>
      Result.success(null);

  @override
  Future<Result<List<AppEntry>>> getRecentlyUsedApps({int limit = 10}) async =>
      Result.success(const <AppEntry>[]);

  @override
  Future<Result<bool>> hasUsageAccess() async => Result.success(true);

  @override
  Future<Result<void>> requestUsageAccess() async => Result.success(null);

  @override
  Future<Result<String?>> getForegroundPackage() async =>
      Result.failure(StateError('backend unavailable'));

  @override
  Future<Result<void>> launchApp(String packageName) async =>
      Result.failure(StateError('backend unavailable'));
}
