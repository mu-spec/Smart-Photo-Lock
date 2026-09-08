import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/protection/protection_health.dart';
import 'package:smart_app_lock/services/watcher_service.dart';

void main() {
  ProtectionEngineHealth engine({
    bool configured = true,
    bool running = true,
    ProtectionEngineState state = ProtectionEngineState.healthy,
    bool notification = true,
  }) =>
      ProtectionEngineHealth(
        protectionConfigured: configured,
        serviceRunning: running,
        engineState: state,
        notificationPermissionGranted: notification,
      );

  test('inactive configuration never claims protection is healthy', () {
    final result = ProtectionCapabilityEvaluation.evaluate(
      protectionConfigured: false,
      usageAccess: true,
      accessibility: true,
      overlay: true,
      engine: engine(configured: false, running: false),
    );
    expect(result.status, ProtectionHealthStatus.inactive);
  });

  test('single detector is degraded, never reported fully healthy', () {
    for (final pair in <(bool, bool)>[(true, false), (false, true)]) {
      final result = ProtectionCapabilityEvaluation.evaluate(
        protectionConfigured: true,
        usageAccess: pair.$1,
        accessibility: pair.$2,
        overlay: true,
        engine: engine(),
      );
      expect(result.detectionAvailable, isTrue);
      expect(result.status, ProtectionHealthStatus.degraded);
      expect(result.flashResistantDetectionAvailable, pair.$2);
    }
  });

  test('missing both detection alternatives is unavailable', () {
    final result = ProtectionCapabilityEvaluation.evaluate(
      protectionConfigured: true,
      usageAccess: false,
      accessibility: false,
      overlay: true,
      engine: engine(),
    );
    expect(result.status, ProtectionHealthStatus.unavailable);
  });

  test('missing required overlay is unavailable', () {
    final result = ProtectionCapabilityEvaluation.evaluate(
      protectionConfigured: true,
      usageAccess: true,
      accessibility: true,
      overlay: false,
      engine: engine(),
    );
    expect(result.status, ProtectionHealthStatus.unavailable);
  });

  test('running native recovery is distinguishable from healthy', () {
    final result = ProtectionCapabilityEvaluation.evaluate(
      protectionConfigured: true,
      usageAccess: true,
      accessibility: false,
      overlay: true,
      engine: engine(state: ProtectionEngineState.recovering),
    );
    expect(result.status, ProtectionHealthStatus.recovering);
  });

  test('stopped or unavailable engine is unavailable', () {
    final result = ProtectionCapabilityEvaluation.evaluate(
      protectionConfigured: true,
      usageAccess: true,
      accessibility: true,
      overlay: true,
      engine: engine(
        running: false,
        state: ProtectionEngineState.unavailable,
      ),
    );
    expect(result.status, ProtectionHealthStatus.unavailable);
  });

  test('both detection paths plus engine and shield is healthy', () {
    final result = ProtectionCapabilityEvaluation.evaluate(
      protectionConfigured: true,
      usageAccess: true,
      accessibility: true,
      overlay: true,
      engine: engine(),
    );
    expect(result.status, ProtectionHealthStatus.healthy);
    expect(result.detectionRedundant, isTrue);
    expect(result.flashResistantDetectionAvailable, isTrue);
  });

  test('hidden optional notification reports degraded, not unavailable', () {
    final result = ProtectionCapabilityEvaluation.evaluate(
      protectionConfigured: true,
      usageAccess: true,
      accessibility: true,
      overlay: true,
      engine: engine(notification: false),
    );
    expect(result.status, ProtectionHealthStatus.degraded);
    expect(result.notificationVisible, isFalse);
  });
}
