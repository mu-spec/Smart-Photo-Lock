import '../services/watcher_service.dart';

enum CapabilityRequirement { required, alternative, optional, internal }

enum ProtectionHealthStatus {
  inactive,
  healthy,
  degraded,
  recovering,
  unavailable,
}

class ProtectionCapabilityEvaluation {
  const ProtectionCapabilityEvaluation({
    required this.status,
    required this.detectionAvailable,
    required this.detectionRedundant,
    required this.presentationAvailable,
    required this.serviceAvailable,
    required this.notificationVisible,
  });

  final ProtectionHealthStatus status;
  final bool detectionAvailable;
  final bool detectionRedundant;
  final bool presentationAvailable;
  final bool serviceAvailable;
  final bool notificationVisible;

  static ProtectionCapabilityEvaluation evaluate({
    required bool protectionConfigured,
    required bool usageAccess,
    required bool accessibility,
    required bool overlay,
    required ProtectionEngineHealth engine,
  }) {
    final bool detection = usageAccess || accessibility;
    final bool redundant = usageAccess && accessibility;
    final bool service = engine.serviceRunning;
    if (!protectionConfigured) {
      return ProtectionCapabilityEvaluation(
        status: ProtectionHealthStatus.inactive,
        detectionAvailable: detection,
        detectionRedundant: redundant,
        presentationAvailable: overlay,
        serviceAvailable: service,
        notificationVisible: engine.notificationPermissionGranted,
      );
    }
    if (!detection || !overlay || !service ||
        engine.engineState == ProtectionEngineState.unavailable) {
      return ProtectionCapabilityEvaluation(
        status: ProtectionHealthStatus.unavailable,
        detectionAvailable: detection,
        detectionRedundant: redundant,
        presentationAvailable: overlay,
        serviceAvailable: service,
        notificationVisible: engine.notificationPermissionGranted,
      );
    }
    if (engine.engineState == ProtectionEngineState.recovering) {
      return ProtectionCapabilityEvaluation(
        status: ProtectionHealthStatus.recovering,
        detectionAvailable: detection,
        detectionRedundant: redundant,
        presentationAvailable: overlay,
        serviceAvailable: service,
        notificationVisible: engine.notificationPermissionGranted,
      );
    }
    final bool degraded = !redundant || !engine.notificationPermissionGranted;
    return ProtectionCapabilityEvaluation(
      status: degraded
          ? ProtectionHealthStatus.degraded
          : ProtectionHealthStatus.healthy,
      detectionAvailable: detection,
      detectionRedundant: redundant,
      presentationAvailable: overlay,
      serviceAvailable: service,
      notificationVisible: engine.notificationPermissionGranted,
    );
  }
}
