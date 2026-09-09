import '../../utilities/result.dart';
import '../overlay_lock_service.dart';
import '../pending_lock_challenge.dart';

/// In-memory [OverlayLockService] for tests, previews and the in-memory
/// [AppContainer] (Phase 4D).
///
/// [overlayGranted] is mutable so tests can simulate the system settings
/// screen granting the capability between checks; [requestCalls] counts
/// how often the settings screen was requested. Phase 5D: the challenge
/// methods are wired — [showLockChallengeSucceeds] controls the result,
/// [showLockChallengeCalls]/[hideLockChallengeCalls] count invocations
/// and [lastLockPackage] records the challenged package. Phase 5O:
/// [secureWindow] records the FLAG_SECURE state and
/// [setSecureWindowCalls] counts the toggles.
class StaticOverlayLockService implements OverlayLockService {
  StaticOverlayLockService({this.overlayGranted = false});

  bool overlayGranted;
  int requestCalls = 0;

  /// Whether [showLockChallenge] reports success (tests may simulate a
  /// failed bring-to-front).
  bool showLockChallengeSucceeds = true;

  /// Whether the rendered challenge may acknowledge native shield handoff.
  /// Tests set this false to model SCREEN_ON while keyguard is still locked.
  bool markChallengeReadySucceeds = true;

  int showLockChallengeCalls = 0;
  int hideLockChallengeCalls = 0;
  int markChallengeReadyCalls = 0;
  String? lastReadyPackage;
  int? lastReadyGeneration;
  int nextChallengeGeneration = 0;

  /// The most recently challenged package, or null.
  String? lastLockPackage;

  /// Phase 5O: the current FLAG_SECURE state the host requested.
  bool secureWindow = false;
  int setSecureWindowCalls = 0;

  @override
  Future<Result<bool>> canDrawOverlays() async =>
      Result.success(overlayGranted);

  @override
  Future<Result<void>> requestOverlayPermission() async {
    requestCalls++;
    return Result.success(null);
  }

  @override
  Future<Result<PendingLockChallenge>> showLockChallenge(
    String packageName,
  ) async {
    showLockChallengeCalls++;
    lastLockPackage = packageName;
    return showLockChallengeSucceeds
        ? Result.success(
            PendingLockChallenge(
              packageName: packageName,
              generation: ++nextChallengeGeneration,
            ),
          )
        : Result.failure(StateError('Could not show the lock challenge.'));
  }

  @override
  Future<Result<void>> hideLockChallenge() async {
    hideLockChallengeCalls++;
    return Result.success(null);
  }

  @override
  Future<Result<void>> markChallengeReady(
    PendingLockChallenge challenge,
  ) async {
    markChallengeReadyCalls++;
    lastReadyPackage = challenge.packageName;
    lastReadyGeneration = challenge.generation;
    return markChallengeReadySucceeds
        ? Result.success(null)
        : Result.failure(StateError('Challenge handoff is not visible yet.'));
  }

  @override
  Future<Result<void>> setSecureWindow(bool secure) async {
    setSecureWindowCalls++;
    secureWindow = secure;
    return Result.success(null);
  }
}
