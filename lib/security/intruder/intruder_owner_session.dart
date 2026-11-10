// Phase 12 / Milestone 3 — owner evidence-viewing session.
//
// A short-lived, in-memory-only proof that the owner verified with the
// primary app PIN/pattern immediately before opening the evidence viewer.
// It is never persisted (process death destroys it), never extended, and
// never authorizes a mutation on its own — delete / clear-all / settings
// changes always require their own fresh verification. It is not consulted
// by any access decision (lock, challenge, shield, rules or profiles).

import '../credentials/auth_type.dart';

typedef SessionInvalidationListener = void Function(String reason);

/// One verified viewing session. Valid until [IntruderOwnerSessionGate.maxAge]
/// has elapsed since verification, the wall clock moves backwards, or it is
/// invalidated (lifecycle, screen-off, navigation away, newer session).
final class IntruderOwnerSession {
  IntruderOwnerSession._(
      this.id, this.method, this._verifiedAt, this._maxAge, this._now);

  /// Monotonic per-gate id (stale-callback detection).
  final int id;

  /// The primary credential type that was verified.
  final AuthType method;
  final DateTime _verifiedAt;
  final Duration _maxAge;
  final DateTime Function() _now;
  bool _invalidated = false;
  String? _reason;
  final List<SessionInvalidationListener> _listeners =
      <SessionInvalidationListener>[];

  /// Why the session ended (null while valid / never invalidated).
  String? get invalidationReason => _reason;

  /// Evaluated on every call (lazy expiry): fail closed on expiry or a
  /// backwards clock.
  bool get isValid {
    if (_invalidated) return false;
    final DateTime n = _now();
    if (n.isBefore(_verifiedAt) || n.difference(_verifiedAt) >= _maxAge) {
      invalidate('expired');
      return false;
    }
    return true;
  }

  /// Time left (zero when invalid). Used only to arm the UI close timer.
  Duration get remaining {
    if (!isValid) return Duration.zero;
    return _maxAge - _now().difference(_verifiedAt);
  }

  void addListener(SessionInvalidationListener l) => _listeners.add(l);

  void removeListener(SessionInvalidationListener l) => _listeners.remove(l);

  /// Idempotent. Listeners run synchronously, once.
  void invalidate(String reason) {
    if (_invalidated) return;
    _invalidated = true;
    _reason = reason;
    for (final SessionInvalidationListener l
        in List<SessionInvalidationListener>.of(_listeners)) {
      try {
        l(reason);
      } catch (_) {
        // A listener failure never keeps a session alive.
      }
    }
    _listeners.clear();
  }
}

/// One per app container. At most one live session; [begin] replaces (and
/// invalidates) any previous one.
class IntruderOwnerSessionGate {
  IntruderOwnerSessionGate({
    DateTime Function()? now,
    this.maxAge = defaultMaxAge,
  }) : _now = now ?? DateTime.now;

  static const Duration defaultMaxAge = Duration(minutes: 2);

  final DateTime Function() _now;
  final Duration maxAge;
  int _nextId = 0;
  IntruderOwnerSession? _current;

  /// Call ONLY after a successful fresh primary verification plus a fresh
  /// credential status re-check.
  IntruderOwnerSession begin(AuthType method) {
    _current?.invalidate('replaced');
    final IntruderOwnerSession s =
        IntruderOwnerSession._(++_nextId, method, _now(), maxAge, _now);
    _current = s;
    return s;
  }

  /// The live session, or null.
  IntruderOwnerSession? get current {
    final IntruderOwnerSession? s = _current;
    return s != null && s.isValid ? s : null;
  }

  void invalidateAll(String reason) {
    _current?.invalidate(reason);
    _current = null;
  }
}
