/// A temporary unlock window granted after a successful PIN challenge.
///
/// While a session is active, re-opening the same app skips the lock screen —
/// this is what makes unlocking feel instant instead of annoying.
///
/// Phase 5H: the window is INACTIVITY-based. Every allowed re-entry
/// [refresh]es the session — the 2-minute clock restarts from the moment
/// of last use, so a user actively using the protected app is never
/// re-prompted mid-session.
class LockSession {
  const LockSession({
    required this.packageName,
    required this.grantedAt,
    this.window = const Duration(minutes: 2),
  });

  final String packageName;
  final DateTime grantedAt;
  final Duration window;

  DateTime get expiresAt => grantedAt.add(window);

  bool isActiveAt(DateTime now) => now.isBefore(expiresAt);

  bool isExpiredAt(DateTime now) => !isActiveAt(now);

  /// Phase 5H: restarts the inactivity window from [now] — the session
  /// returned by an allowed re-entry so the clock always measures time
  /// since the last protected-app use.
  LockSession refresh(DateTime now) =>
      LockSession(packageName: packageName, grantedAt: now, window: window);

  @override
  String toString() =>
      'LockSession($packageName, granted=${grantedAt.toIso8601String()}, '
      'expires=${expiresAt.toIso8601String()})';
}
