import '../../utilities/result.dart';
import '../overlay_lock_service.dart';

/// In-memory [OverlayLockService] for tests, previews and the in-memory
/// [AppContainer] (Phase 4D).
///
/// [overlayGranted] is mutable so tests can simulate the system settings
/// screen granting the capability between checks; [requestCalls] counts
/// how often the settings screen was requested.
class StaticOverlayLockService implements OverlayLockService {
  StaticOverlayLockService({this.overlayGranted = false});

  bool overlayGranted;
  int requestCalls = 0;

  @override
  Future<Result<bool>> canDrawOverlays() async =>
      Result.success(overlayGranted);

  @override
  Future<Result<void>> requestOverlayPermission() async {
    requestCalls++;
    return Result.success(null);
  }

  @override
  Future<Result<void>> showLockChallenge(String packageName) async =>
      Result.failure(StateError('Lock challenge not implemented yet.'));

  @override
  Future<Result<void>> hideLockChallenge() async =>
      Result.failure(StateError('Lock challenge not implemented yet.'));
}
