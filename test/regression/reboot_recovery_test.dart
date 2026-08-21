import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/repositories/impl/lock_settings_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/impl/protected_apps_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/impl/security_settings_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/security_settings_repository.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/access_controller.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/protection/protected_app_matcher.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/credential_state_machine.dart';
import 'package:smart_app_lock/security/credentials/impl/default_credential_manager.dart';
import 'package:smart_app_lock/security/credentials/pattern_hasher.dart';
import 'package:smart_app_lock/security/pin_hasher.dart';

/// Phase 5S: reboot recovery — protection is restored correctly the
/// moment Smart App Lock runs again (Android does not allow boot-time
/// auto-start; recovery is lazy by design, see capabilities.md).
///
/// What a reboot means for each state layer:
///  * unlock sessions / grace deadlines are in-memory -> gone (fail-closed);
///  * protected-app list, credentials and the persisted lockout persist
///    through the database -> restored exactly;
///  * the grace-period setting persists -> restored (5L);
///  * an expired lockout stays expired, an active one stays active
///    (timestamps are wall-clock based).
void main() {
  test('the protected-app list survives a reboot (fresh repository over '
      'the same database)', () async {
    final InMemoryLocalDatabase database = InMemoryLocalDatabase();

    // "Before the reboot": the user protects WhatsApp.
    final ProtectedAppsRepositoryImpl before =
        ProtectedAppsRepositoryImpl(database);
    await before.add(
      ProtectedApp(
        packageName: 'com.whatsapp',
        label: 'WhatsApp',
        addedAt: DateTime(2026, 8, 21, 9, 0),
      ),
    );

    // "After the reboot": a fresh repository/controller stack over the
    // same database. The fresh controller has NO unlock sessions, so a
    // protected foreground must challenge immediately.
    final DefaultAccessController after = DefaultAccessController(
      matcher: ProtectedAppMatcher(
        repository: ProtectedAppsRepositoryImpl(database),
      ),
      auth: _managerFor(SecuritySettingsRepositoryImpl(database)),
      now: () => DateTime(2026, 8, 21, 9, 5),
    );

    expect(
      await after.evaluate('com.whatsapp'),
      AccessDecision.challenge,
    );
    expect(
      await after.evaluate('com.example.chat'),
      AccessDecision.allow,
    );
  });

  test('a grace period set before the reboot is restored after it',
      () async {
    final InMemoryLocalDatabase database = InMemoryLocalDatabase();

    final LockSettingsRepositoryImpl before =
        LockSettingsRepositoryImpl(database);
    await before.setGracePeriod(const Duration(seconds: 30));

    final LockSettingsRepositoryImpl after =
        LockSettingsRepositoryImpl(database);
    final duration = (await after.getGracePeriod()).valueOrNull!;
    expect(duration, const Duration(seconds: 30));
  });

  test('an ACTIVE lockout survives the reboot (fail-closed)', () async {
    final InMemoryLocalDatabase database = InMemoryLocalDatabase();
    final DefaultCredentialManager before = _managerFor(
      SecuritySettingsRepositoryImpl(database),
    );
    await before.enrollPin('1234');
    for (int i = 0; i < 3; i++) {
      await before.authenticatePin('9999');
    }

    // "Reboot": a fresh manager over the same persisted state. The
    // cooldown timestamp is wall-clock based — while it is still in the
    // future, even the CORRECT PIN is blocked.
    final DefaultCredentialManager after = _managerFor(
      SecuritySettingsRepositoryImpl(database),
    );
    final AuthAttemptResult during =
        (await after.authenticatePin('1234')).valueOrNull!;
    expect(during, isA<AuthLockedOut>());
  });

  test('an EXPIRED lockout does not block after the reboot', () async {
    final InMemoryLocalDatabase database = InMemoryLocalDatabase();
    // A 1-second cooldown so wall-clock expiry is deterministic.
    final DefaultCredentialManager before = DefaultCredentialManager(
      settings: SecuritySettingsRepositoryImpl(database),
      pinHasher: Pbkdf2PinHasher(iterations: 200),
      patternHasher: Pbkdf2PatternHasher(iterations: 200),
      stateMachine: CredentialStateMachine(
        maxFailedAttempts: 3,
        lockoutDuration: const Duration(seconds: 1),
      ),
    );
    await before.enrollPin('1234');
    for (int i = 0; i < 3; i++) {
      await before.authenticatePin('9999');
    }

    // The "device was off" for longer than the cooldown: a fresh
    // manager sees the wall clock past the expiry and the correct PIN
    // authenticates again.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final DefaultCredentialManager after = DefaultCredentialManager(
      settings: SecuritySettingsRepositoryImpl(database),
      pinHasher: Pbkdf2PinHasher(iterations: 200),
      patternHasher: Pbkdf2PatternHasher(iterations: 200),
      stateMachine: CredentialStateMachine(
        maxFailedAttempts: 3,
        lockoutDuration: const Duration(seconds: 1),
      ),
    );
    final AuthAttemptResult afterExpiry =
        (await after.authenticatePin('1234')).valueOrNull!;
    expect(afterExpiry, isA<AuthSuccess>());
  });

  test('credentials persist across the reboot', () async {
    final InMemoryLocalDatabase database = InMemoryLocalDatabase();
    final DefaultCredentialManager before = _managerFor(
      SecuritySettingsRepositoryImpl(database),
    );
    await before.enrollPin('1234');

    final DefaultCredentialManager after = _managerFor(
      SecuritySettingsRepositoryImpl(database),
    );
    expect(
      (await after.authenticatePin('1234')).valueOrNull,
      isA<AuthSuccess>(),
    );
    expect(
      (await after.authenticatePin('9999')).valueOrNull,
      isA<AuthFailure>(),
    );
  });
}

DefaultCredentialManager _managerFor(
  SecuritySettingsRepository settings,
) =>
    DefaultCredentialManager(
      settings: settings,
      pinHasher: Pbkdf2PinHasher(iterations: 200),
      patternHasher: Pbkdf2PatternHasher(iterations: 200),
      stateMachine: CredentialStateMachine(
        maxFailedAttempts: 3,
        lockoutDuration: const Duration(seconds: 30),
      ),
    );
