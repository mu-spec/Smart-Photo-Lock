import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/services/capability_monitor.dart';
import 'package:smart_app_lock/utilities/result.dart';

/// Phase 4F: the revocation monitor — granted→revoked edges only,
/// fail-quiet probes, no duplicate spam, timer-driven + resume probes.
void main() {
  final DateTime start = DateTime(2026, 8, 20, 12, 0);
  int tick = 0;
  DateTime fakeNow() => start.add(Duration(seconds: tick));

  group('CapabilityMonitor', () {
    test('emits exactly one granted->revoked change per kind', () async {
      final Map<CapabilityKind, bool> state = <CapabilityKind, bool>{
        CapabilityKind.usageAccess: true,
        CapabilityKind.accessibility: true,
        CapabilityKind.overlay: true,
      };
      CapabilityMonitor monitor() => CapabilityMonitor(
            hasUsageAccess: () async =>
                Result.success(state[CapabilityKind.usageAccess]!),
            isAccessibilityEnabled: () async =>
                Result.success(state[CapabilityKind.accessibility]!),
            canDrawOverlays: () async =>
                Result.success(state[CapabilityKind.overlay]!),
            now: fakeNow,
          );

      final CapabilityMonitor m = monitor();
      final List<CapabilityChange> changes = <CapabilityChange>[];
      m.changes.listen(changes.add);

      await m.probe(); // baseline: granted — NO change emitted
      expect(changes, isEmpty);

      // Usage access revoked in the system settings.
      state[CapabilityKind.usageAccess] = false;
      await m.probe();
      expect(changes, hasLength(1));
      expect(changes.single.kind, CapabilityKind.usageAccess);
      expect(changes.single.state, CapabilityState.revoked);
      expect(changes.single.at, fakeNow());

      // Repeated probes while it stays revoked: NO duplicate spam.
      await m.probe();
      await m.probe();
      expect(changes, hasLength(1));

      await m.dispose();
    });

    test('does not emit for revocations that existed before the baseline',
        () async {
      final Map<CapabilityKind, bool> state = <CapabilityKind, bool>{
        CapabilityKind.usageAccess: true,
        CapabilityKind.accessibility: false, // already revoked at start
        CapabilityKind.overlay: false, // already revoked at start
      };
      final CapabilityMonitor m = CapabilityMonitor(
        hasUsageAccess: () async =>
            Result.success(state[CapabilityKind.usageAccess]!),
        isAccessibilityEnabled: () async =>
            Result.success(state[CapabilityKind.accessibility]!),
        canDrawOverlays: () async =>
            Result.success(state[CapabilityKind.overlay]!),
        now: fakeNow,
      );
      final List<CapabilityChange> changes = <CapabilityChange>[];
      m.changes.listen(changes.add);

      await m.probe(); // baseline only — nothing emitted
      expect(changes, isEmpty);

      // A LATER revocation of the granted one fires once.
      state[CapabilityKind.usageAccess] = false;
      await m.probe();
      expect(changes, hasLength(1));
      expect(changes.single.kind, CapabilityKind.usageAccess);

      await m.dispose();
    });

    test('probe failures are fail-quiet (no fabricated transitions)',
        () async {
      bool fail = false;
      final CapabilityMonitor m = CapabilityMonitor(
        hasUsageAccess: () async =>
            fail ? Result.failure(StateError('boom')) : Result.success(true),
        isAccessibilityEnabled: () async => Result.success(true),
        canDrawOverlays: () async => Result.success(true),
        now: fakeNow,
      );
      final List<CapabilityChange> changes = <CapabilityChange>[];
      m.changes.listen(changes.add);

      await m.probe(); // baseline granted

      fail = true; // probes now fail — NOT a revocation
      await m.probe();
      await m.probe();
      expect(changes, isEmpty);

      fail = false; // back to granted — still no edge
      await m.probe();
      expect(changes, isEmpty);

      await m.dispose();
    });

    test('re-grants do not emit and the next revocation fires again',
        () async {
      bool overlayGranted = true;
      final CapabilityMonitor m = CapabilityMonitor(
        hasUsageAccess: () async => Result.success(true),
        isAccessibilityEnabled: () async => Result.success(true),
        canDrawOverlays: () async => Result.success(overlayGranted),
        now: fakeNow,
      );
      final List<CapabilityChange> changes = <CapabilityChange>[];
      m.changes.listen(changes.add);

      await m.probe(); // baseline granted
      expect(m.previousGranted[CapabilityKind.overlay], isTrue);
      expect(m.evaluationCounts[CapabilityKind.overlay], 1);
      overlayGranted = false;
      await m.probe();
      // Internal state FIRST: proves the overlay evaluation ran and
      // observed the revoked value, before checking the emitted event.
      expect(m.evaluationCounts[CapabilityKind.overlay], 2);
      expect(m.previousGranted[CapabilityKind.overlay], isFalse);
      expect(changes, hasLength(1));
      expect(changes.single.kind, CapabilityKind.overlay);

      // User re-grants: the next revocation is a NEW edge.
      overlayGranted = true;
      await m.probe();
      expect(m.evaluationCounts[CapabilityKind.overlay], 3);
      expect(changes, hasLength(1)); // re-grant not surfaced
      expect(m.previousGranted[CapabilityKind.overlay], isTrue); // re-armed

      overlayGranted = false;
      await m.probe();
      expect(m.evaluationCounts[CapabilityKind.overlay], 4);
      expect(changes, hasLength(2));
      expect(changes.last.kind, CapabilityKind.overlay);

      await m.dispose();
    });

    test('manual probes detect revocations made between timer ticks',
        () async {
      final Map<CapabilityKind, bool> state = <CapabilityKind, bool>{
        CapabilityKind.accessibility: true,
      };
      final CapabilityMonitor m = CapabilityMonitor(
        hasUsageAccess: () async => Result.success(true),
        isAccessibilityEnabled: () async =>
            Result.success(state[CapabilityKind.accessibility]!),
        canDrawOverlays: () async => Result.success(true),
        interval: const Duration(minutes: 5), // long timer
        now: fakeNow,
      );
      final List<CapabilityChange> changes = <CapabilityChange>[];
      m.changes.listen(changes.add);
      m.start();
      await Future<void>.delayed(Duration.zero); // baseline ran

      state[CapabilityKind.accessibility] = false;
      await m.probe(); // manual (resume-style) probe between ticks
      expect(changes, hasLength(1));
      expect(changes.single.kind, CapabilityKind.accessibility);

      await m.dispose();
    });

    test('each capability re-arms independently after its own re-grant',
        () async {
      bool usageAccessGranted = true;
      bool overlayGranted = true;
      final CapabilityMonitor m = CapabilityMonitor(
        hasUsageAccess: () async => Result.success(usageAccessGranted),
        isAccessibilityEnabled: () async => Result.success(true),
        canDrawOverlays: () async => Result.success(overlayGranted),
        now: fakeNow,
      );
      final List<CapabilityChange> changes = <CapabilityChange>[];
      m.changes.listen(changes.add);

      await m.probe(); // baseline granted
      expect(m.previousGranted[CapabilityKind.usageAccess], isTrue);
      expect(m.previousGranted[CapabilityKind.overlay], isTrue);
      expect(m.evaluationCounts[CapabilityKind.overlay], 1);

      // Revoke BOTH, then re-grant ONLY usage access. Overlay stays
      // revoked (no duplicate spam), usage re-arms.
      usageAccessGranted = false;
      overlayGranted = false;
      await m.probe();
      // Internal state FIRST: proves BOTH evaluations ran and observed
      // the revoked values, before checking the emitted events.
      expect(m.evaluationCounts[CapabilityKind.usageAccess], 2);
      expect(m.evaluationCounts[CapabilityKind.overlay], 2);
      expect(m.previousGranted[CapabilityKind.usageAccess], isFalse);
      expect(m.previousGranted[CapabilityKind.overlay], isFalse);
      expect(changes, hasLength(2));

      usageAccessGranted = true;
      await m.probe();
      expect(m.evaluationCounts[CapabilityKind.overlay], 3);
      expect(changes, hasLength(2)); // re-grant not surfaced
      expect(m.previousGranted[CapabilityKind.usageAccess], isTrue);
      expect(m.previousGranted[CapabilityKind.overlay], isFalse);

      // Usage revoked again: a NEW event for usage only.
      usageAccessGranted = false;
      await m.probe();
      expect(changes, hasLength(3));
      expect(changes.last.kind, CapabilityKind.usageAccess);

      // Overlay re-granted: still no event, and it re-arms too.
      overlayGranted = true;
      await m.probe();
      expect(changes, hasLength(3));
      expect(m.previousGranted[CapabilityKind.overlay], isTrue);
      overlayGranted = false;
      await m.probe();
      expect(changes, hasLength(4));
      expect(changes.last.kind, CapabilityKind.overlay);

      await m.dispose();
    });
  });

  group('CapabilityMonitor lifecycle', () {
    CapabilityMonitor monitor() => CapabilityMonitor(
          hasUsageAccess: () async => Result.success(true),
          isAccessibilityEnabled: () async => Result.success(true),
          canDrawOverlays: () async => Result.success(true),
          now: fakeNow,
        );

    testWidgets('stop cancels the periodic timer', (WidgetTester tester) async {
      final CapabilityMonitor m = monitor();
      await tester.pumpWidget(const SizedBox());
      m.start();
      await tester.pump();
      m.stop();
      // No further cleanup: if the periodic timer were still pending,
      // the framework fails this test at teardown.
    });

    testWidgets('start is idempotent (no duplicate timers)',
        (WidgetTester tester) async {
      final CapabilityMonitor m = monitor();
      await tester.pumpWidget(const SizedBox());
      m.start();
      m.start(); // must be a no-op — a second timer would leak
      await tester.pump();
      m.stop();
    });

    testWidgets('start after stop resumes periodic monitoring',
        (WidgetTester tester) async {
      final CapabilityMonitor m = monitor();
      await tester.pumpWidget(const SizedBox());
      m.start();
      m.stop();
      m.start();
      await tester.pump();
      m.stop();
    });
  });
}
