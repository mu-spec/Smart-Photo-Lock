import '../utilities/result.dart';

/// Bridge to Android's earliest available launch-detection signal.
///
/// Implemented in the lock phases: an `AccessibilityService` that reports
/// foreground package changes before the slower usage-history fallback.
abstract interface class AccessibilityLockService {
  /// True when the user has enabled our accessibility service.
  Future<Result<bool>> isServiceEnabled();

  /// Opens the system accessibility settings screen.
  Future<Result<void>> requestServiceEnable();

  /// Emits the package name of the app currently in the foreground.
  Stream<Result<String>> get foregroundPackages;
}
