import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/protected_apps_repository.dart';
import 'package:smart_app_lock/protection/access_controller.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/protection/lock_session.dart';
import 'package:smart_app_lock/protection/protected_app_matcher.dart';
import 'package:smart_app_lock/utilities/result.dart';

/// Phase 5D: the access decision policy — protected apps require a
/// challenge, unlock sessions allow re-entry, sessions expire, and
/// unknown protection state fails closed.
void main() {
  late AppContainer container;
  late DefaultAccessController controller;

  setUp(() {
    container = AppContainer.inMemory();
    controller = container.accessController as DefaultAccessController;
  });

  Future<void> protect(String package) => container.protectedApps.add(
        ProtectedApp(
          packageName: package,
          label: package,
          addedAt: DateTime(2026, 8, 21),
        ),
      );

  test('an unprotected app is allowed', () async {
    expect(
      await controller.evaluate('com.example.chat'),
      AccessDecision.allow,
    );
  });

  test('a protected app without a session requires a challenge', () async {
    await protect('com.whatsapp');
    expect(
      await controller.evaluate('com.whatsapp'),
      AccessDecision.challenge,
    );
  });

  test('grantAccess opens a session that allows re-entry', () async {
    await protect('com.whatsapp');
    expect(
      await controller.evaluate('com.whatsapp'),
      AccessDecision.challenge,
    );

    final LockSession session =
        (await controller.grantAccess('com.whatsapp')).valueOrNull!;
    expect(session.packageName, 'com.whatsapp');
    expect(session.isActiveAt(DateTime.now()), isTrue);

    expect(
      await controller.evaluate('com.whatsapp'),
      AccessDecision.allow,
    );
    // Other protected apps are unaffected by another app's session.
    await protect('com.example.maps');
    expect(
      await controller.evaluate('com.example.maps'),
      AccessDecision.challenge,
    );
  });

  test('sessions expire after their window', () async {
    await protect('com.whatsapp');
    final DefaultAccessController clocked = DefaultAccessController(
      matcher: container.protectedAppMatcher,
      now: () => DateTime(2026, 8, 21, 9, 0),
    );
    await clocked.grantAccess('com.whatsapp');
    expect(
      await clocked.evaluate('com.whatsapp'),
      AccessDecision.allow,
    );

    // A controller past the 2-minute window must challenge again.
    final DefaultAccessController later = DefaultAccessController(
      matcher: container.protectedAppMatcher,
      now: () => DateTime(2026, 8, 21, 9, 3),
    );
    expect(
      await later.evaluate('com.whatsapp'),
      AccessDecision.challenge,
    );
  });

  test('clearSessions revokes every open window', () async {
    await protect('com.whatsapp');
    await controller.grantAccess('com.whatsapp');
    expect(
      await controller.evaluate('com.whatsapp'),
      AccessDecision.allow,
    );

    controller.clearSessions();
    expect(
      await controller.evaluate('com.whatsapp'),
      AccessDecision.challenge,
    );
  });

  test('a repository failure fails closed as challenge', () async {
    // The matcher maps repository failures to `unknown`; the controller
    // must treat unknown as challenge (never allow).
    final DefaultAccessController failing = DefaultAccessController(
      matcher: ProtectedAppMatcher(repository: _FailingRepository()),
    );
    expect(
      await failing.evaluate('com.anything'),
      AccessDecision.challenge,
    );
  });
}

/// [ProtectedAppsRepository] whose reads always fail — proves the
/// controller fails closed (unknown -> challenge).
class _FailingRepository implements ProtectedAppsRepository {
  @override
  Future<Result<List<ProtectedApp>>> getProtectedApps() async =>
      Result.failure(StateError('database unavailable'));

  @override
  Future<Result<void>> add(ProtectedApp app) async =>
      Result.failure(StateError('database unavailable'));

  @override
  Future<Result<void>> remove(String packageName) async =>
      Result.failure(StateError('database unavailable'));

  @override
  Future<Result<bool>> isProtected(String packageName) async =>
      Result.failure(StateError('database unavailable'));

  @override
  Future<Result<int>> count() async =>
      Result.failure(StateError('database unavailable'));
}
