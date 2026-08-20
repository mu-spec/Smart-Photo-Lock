import '../../utilities/result.dart';
import '../accessibility_lock_service.dart';

/// In-memory [AccessibilityLockService] for tests, previews and the
/// in-memory [AppContainer] (Phase 4C).
///
/// [enabled] is mutable so tests can simulate the system settings screen
/// enabling the service between checks; [requestServiceEnableCalls]
/// counts how often the settings screen was requested.
class StaticAccessibilityLockService implements AccessibilityLockService {
  StaticAccessibilityLockService({this.enabled = false});

  bool enabled;
  int requestServiceEnableCalls = 0;

  @override
  Future<Result<bool>> isServiceEnabled() async => Result.success(enabled);

  @override
  Future<Result<void>> requestServiceEnable() async {
    requestServiceEnableCalls++;
    return Result.success(null);
  }

  @override
  Stream<Result<String>> get foregroundPackages =>
      const Stream<Result<String>>.empty();
}
