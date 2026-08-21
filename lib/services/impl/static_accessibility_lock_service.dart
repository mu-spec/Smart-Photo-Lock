import 'dart:async';

import '../../utilities/result.dart';
import '../accessibility_lock_service.dart';

/// In-memory [AccessibilityLockService] for tests, previews and the
/// in-memory [AppContainer] (Phase 4C).
///
/// [enabled] is mutable so tests can simulate the system settings screen
/// enabling the service between checks; [requestServiceEnableCalls]
/// counts how often the settings screen was requested. Phase 5A:
/// [emitForegroundPackage] simulates the detection-only service
/// reporting a window-state change.
class StaticAccessibilityLockService implements AccessibilityLockService {
  StaticAccessibilityLockService({this.enabled = false});

  bool enabled;
  int requestServiceEnableCalls = 0;

  final StreamController<Result<String>> _foreground =
      StreamController<Result<String>>.broadcast();

  /// Test hook: simulates the accessibility service reporting a
  /// foreground package (window-state change).
  void emitForegroundPackage(String packageName) =>
      _foreground.add(Result.success(packageName));

  @override
  Future<Result<bool>> isServiceEnabled() async => Result.success(enabled);

  @override
  Future<Result<void>> requestServiceEnable() async {
    requestServiceEnableCalls++;
    return Result.success(null);
  }

  @override
  Stream<Result<String>> get foregroundPackages => _foreground.stream;
}
