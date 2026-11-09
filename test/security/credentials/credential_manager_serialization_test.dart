// Phase 12 / Milestone 1 — credential manager serialization (defect fix)
// and the observe-only verified-attempt hook.
//
// On 824b2ae three CONCURRENT wrong PINs persisted failedAttempts=1 and
// never tripped the lockout (lost update: each verification loaded the same
// counters). These tests pin the fix: every settings read-modify-write runs
// under one FIFO lock, biometric verdicts apply to the current counters, the
// observer hears exactly one report per counted verification with the
// attribution captured at the call's start, and a failing observer can never
// change a verdict.
//
// SIMULATED: pure Dart VM, in-memory storage, deterministic clock, fake
// biometric service. No device or biometric hardware involved.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/data/models/security_settings.dart';
import 'package:smart_app_lock/data/repositories/impl/security_settings_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/security_settings_repository.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/credentials/biometric_options.dart';
import 'package:smart_app_lock/security/credentials/credential_state.dart';
import 'package:smart_app_lock/security/credentials/credential_state_machine.dart';
import 'package:smart_app_lock/security/credentials/impl/default_credential_manager.dart';
import 'package:smart_app_lock/security/credentials/pattern_hasher.dart';
import 'package:smart_app_lock/security/credentials/verified_attempt.dart';
import 'package:smart_app_lock/security/pin_hasher.dart';
import 'package:smart_app_lock/services/biometric_service.dart';
import 'package:smart_app_lock/utilities/result.dart';

class _SpyObserver implements VerifiedAttemptObserver {
  final List<VerifiedAttempt> seen = <VerifiedAttempt>[];
  bool throwOnEach = false;

  @override
  void onVerifiedAttempt(VerifiedAttempt attempt) {
    seen.add(attempt);
    if (throwOnEach) {
      throw StateError('monitor exploded');
    }
  }
}

/// Settings repository that yields between load and save (widening every
/// race window) and can fail the next read once.
class _SlowSettings implements SecuritySettingsRepository {
  _SlowSettings(this._inner);
  final SecuritySettingsRepository _inner;
  bool failNextRead = false;

  @override
  Future<Result<SecuritySettings>> getSettings() async {
    await Future<void>.delayed(Duration.zero);
    if (failNextRead) {
      failNextRead = false;
      return Result.failure(StateError('read fault'));
    }
    final Result<SecuritySettings> r = await _inner.getSettings();
    await Future<void>.delayed(Duration.zero);
    return r;
  }

  @override
  Future<Result<void>> saveSettings(SecuritySettings settings) async {
    await Future<void>.delayed(Duration.zero);
    return _inner.saveSettings(settings);
  }

  @override
  Future<Result<bool>> hasPin() => _inner.hasPin();
}

/// Biometric prompt the test controls: completes when [gate] does.
class _GatedBiometrics implements BiometricService {
  Completer<Result<bool>> gate = Completer<Result<bool>>();
  int prompts = 0;

  @override
  Future<Result<bool>> isSupported() async => Result.success(true);

  @override
  Future<Result<Set<BiometricKind>>> availableKinds() async =>
      Result.success(<BiometricKind>{BiometricKind.strong});

  @override
  Future<Result<bool>> authenticate({
    required String reason,
    BiometricOptions? options,
  }) {
    prompts++;
    return gate.future;
  }
}

void main() {
  late _SlowSettings settings;
  late _SpyObserver observer;
  late _GatedBiometrics bio;
  late DefaultCredentialManager manager;
  DateTime now = DateTime(2026, 10, 22, 9);

  DefaultCredentialManager build({VerifiedAttemptObserver? obs}) =>
      DefaultCredentialManager(
        settings: settings,
        pinHasher: Pbkdf2PinHasher(iterations: 200),
        patternHasher: Pbkdf2PatternHasher(iterations: 200),
        // The production policy (AppContainer): 3 attempts, 30 s base.
        stateMachine: CredentialStateMachine(
          maxFailedAttempts: 3,
          lockoutDuration: const Duration(seconds: 30),
        ),
        biometricService: bio,
        now: () => now,
        attemptObserver: obs ?? observer,
      );

  Future<CredentialState> state() async =>
      (await manager.status()).valueOrNull!;

  setUp(() async {
    now = DateTime(2026, 10, 22, 9);
    settings = _SlowSettings(SecuritySettingsRepositoryImpl(
      InMemoryLocalDatabase(),
    ));
    observer = _SpyObserver();
    bio = _GatedBiometrics();
    manager = build();
    await manager.enrollPin('1234');
  });

  group('concurrent verifications are serialized (lost-update fix)', () {
    test('3 concurrent wrong PINs count 3 failures and trip the lockout',
        () async {
      final List<Result<AuthAttemptResult>> r = await Future.wait(
        <Future<Result<AuthAttemptResult>>>[
          manager.authenticatePin('0000'),
          manager.authenticatePin('1111'),
          manager.authenticatePin('2222'),
        ],
      );
      final List<AuthAttemptResult> v =
          r.map((Result<AuthAttemptResult> x) => x.valueOrNull!).toList();
      expect((v[0] as AuthFailure).remainingAttempts, 2);
      expect((v[1] as AuthFailure).remainingAttempts, 1);
      expect(v[2], isA<AuthLockedOut>());
      expect((v[2] as AuthLockedOut).attemptsMade, 3);
      final CredentialState s = await state();
      expect(s.failedAttempts, 3);
      expect(s.lockedOutUntil, now.add(const Duration(seconds: 30)));
      expect(s.lockoutStreak, 1);
    });

    test(
        'a burst of 6 concurrent wrong PINs creates ONE lockout; the rest '
        'are blocked without counting', () async {
      final List<Result<AuthAttemptResult>> r = await Future.wait(
        List<Future<Result<AuthAttemptResult>>>.generate(
          6,
          (int i) => manager.authenticatePin('000$i'),
        ),
      );
      final List<AuthLockedOut> lockouts = r
          .map((Result<AuthAttemptResult> x) => x.valueOrNull!)
          .whereType<AuthLockedOut>()
          .toList();
      expect(lockouts, hasLength(4));
      expect(lockouts.where((AuthLockedOut l) => l.attemptsMade != null),
          hasLength(1),
          reason: 'exactly one lockout was triggered');
      expect((await state()).lockoutStreak, 1, reason: 'no second lockout');
      expect(observer.seen, hasLength(3),
          reason: 'blocked attempts are not verifications');
    });

    test('concurrent PIN and pattern failures share the one counter', () async {
      await manager.enrollPattern(
        const <int>[1, 2, 3, 6],
        authorization: (await manager.verifyPinForCredentialChange('1234'))
            .valueOrNull!
            .authorization,
      );
      await manager.authenticatePattern(const <int>[1, 2, 3, 6]); // reset
      final List<Result<AuthAttemptResult>> r = await Future.wait(
        <Future<Result<AuthAttemptResult>>>[
          manager.authenticatePattern(const <int>[9, 8, 7, 4]),
          manager.authenticatePin('0000'),
          manager.authenticatePattern(const <int>[7, 8, 9, 6]),
        ],
      );
      expect(r.last.valueOrNull, isA<AuthLockedOut>());
      expect((await state()).failedAttempts, 3);
    });

    test('a success and a failure in flight together apply in call order',
        () async {
      await manager.authenticatePin('0000'); // 1 failure
      final List<Result<AuthAttemptResult>> r = await Future.wait(
        <Future<Result<AuthAttemptResult>>>[
          manager.authenticatePin('1234'),
          manager.authenticatePin('9999'),
        ],
      );
      expect(r[0].valueOrNull, isA<AuthSuccess>());
      expect((r[1].valueOrNull! as AuthFailure).remainingAttempts, 2);
      expect((await state()).failedAttempts, 1);
    });

    test('a concurrent preference write can no longer erase a lockout',
        () async {
      await manager.authenticatePin('0000');
      await manager.authenticatePin('1111');
      await Future.wait(<Future<Object?>>[
        manager.authenticatePin('2222'), // trips the lockout
        manager.setRandomizedKeypadEnabled(true), // stale-snapshot writer
      ]);
      final CredentialState s = await state();
      expect(s.lockedOutUntil, isNotNull, reason: 'lockout survived');
      expect(s.failedAttempts, 3);
      expect(s.randomizedKeypadEnabled, isTrue, reason: 'write also applied');
    });

    test('a failed read never wedges the lock', () async {
      settings.failNextRead = true;
      expect((await manager.authenticatePin('0000')).isFailure, isTrue);
      expect((await manager.authenticatePin('1234')).valueOrNull,
          isA<AuthSuccess>());
    });
  });

  group('biometric verdicts apply to the CURRENT counters', () {
    setUp(() async {
      await manager.updateBiometricOptions(BiometricOptions.defaults);
    });

    test(
        'a lockout that starts while the prompt is open blocks a late '
        'biometric success (it is not reset)', () async {
      final Future<Result<AuthAttemptResult>> pending =
          manager.authenticateBiometric();
      await pumpEventQueue();
      expect(bio.prompts, 1);
      for (final String pin in <String>['0000', '1111', '2222']) {
        await manager.authenticatePin(pin);
      }
      final DateTime? until = (await state()).lockedOutUntil;
      expect(until, isNotNull);

      bio.gate.complete(Result.success(true));
      final AuthAttemptResult r = (await pending).valueOrNull!;
      expect(r, isA<AuthLockedOut>());
      final CredentialState s = await state();
      expect(s.lockedOutUntil, until);
      expect(s.failedAttempts, 3);
    });

    test(
        'a biometric verdict no longer reverts writes made during the '
        'prompt (stale snapshot)', () async {
      final Future<Result<AuthAttemptResult>> pending =
          manager.authenticateBiometric();
      await pumpEventQueue();
      await manager.setPatternVisibilityEnabled(false);
      await manager.authenticatePin('0000');
      bio.gate.complete(Result.success(false)); // rejection: counted
      expect((await pending).valueOrNull, isA<AuthFailure>());
      final CredentialState s = await state();
      expect(s.patternVisibilityEnabled, isFalse);
      expect(s.failedAttempts, 2, reason: 'both failures counted');
    });

    test('an open biometric prompt never blocks PIN entry', () async {
      unawaited(manager.authenticateBiometric());
      await pumpEventQueue();
      expect((await manager.authenticatePin('1234')).valueOrNull,
          isA<AuthSuccess>());
    });

    test('H-3 unchanged: cancellation persists nothing and is not reported',
        () async {
      await manager.authenticatePin('0000');
      observer.seen.clear();
      final Future<Result<AuthAttemptResult>> pending =
          manager.authenticateBiometric();
      bio.gate.complete(Result.failure(
        const BiometricAuthException(code: 'userCanceled', message: 'x'),
      ));
      final AuthAttemptResult r = (await pending).valueOrNull!;
      expect((r as AuthFailure).reason, AuthFailureReason.cancelled);
      expect((await state()).failedAttempts, 1);
      expect(observer.seen, isEmpty);
    });

    test('hardware unavailable is not counted; an unknown platform error is',
        () async {
      Future<AuthAttemptResult> once(String code) async {
        bio.gate = Completer<Result<bool>>()
          ..complete(Result.failure(
            BiometricAuthException(code: code, message: 'x'),
          ));
        return (await manager.authenticateBiometric()).valueOrNull!;
      }

      expect(
          (await once('biometricHardwareTemporarilyUnavailable') as AuthFailure)
              .reason,
          AuthFailureReason.notAvailable);
      expect((await state()).failedAttempts, 0);
      expect(observer.seen, isEmpty);

      expect((await once('somethingElse') as AuthFailure).reason,
          AuthFailureReason.wrongCredential);
      expect((await state()).failedAttempts, 1);
      expect(observer.seen.single.type, AuthType.biometric);
      expect(observer.seen.single.matched, isFalse);
    });
  });

  group('zone safety (found by the full regression suite)', () {
    // Built in setUp — OUTSIDE the widget test's fake-async zone — over the
    // plain repository (no timers: fake time only advances on pump). An
    // earlier lock chained every caller onto a future created in another
    // zone and stalled forever here.
    late DefaultCredentialManager plain;
    late _SpyObserver spy;

    setUp(() async {
      spy = _SpyObserver();
      plain = DefaultCredentialManager(
        settings: SecuritySettingsRepositoryImpl(InMemoryLocalDatabase()),
        pinHasher: Pbkdf2PinHasher(iterations: 200),
        stateMachine: CredentialStateMachine(maxFailedAttempts: 3),
        attemptObserver: spy,
      );
      await plain.enrollPin('1234');
    });

    testWidgets(
        'calls from the fake-async zone and from runAsync interleave '
        'without stalling', (WidgetTester tester) async {
      await tester.runAsync(() async {
        await plain.authenticatePin('0000');
      });
      expect((await plain.authenticatePin('1111')).valueOrNull,
          isA<AuthFailure>());
      await tester.runAsync(() async {
        await plain.setRandomizedKeypadEnabled(true);
      });
      final AuthAttemptResult r =
          (await plain.authenticatePin('2222')).valueOrNull!;
      expect(r, isA<AuthLockedOut>());
      expect(
        (await plain.status()).valueOrNull!.randomizedKeypadEnabled,
        isTrue,
      );
      expect(spy.seen, hasLength(3));
    });
  });

  group('verified-attempt observer', () {
    test('one report per counted verification, after the counter write',
        () async {
      await manager.authenticatePin('0000');
      await manager.authenticatePin('1234');
      expect(observer.seen, hasLength(2));
      expect(observer.seen[0].matched, isFalse);
      expect(observer.seen[0].counterPersisted, isTrue);
      expect(observer.seen[0].result, isA<AuthFailure>());
      expect(observer.seen[1].result, isA<AuthSuccess>());
      expect(
        observer.seen[0].verificationId,
        isNot(observer.seen[1].verificationId),
      );
    });

    test(
        'no report for lockout-blocked attempts, missing credentials or '
        'storage failures', () async {
      for (final String pin in <String>['0000', '1111', '2222']) {
        await manager.authenticatePin(pin);
      }
      observer.seen.clear();
      expect((await manager.authenticatePin('1234')).valueOrNull,
          isA<AuthLockedOut>());
      // No pattern enrolled: reported as noCredentialEnrolled (existing
      // order of checks) — not a verification either way.
      expect(
          ((await manager.authenticatePattern(const <int>[1, 2, 3, 4]))
                  .valueOrNull! as AuthFailure)
              .reason,
          AuthFailureReason.noCredentialEnrolled);
      settings.failNextRead = true;
      await manager.authenticatePin('3333');
      expect(observer.seen, isEmpty);

      final DefaultCredentialManager fresh = DefaultCredentialManager(
        settings: SecuritySettingsRepositoryImpl(InMemoryLocalDatabase()),
        pinHasher: Pbkdf2PinHasher(iterations: 200),
        attemptObserver: observer,
      );
      expect(
          ((await fresh.authenticatePin('1234')).valueOrNull! as AuthFailure)
              .reason,
          AuthFailureReason.noCredentialEnrolled);
      expect(observer.seen, isEmpty);
    });

    test(
        'attribution is captured at the START of each call; overlapping '
        'calls with different contexts never mix', () async {
      const AuthAttemptContext a = AuthAttemptContext.protectedAppChallenge(
        packageName: 'com.a',
        generation: 1,
        challengeSerial: 1,
      );
      const AuthAttemptContext b = AuthAttemptContext.protectedAppChallenge(
        packageName: 'com.b',
        generation: 2,
        challengeSerial: 2,
      );
      await Future.wait(<Future<Object?>>[
        a.run(() => manager.authenticatePin('0000')),
        b.run(() => manager.authenticatePin('1111')),
        manager.authenticatePin('2222'),
      ]);
      expect(observer.seen.map((VerifiedAttempt v) => v.context.packageName),
          <String?>['com.a', 'com.b', null]);
      expect(observer.seen[2].context.surface, AuthAttemptSurface.smartAppLock);
    });

    test('verification ids are unique across manager instances (restart)',
        () async {
      await manager.authenticatePin('0000');
      final DefaultCredentialManager restarted = build();
      await restarted.authenticatePin('0000');
      final String first = observer.seen[0].verificationId;
      final String second = observer.seen[1].verificationId;
      expect(first.split(':').first, isNot(second.split(':').first));
    });

    test(
        'an observer that throws never changes a verdict: counting, '
        'lockout, cooldown and success all behave identically', () async {
      observer.throwOnEach = true;
      final AuthFailure f1 =
          (await manager.authenticatePin('0000')).valueOrNull! as AuthFailure;
      expect(f1.remainingAttempts, 2);
      await manager.authenticatePin('1111');
      final AuthLockedOut l =
          (await manager.authenticatePin('2222')).valueOrNull! as AuthLockedOut;
      expect(l.retryAt, now.add(const Duration(seconds: 30)));
      expect((await manager.authenticatePin('1234')).valueOrNull,
          isA<AuthLockedOut>(),
          reason: 'correct PIN still blocked');
      now = now.add(const Duration(seconds: 31));
      expect((await manager.authenticatePin('1234')).valueOrNull,
          isA<AuthSuccess>());
      expect(observer.seen, hasLength(4));
    });
  });
}
