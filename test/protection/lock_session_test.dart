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
}
