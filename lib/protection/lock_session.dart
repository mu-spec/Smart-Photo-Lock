/// A temporary unlock window granted after a successful PIN challenge.
///
/// While a session is active, re-opening the same app skips the lock screen —
/// this is what makes unlocking feel instant instead of annoying.
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

  @override
  String toString() =>
      'LockSession($packageName, granted=${grantedAt.toIso8601String()}, '
      'expires=${expiresAt.toIso8601String()})';
}
