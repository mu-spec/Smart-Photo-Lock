import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/protection/lock_session.dart';

void main() {
  final LockSession session = LockSession(
    packageName: 'com.whatsapp',
    grantedAt: DateTime(2026, 8, 19, 12, 0, 0),
  );

  test('session is active inside its window', () {
    expect(session.isActiveAt(DateTime(2026, 8, 19, 12, 1, 30)), isTrue);
    expect(session.isExpiredAt(DateTime(2026, 8, 19, 12, 1, 30)), isFalse);
  });

  test('session expires after the window', () {
    expect(session.isExpiredAt(DateTime(2026, 8, 19, 12, 2, 1)), isTrue);
    expect(session.isActiveAt(DateTime(2026, 8, 19, 12, 2, 1)), isFalse);
  });

  test('expiresAt equals grantedAt + window', () {
    expect(session.expiresAt, DateTime(2026, 8, 19, 12, 2, 0));
  });

  test('custom windows are respected', () {
    final LockSession short = LockSession(
      packageName: 'com.whatsapp',
      grantedAt: DateTime(2026, 8, 19, 12, 0, 0),
      window: const Duration(seconds: 30),
    );
    expect(short.isActiveAt(DateTime(2026, 8, 19, 12, 0, 29)), isTrue);
    expect(short.isExpiredAt(DateTime(2026, 8, 19, 12, 0, 31)), isTrue);
  });

  test('refresh restarts the inactivity window from the given moment '
      '(Phase 5H)', () {
    // The original window expires at 12:02:00...
    final LockSession refreshed = session.refresh(
      DateTime(2026, 8, 19, 12, 1, 30),
    );
    // ...but after the refresh the expiry slides to 12:03:30, so a
    // moment that would have been past the original expiry is active.
    expect(
      refreshed.isActiveAt(DateTime(2026, 8, 19, 12, 2, 30)),
      isTrue,
    );
    expect(
      refreshed.expiresAt,
      DateTime(2026, 8, 19, 12, 3, 30),
    );
    // The original session object is untouched (immutable).
    expect(session.expiresAt, DateTime(2026, 8, 19, 12, 2, 0));
  });
}
