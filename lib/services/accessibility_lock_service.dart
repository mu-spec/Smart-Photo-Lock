import '../utilities/result.dart';

/// Bridge to the Android Accessibility API — the launch-detection fallback.
///
/// Implemented in the lock phases: an `AccessibilityService` that reports
/// foreground package changes, used when usage-stats polling is disabled or
/// throttled by the OS.
abstract interface class AccessibilityLockService {
  /// True when the user has enabled our accessibility service.
  Future<Result<bool>> isServiceEnabled();

  /// Opens the system accessibility settings screen.
  Future<Result<void>> requestServiceEnable();

  /// Emits the package name of the app currently in the foreground.
  Stream<Result<String>> get foregroundPackages;
}
