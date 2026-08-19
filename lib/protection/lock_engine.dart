/// Contract for the lock-enforcement layer — the "muscle" of Smart App Lock.
///
/// Deliberately NOT implemented in Phase 1B. Concrete implementations in
/// later phases combine strategies:
///   * overlay strategy   — SYSTEM_ALERT_WINDOW draws the PIN challenge
///   * accessibility      — detects foreground app switches
///   * device-admin       — uninstall/reinstall protection
///
/// Nothing outside this module may touch Android platform code directly;
/// everything flows through [LockEngine] and `AccessController`.
abstract interface class LockEngine {
  /// Begin intercepting launches for [packageName].
  Future<bool> startWatching(String packageName);

  /// Stop intercepting launches for [packageName].
  Future<bool> stopWatching(String packageName);

  /// True while the app is actively locked.
  Future<bool> isLocked(String packageName);

  /// Immediately show the lock challenge for [packageName]
  /// (used by the accessibility/usage-stats trigger path).
  Future<bool> lockNow(String packageName);

  /// Tear down all watchers (service shutdown).
  Future<void> dispose();
}
