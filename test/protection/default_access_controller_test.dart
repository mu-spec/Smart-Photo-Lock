import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/impl/security_settings_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/protected_apps_repository.dart';
import 'package:smart_app_lock/data/repositories/security_settings_repository.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/access_controller.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/protection/lock_session.dart';
import 'package:smart_app_lock/protection/protected_app_matcher.dart';
import 'package:smart_app_lock/security/credentials/credential_state_machine.dart';
import 'package:smart_app_lock/security/credentials/impl/default_credential_manager.dart';
import 'package:smart_app_lock/security/credentials/pattern_hasher.dart';
import 'package:smart_app_lock/security/pin_hasher.dart';
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
    DateTime clock = DateTime(2026, 8, 21, 9, 0);
    final DefaultAccessController controller = DefaultAccessController(
      matcher: container.protectedAppMatcher,
      auth: container.auth,
      now: () => clock,
    );
    await controller.grantAccess('com.whatsapp');
    expect(
      await controller.evaluate('com.whatsapp'),
      AccessDecision.allow,
    );

    // Three minutes later the same controller must challenge again —
    // the 2-minute inactivity window expired.
    clock = DateTime(2026, 8, 21, 9, 3);
    expect(
      await controller.evaluate('com.whatsapp'),
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
      auth: container.auth,
    );
    expect(
      await failing.evaluate('com.anything'),
      AccessDecision.challenge,
    );
  });

  test('an active authentication lockout denies protected access '
      '(Phase 5E)', () async {
    await protect('com.whatsapp');
    final SecuritySettingsRepository settings =
        SecuritySettingsRepositoryImpl(InMemoryLocalDatabase());
    final DefaultCredentialManager manager = DefaultCredentialManager(
      settings: settings,
      pinHasher: Pbkdf2PinHasher(iterations: 200),
      patternHasher: Pbkdf2PatternHasher(iterations: 200),
      stateMachine: CredentialStateMachine(
        maxFailedAttempts: 3,
        lockoutDuration: const Duration(seconds: 30),
      ),
    );
    await manager.enrollPin('1234');
    // Three wrong attempts trip the 30-second lockout.
    for (int i = 0; i < 3; i++) {
      await manager.authenticatePin('9999');
    }

    final DefaultAccessController lockedOut = DefaultAccessController(
      matcher: container.protectedAppMatcher,
      auth: manager,
      now: () => DateTime(2026, 8, 21, 9, 0),
    );
    expect(
      await lockedOut.evaluate('com.whatsapp'),
      AccessDecision.deny,
    );

    // Unprotected apps stay allowed even during a lockout.
    expect(
      await lockedOut.evaluate('com.example.chat'),
      AccessDecision.allow,
    );
  });

  test('a lockout that has expired challenges again (Phase 5E)',
      () async {
    await protect('com.whatsapp');
    final SecuritySettingsRepository settings =
        SecuritySettingsRepositoryImpl(InMemoryLocalDatabase());
    final DefaultCredentialManager manager = DefaultCredentialManager(
      settings: settings,
      pinHasher: Pbkdf2PinHasher(iterations: 200),
      patternHasher: Pbkdf2PatternHasher(iterations: 200),
      stateMachine: CredentialStateMachine(
        maxFailedAttempts: 3,
        lockoutDuration: const Duration(seconds: 30),
      ),
    );
    await manager.enrollPin('1234');
    for (int i = 0; i < 3; i++) {
      await manager.authenticatePin('9999');
    }

    final DefaultAccessController lockedOut = DefaultAccessController(
      matcher: container.protectedAppMatcher,
      auth: manager,
      now: () => DateTime(2026, 8, 21, 9, 0),
    );
    expect(await lockedOut.evaluate('com.whatsapp'), AccessDecision.deny);

    // Past the cooldown the decision returns to a normal challenge.
    final DefaultAccessController expired = DefaultAccessController(
      matcher: container.protectedAppMatcher,
      auth: manager,
      now: () => DateTime(2026, 8, 21, 9, 1),
    );
    expect(
      await expired.evaluate('com.whatsapp'),
      AccessDecision.challenge,
    );
  });

  test('a pattern-driven lockout denies protected access (Phase 5F)',
      () async {
    await protect('com.whatsapp');
    final SecuritySettingsRepository settings =
        SecuritySettingsRepositoryImpl(InMemoryLocalDatabase());
    final DefaultCredentialManager manager = DefaultCredentialManager(
      settings: settings,
      pinHasher: Pbkdf2PinHasher(iterations: 200),
      patternHasher: Pbkdf2PatternHasher(iterations: 200),
      stateMachine: CredentialStateMachine(
        maxFailedAttempts: 3,
        lockoutDuration: const Duration(seconds: 30),
      ),
    );
    await manager.enrollPattern(const <int>[3, 6, 9, 8]);
    // Patterns share the PIN lockout state (2F): three wrong drawings
    // trip the same cooldown.
    for (int i = 0; i < 3; i++) {
      await manager.authenticatePattern(const <int>[1, 2, 3, 5]);
    }

    final DefaultAccessController lockedOut = DefaultAccessController(
      matcher: container.protectedAppMatcher,
      auth: manager,
      now: () => DateTime(2026, 8, 21, 9, 0),
    );
    expect(
      await lockedOut.evaluate('com.whatsapp'),
      AccessDecision.deny,
    );
  });

  test('an allowed re-entry REFRESHES the inactivity window '
      '(Phase 5H)', () async {
    await protect('com.whatsapp');
    // ONE controller with a MUTABLE clock: sessions live in the
    // controller, so time travel must happen inside it, not across
    // fresh instances (whose session maps would be empty).
    DateTime clock = DateTime(2026, 8, 21, 9, 0);
    final DefaultAccessController controller = DefaultAccessController(
      matcher: container.protectedAppMatcher,
      auth: container.auth,
      now: () => clock,
    );
    await controller.grantAccess('com.whatsapp');

    // Re-entry 90 seconds later: allowed AND the window slides forward
    // (the session now ends 2 minutes after the re-entry, not after
    // the original grant).
    clock = DateTime(2026, 8, 21, 9, 1, 30);
    expect(await controller.evaluate('com.whatsapp'), AccessDecision.allow);
    expect(
      controller.sessionFor('com.whatsapp')!.expiresAt,
      DateTime(2026, 8, 21, 9, 3, 30),
    );

    // The refreshed window keeps the user un-prompted past the
    // ORIGINAL expiry (9:02:00) — active use never re-prompts.
    clock = DateTime(2026, 8, 21, 9, 2, 30);
    expect(
      await controller.evaluate('com.whatsapp'),
      AccessDecision.allow,
    );
  });

  test('expired sessions are pruned and challenge again (Phase 5H)',
      () async {
    await protect('com.whatsapp');
    DateTime clock = DateTime(2026, 8, 21, 9, 0);
    final DefaultAccessController controller = DefaultAccessController(
      matcher: container.protectedAppMatcher,
      auth: container.auth,
      now: () => clock,
    );
    await controller.grantAccess('com.whatsapp');
    expect(controller.sessionFor('com.whatsapp'), isNotNull);

    // Four minutes of INACTIVITY later: the window expired.
    clock = DateTime(2026, 8, 21, 9, 4);
    expect(await controller.evaluate('com.whatsapp'), AccessDecision.challenge);
    // The dead session was pruned from the map.
    expect(controller.sessionFor('com.whatsapp'), isNull);
  });

  test('revokeAccess ends the unlock window immediately (Phase 5J)',
      () async {
    await protect('com.whatsapp');
    await controller.grantAccess('com.whatsapp');
    expect(controller.sessionFor('com.whatsapp'), isNotNull);
    expect(
      await controller.evaluate('com.whatsapp'),
      AccessDecision.allow,
    );

    // Leaving the app revokes the session instantly: the next
    // evaluation challenges again, and the map no longer holds it.
    expect((await controller.revokeAccess('com.whatsapp')).isSuccess,
        isTrue);
    expect(controller.sessionFor('com.whatsapp'), isNull);
    expect(
      await controller.evaluate('com.whatsapp'),
      AccessDecision.challenge,
    );

    // Revoking an unknown package is a harmless no-op.
    expect((await controller.revokeAccess('com.example.other')).isSuccess,
        isTrue);
  });

  test('revokeAllAccess ends every unlock window at once (Phase 5K)',
      () async {
    await protect('com.whatsapp');
    await protect('com.example.maps');
    await controller.grantAccess('com.whatsapp');
    await controller.grantAccess('com.example.maps');
    expect(controller.sessionFor('com.whatsapp'), isNotNull);
    expect(controller.sessionFor('com.example.maps'), isNotNull);

    expect((await controller.revokeAllAccess()).isSuccess, isTrue);
    expect(controller.sessionFor('com.whatsapp'), isNull);
    expect(controller.sessionFor('com.example.maps'), isNull);
    expect(
      await controller.evaluate('com.whatsapp'),
      AccessDecision.challenge,
    );
    expect(
      await controller.evaluate('com.example.maps'),
      AccessDecision.challenge,
    );
  });

  // -- re-lock grace (Phase 5L) ---------------------------------------------

  test('a grace period delays re-lock after leaving (Phase 5L)', () async {
    await protect('com.whatsapp');
    DateTime clock = DateTime(2026, 8, 21, 9, 0);
    final DefaultAccessController controller = DefaultAccessController(
      matcher: container.protectedAppMatcher,
      auth: container.auth,
      now: () => clock,
    );
    controller.setGracePeriod(const Duration(seconds: 30));
    await controller.grantAccess('com.whatsapp');

    // Leaving starts the grace clock instead of removing the session.
    await controller.revokeAccess('com.whatsapp');
    expect(controller.sessionFor('com.whatsapp'), isNotNull);

    // Re-entry 20 seconds later (within grace): allowed without
    // re-authentication, and the grace marker is consumed.
    clock = DateTime(2026, 8, 21, 9, 0, 20);
    expect(await controller.evaluate('com.whatsapp'), AccessDecision.allow);

    // Leave again, then return AFTER the 30-second grace: challenge.
    await controller.revokeAccess('com.whatsapp');
    clock = DateTime(2026, 8, 21, 9, 0, 51);
    expect(
      await controller.evaluate('com.whatsapp'),
      AccessDecision.challenge,
    );
    expect(controller.sessionFor('com.whatsapp'), isNull);
  });

  test('zero grace keeps the immediate re-lock default (Phase 5L)',
      () async {
    await protect('com.whatsapp');
    final DefaultAccessController clocked = DefaultAccessController(
      matcher: container.protectedAppMatcher,
      auth: container.auth,
      now: () => DateTime(2026, 8, 21, 9, 0),
    );
    await clocked.grantAccess('com.whatsapp');
    await clocked.revokeAccess('com.whatsapp'); // grace is zero
    expect(clocked.sessionFor('com.whatsapp'), isNull);
    expect(
      await clocked.evaluate('com.whatsapp'),
      AccessDecision.challenge,
    );
  });

  test('screen-off revokeAllAccess ignores the grace (Phase 5L)',
      () async {
    await protect('com.whatsapp');
    DateTime clock = DateTime(2026, 8, 21, 9, 0);
    final DefaultAccessController controller = DefaultAccessController(
      matcher: container.protectedAppMatcher,
      auth: container.auth,
      now: () => clock,
    );
    controller.setGracePeriod(const Duration(minutes: 5));
    await controller.grantAccess('com.whatsapp');
    await controller.revokeAccess('com.whatsapp'); // grace clock starts
    expect(controller.sessionFor('com.whatsapp'), isNotNull);

    // The screen turning off re-locks EVERYTHING immediately.
    await controller.revokeAllAccess();
    expect(controller.sessionFor('com.whatsapp'), isNull);
    expect(
      await controller.evaluate('com.whatsapp'),
      AccessDecision.challenge,
    );
  });

  test('shrinking the grace clamps pending deadlines (Phase 5L audit)',
      () async {
    await protect('com.whatsapp');
    DateTime clock = DateTime(2026, 8, 21, 9, 0);
    final DefaultAccessController controller = DefaultAccessController(
      matcher: container.protectedAppMatcher,
      auth: container.auth,
      now: () => clock,
    );
    controller.setGracePeriod(const Duration(minutes: 5));
    await controller.grantAccess('com.whatsapp');
    await controller.revokeAccess('com.whatsapp'); // deadline: 9:05:00

    // One minute later the user shrinks the grace to 30 seconds: the
    // pending deadline clamps to 9:01:30.
    clock = DateTime(2026, 8, 21, 9, 1);
    controller.setGracePeriod(const Duration(seconds: 30));

    // 20 seconds after the shrink: still inside the clamped grace.
    clock = DateTime(2026, 8, 21, 9, 1, 20);
    expect(
      await controller.evaluate('com.whatsapp'),
      AccessDecision.allow,
    );

    // A fresh departure under the new grace, then a return past it.
    await controller.revokeAccess('com.whatsapp');
    clock = DateTime(2026, 8, 21, 9, 2);
    expect(
      await controller.evaluate('com.whatsapp'),
      AccessDecision.challenge,
    );
  });

  test('shrinking the grace to zero kills pending deadlines '
      '(Phase 5L audit)', () async {
    await protect('com.whatsapp');
    DateTime clock = DateTime(2026, 8, 21, 9, 0);
    final DefaultAccessController controller = DefaultAccessController(
      matcher: container.protectedAppMatcher,
      auth: container.auth,
      now: () => clock,
    );
    controller.setGracePeriod(const Duration(minutes: 5));
    await controller.grantAccess('com.whatsapp');
    await controller.revokeAccess('com.whatsapp');

    controller.setGracePeriod(Duration.zero); // immediate
    expect(
      await controller.evaluate('com.whatsapp'),
      AccessDecision.challenge,
    );
  });

  test('clearSessions clears grace deadlines too (Phase 5L audit)',
      () async {
    await protect('com.whatsapp');
    DateTime clock = DateTime(2026, 8, 21, 9, 0);
    final DefaultAccessController controller = DefaultAccessController(
      matcher: container.protectedAppMatcher,
      auth: container.auth,
      now: () => clock,
    );
    controller.setGracePeriod(const Duration(minutes: 5));
    await controller.grantAccess('com.whatsapp');
    await controller.revokeAccess('com.whatsapp');

    controller.clearSessions();
    expect(controller.sessionFor('com.whatsapp'), isNull);
    expect(
      await controller.evaluate('com.whatsapp'),
      AccessDecision.challenge,
    );
  });
  // -- rapid switching (Phase 5Q) --------------------------------------------

  test('rapid protected -> unprotected -> protected cycles (immediate '
      'grace)', () async {
    await protect('com.whatsapp');
    final DefaultAccessController controller = DefaultAccessController(
      matcher: container.protectedAppMatcher,
      auth: container.auth,
      now: () => DateTime(2026, 8, 21, 9, 0),
    );

    // Entry 1: no session -> challenge.
    expect(
      await controller.evaluate('com.whatsapp'),
      AccessDecision.challenge,
    );

    // Three rapid leave/re-enter cycles: every departure revokes the
    // fresh session immediately, so every re-entry challenges again.
    for (int i = 0; i < 3; i++) {
      await controller.grantAccess('com.whatsapp');
      await controller.revokeAccess('com.whatsapp'); // leave
      expect(
        await controller.evaluate('com.example.launcher'),
        AccessDecision.allow,
      );
      expect(
        await controller.evaluate('com.whatsapp'),
        AccessDecision.challenge,
        reason: 'cycle ${i + 1} must re-lock on re-entry',
      );
    }
  });

  test('rapid switching inside a grace window allows each re-entry and '
      're-arms on each leave', () async {
    await protect('com.whatsapp');
    DateTime clock = DateTime(2026, 8, 21, 9, 0);
    final DefaultAccessController controller = DefaultAccessController(
      matcher: container.protectedAppMatcher,
      auth: container.auth,
      now: () => clock,
    );
    controller.setGracePeriod(const Duration(seconds: 30));

    // Entry 1 challenges; unlock, then three rapid cycles of
    // leave + quick return (10s each) stay inside the grace.
    expect(
      await controller.evaluate('com.whatsapp'),
      AccessDecision.challenge,
    );
    await controller.grantAccess('com.whatsapp');

    for (int i = 0; i < 3; i++) {
      await controller.revokeAccess('com.whatsapp'); // leave
      expect(
        await controller.evaluate('com.example.launcher'),
        AccessDecision.allow,
      );
      clock = clock.add(const Duration(seconds: 10));
      expect(
        await controller.evaluate('com.whatsapp'),
        AccessDecision.allow,
        reason: 'cycle ${i + 1} within grace must not re-challenge',
      );
    }

    // A leave followed by a return AFTER the grace re-locks.
    await controller.revokeAccess('com.whatsapp');
    clock = clock.add(const Duration(seconds: 40));
    expect(
      await controller.evaluate('com.whatsapp'),
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
      Result.failure(StateError('database unavailable'));}
