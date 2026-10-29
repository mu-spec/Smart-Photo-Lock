// Phase 5 / Milestone 2 — Challenge host security hardening (HB-1).
//
// Unit tests for ChallengeAuthRecorder: one recorder per presented lock
// challenge. It forwards authentication unchanged, records only a genuine
// permitted success while open, closes exactly once, and refuses every
// mutation, write and CR-3 grant without touching the real manager.
//
// SIMULATED: pure Dart. No platform channel, APK or device involved.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/challenge_auth_recorder.dart';
import 'package:smart_app_lock/data/repositories/impl/security_settings_repository_impl.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/credentials/biometric_options.dart';
import 'package:smart_app_lock/security/credentials/credential_change_authorization.dart';
import 'package:smart_app_lock/security/credentials/credential_manager.dart';
import 'package:smart_app_lock/security/credentials/credential_state.dart';
import 'package:smart_app_lock/security/credentials/credential_state_machine.dart';
import 'package:smart_app_lock/security/credentials/impl/default_credential_manager.dart';
import 'package:smart_app_lock/security/credentials/pattern_hasher.dart';
import 'package:smart_app_lock/security/pin_hasher.dart';
import 'package:smart_app_lock/utilities/result.dart';

/// Records every call. Authentication and `status` answer from
/// configurable results; ANY other member (writes, enrollment, CR-3) is
/// recorded and throws, so a forwarded mutation can never go unnoticed.
class _SpyManager implements CredentialManager {
  final List<String> calls = <String>[];

  Result<AuthAttemptResult> pinResult =
      Result.success(const AuthSuccess(type: AuthType.pin));
  Result<AuthAttemptResult> patternResult =
      Result.success(const AuthSuccess(type: AuthType.pattern));
  Result<AuthAttemptResult> biometricResult =
      Result.success(const AuthSuccess(type: AuthType.biometric));

  /// When set, the next authentication waits on this completer instead.
  Completer<Result<AuthAttemptResult>>? hold;

  final Result<CredentialState> statusResult = Result.success(
    const CredentialState(
      enrolled: <AuthType>{AuthType.pin, AuthType.biometric},
      primary: AuthType.pin,
    ),
  );

  Future<Result<AuthAttemptResult>> _answer(
    Result<AuthAttemptResult> r,
  ) async {
    final Completer<Result<AuthAttemptResult>>? h = hold;
    if (h != null) {
      hold = null;
      return h.future;
    }
    return r;
  }

  @override
  Future<Result<CredentialState>> status() async {
    calls.add('status');
    return statusResult;
  }

  @override
  Future<Result<AuthAttemptResult>> authenticatePin(String pin) {
    calls.add('authenticatePin');
    return _answer(pinResult);
  }

  @override
  Future<Result<AuthAttemptResult>> authenticatePattern(List<int> nodes) {
    calls.add('authenticatePattern');
    return _answer(patternResult);
  }

  @override
  Future<Result<AuthAttemptResult>> authenticateBiometric({
    String reason = 'Unlock Smart App Lock',
  }) {
    calls.add('authenticateBiometric');
    return _answer(biometricResult);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add('FORWARDED:${invocation.memberName}');
    throw StateError('must never be forwarded: ${invocation.memberName}');
  }
}

DefaultCredentialManager _realManager() => DefaultCredentialManager(
      settings: SecuritySettingsRepositoryImpl(InMemoryLocalDatabase()),
      pinHasher: Pbkdf2PinHasher(iterations: 200),
      patternHasher: Pbkdf2PatternHasher(iterations: 200),
      stateMachine: CredentialStateMachine(
        maxFailedAttempts: 3,
        lockoutDuration: const Duration(seconds: 30),
      ),
    );

const List<int> _pattern = <int>[1, 2, 3, 6, 9];

void main() {
  group('close is one-shot', () {
    test('a recorded success is reported once; every later close is false',
        () async {
      final _SpyManager spy = _SpyManager();
      final ChallengeAuthRecorder r = ChallengeAuthRecorder.forPinRoute(spy);
      expect(r.isOpen, isTrue);
      await r.authenticatePin('1234');
      expect(r.close(), isTrue);
      expect(r.isOpen, isFalse);
      expect(r.close(), isFalse);
      expect(r.close(), isFalse);
    });

    test('closing without a success reports false', () {
      final ChallengeAuthRecorder r =
          ChallengeAuthRecorder.forPinRoute(_SpyManager());
      expect(r.close(), isFalse);
      expect(r.isOpen, isFalse);
    });

    test('after close every authentication is refused without reaching the '
        'real manager, and nothing can be recorded', () async {
      final _SpyManager spy = _SpyManager();
      final ChallengeAuthRecorder pin = ChallengeAuthRecorder.forPinRoute(spy);
      final ChallengeAuthRecorder pat =
          ChallengeAuthRecorder.forPatternRoute(spy);
      pin.close();
      pat.close();
      expect((await pin.authenticatePin('1234')).isFailure, isTrue);
      expect((await pin.authenticateBiometric()).isFailure, isTrue);
      expect((await pat.authenticatePattern(_pattern)).isFailure, isTrue);
      expect((await pat.authenticateBiometric()).isFailure, isTrue);
      expect(spy.calls, isEmpty);
      expect(pin.close(), isFalse);
      expect(pat.close(), isFalse);
    });

    test('a success after a recorded one cannot be consumed twice', () async {
      final ChallengeAuthRecorder r =
          ChallengeAuthRecorder.forPinRoute(_SpyManager());
      await r.authenticatePin('1234');
      await r.authenticateBiometric();
      expect(r.close(), isTrue);
      expect(r.close(), isFalse);
    });
  });

  group('late and foreign results', () {
    test('a verification that finishes after close is never recorded (the '
        'caller still sees the delegate result unchanged)', () async {
      final _SpyManager spy = _SpyManager();
      final Completer<Result<AuthAttemptResult>> late =
          Completer<Result<AuthAttemptResult>>();
      spy.hold = late;
      final ChallengeAuthRecorder r = ChallengeAuthRecorder.forPinRoute(spy);
      final Future<Result<AuthAttemptResult>> pending =
          r.authenticatePin('1234');
      expect(r.close(), isFalse); // route completed before the result
      late.complete(Result.success(const AuthSuccess(type: AuthType.pin)));
      final Result<AuthAttemptResult> seen = await pending;
      expect(seen.valueOrNull, isA<AuthSuccess>());
      expect(r.close(), isFalse);
    });

    test('a late biometric success after close is never recorded', () async {
      final _SpyManager spy = _SpyManager();
      final Completer<Result<AuthAttemptResult>> late =
          Completer<Result<AuthAttemptResult>>();
      spy.hold = late;
      final ChallengeAuthRecorder r =
          ChallengeAuthRecorder.forPatternRoute(spy);
      final Future<Result<AuthAttemptResult>> pending =
          r.authenticateBiometric();
      r.close();
      late.complete(
        Result.success(const AuthSuccess(type: AuthType.biometric)),
      );
      await pending;
      expect(r.close(), isFalse);
    });

    test('recorders are independent: one challenge success never satisfies '
        'another (earlier or later) challenge', () async {
      final _SpyManager spy = _SpyManager();
      final ChallengeAuthRecorder first = ChallengeAuthRecorder.forPinRoute(spy);
      final ChallengeAuthRecorder second =
          ChallengeAuthRecorder.forPinRoute(spy);
      final Completer<Result<AuthAttemptResult>> late =
          Completer<Result<AuthAttemptResult>>();
      spy.hold = late;
      final Future<Result<AuthAttemptResult>> firstPending =
          first.authenticatePin('1234');
      expect(first.close(), isFalse); // first challenge dismissed
      late.complete(Result.success(const AuthSuccess(type: AuthType.pin)));
      await firstPending;
      expect(second.close(), isFalse); // nothing happened on the second

      final ChallengeAuthRecorder third = ChallengeAuthRecorder.forPinRoute(spy);
      await third.authenticatePin('1234');
      final ChallengeAuthRecorder fourth =
          ChallengeAuthRecorder.forPinRoute(spy);
      expect(fourth.close(), isFalse);
      expect(third.close(), isTrue);
    });
  });

  group('only a genuine permitted success is recorded', () {
    test('the PIN route refuses pattern without calling the real manager',
        () async {
      final _SpyManager spy = _SpyManager();
      final ChallengeAuthRecorder r = ChallengeAuthRecorder.forPinRoute(spy);
      expect(r.permittedTypes, <AuthType>{AuthType.pin, AuthType.biometric});
      expect((await r.authenticatePattern(_pattern)).isFailure, isTrue);
      expect(spy.calls, isEmpty);
      expect(r.close(), isFalse);
    });

    test('the pattern route refuses PIN without calling the real manager',
        () async {
      final _SpyManager spy = _SpyManager();
      final ChallengeAuthRecorder r =
          ChallengeAuthRecorder.forPatternRoute(spy);
      expect(r.permittedTypes, <AuthType>{AuthType.pattern, AuthType.biometric});
      expect((await r.authenticatePin('1234')).isFailure, isTrue);
      expect(spy.calls, isEmpty);
      expect(r.close(), isFalse);
    });

    test('a recorder with no biometric permission refuses biometric without '
        'prompting', () async {
      final _SpyManager spy = _SpyManager();
      final ChallengeAuthRecorder r = ChallengeAuthRecorder(
        spy,
        permittedTypes: const <AuthType>{AuthType.pin},
      );
      expect((await r.authenticateBiometric()).isFailure, isTrue);
      expect(spy.calls, isEmpty);
      expect(r.close(), isFalse);
    });

    test('permitted biometric success is recorded on both routes', () async {
      final ChallengeAuthRecorder pin =
          ChallengeAuthRecorder.forPinRoute(_SpyManager());
      final ChallengeAuthRecorder pat =
          ChallengeAuthRecorder.forPatternRoute(_SpyManager());
      await pin.authenticateBiometric();
      await pat.authenticateBiometric();
      expect(pin.close(), isTrue);
      expect(pat.close(), isTrue);
    });

    test('a success whose type does not match the method is not recorded',
        () async {
      final _SpyManager spy = _SpyManager()
        ..pinResult =
            Result.success(const AuthSuccess(type: AuthType.biometric))
        ..biometricResult =
            Result.success(const AuthSuccess(type: AuthType.pin))
        ..patternResult = Result.success(const AuthSuccess(type: AuthType.pin));
      final ChallengeAuthRecorder pin = ChallengeAuthRecorder.forPinRoute(spy);
      await pin.authenticatePin('1234');
      await pin.authenticateBiometric();
      expect(pin.close(), isFalse);
      final ChallengeAuthRecorder pat =
          ChallengeAuthRecorder.forPatternRoute(spy);
      await pat.authenticatePattern(_pattern);
      expect(pat.close(), isFalse);
    });

    test('biometric failure, cancellation, lockout and service failure are '
        'never recorded and are passed through unchanged', () async {
      final List<Result<AuthAttemptResult>> outcomes =
          <Result<AuthAttemptResult>>[
        Result.success(const AuthFailure(
          reason: AuthFailureReason.cancelled,
          remainingAttempts: 3,
        )),
        Result.success(const AuthFailure(
          reason: AuthFailureReason.wrongCredential,
          remainingAttempts: 2,
        )),
        Result.success(const AuthFailure(
          reason: AuthFailureReason.notAvailable,
          remainingAttempts: 0,
        )),
        Result.success(AuthLockedOut(retryAt: DateTime(2026, 10, 29, 12))),
        Result.failure(StateError('bridge failure')),
      ];
      for (final Result<AuthAttemptResult> o in outcomes) {
        final _SpyManager spy = _SpyManager()..biometricResult = o;
        final ChallengeAuthRecorder r = ChallengeAuthRecorder.forPinRoute(spy);
        expect(identical(await r.authenticateBiometric(), o), isTrue);
        expect(r.close(), isFalse, reason: '$o must not be recorded');
      }
    });

    test('PIN / pattern failures are never recorded', () async {
      final Result<AuthAttemptResult> wrong = Result.success(
        const AuthFailure(
          reason: AuthFailureReason.wrongCredential,
          remainingAttempts: 2,
        ),
      );
      final _SpyManager spy = _SpyManager()
        ..pinResult = wrong
        ..patternResult = wrong;
      final ChallengeAuthRecorder pin = ChallengeAuthRecorder.forPinRoute(spy);
      final ChallengeAuthRecorder pat =
          ChallengeAuthRecorder.forPatternRoute(spy);
      await pin.authenticatePin('0000');
      await pat.authenticatePattern(_pattern);
      expect(pin.close(), isFalse);
      expect(pat.close(), isFalse);
    });
  });

  group('mutations and writes are refused, reads are delegated', () {
    test('status is delegated unchanged (the same result object)', () async {
      final _SpyManager spy = _SpyManager();
      final ChallengeAuthRecorder r = ChallengeAuthRecorder.forPinRoute(spy);
      expect(identical(await r.status(), spy.statusResult), isTrue);
      expect(spy.calls, <String>['status']);
    });

    test('enrollment, settings writes, clearAll and the CR-3 grant API are '
        'refused and never forwarded, open or closed', () async {
      for (final bool closeFirst in <bool>[false, true]) {
        final _SpyManager spy = _SpyManager();
        final ChallengeAuthRecorder r = ChallengeAuthRecorder.forPinRoute(spy);
        if (closeFirst) r.close();
        expect((await r.enrollPin('5678')).isFailure, isTrue);
        expect((await r.enrollPattern(_pattern)).isFailure, isTrue);
        expect(
          (await r.updateBiometricOptions(BiometricOptions.defaults))
              .isFailure,
          isTrue,
        );
        expect((await r.updateBiometricOptions(null)).isFailure, isTrue);
        expect((await r.setRandomizedKeypadEnabled(true)).isFailure, isTrue);
        expect((await r.setPatternVisibilityEnabled(false)).isFailure, isTrue);
        expect((await r.clearAll()).isFailure, isTrue);
        expect(
          (await r.verifyPinForCredentialChange('1234')).isFailure,
          isTrue,
        );
        expect(
          (await r.verifyPatternForCredentialChange(_pattern)).isFailure,
          isTrue,
        );
        r.revokeCredentialChangeAuthorization(
          CredentialChangeAuthorization.handle(method: AuthType.pin),
        );
        expect(spy.calls, isEmpty, reason: 'closeFirst=$closeFirst');
        expect(r.close(), isFalse);
      }
    });

    test('refused writes leave the real manager untouched', () async {
      final DefaultCredentialManager real = _realManager();
      await real.enrollPin('1234');
      final ChallengeAuthRecorder r = ChallengeAuthRecorder.forPinRoute(real);
      await r.enrollPin('5678');
      await r.clearAll();
      await r.setRandomizedKeypadEnabled(true);
      final CredentialState s = (await real.status()).valueOrNull!;
      expect(s.hasEnrolled(AuthType.pin), isTrue);
      expect(s.randomizedKeypadEnabled, isFalse);
      // The original PIN still authenticates, the "new" one does not.
      final ChallengeAuthRecorder check =
          ChallengeAuthRecorder.forPinRoute(real);
      expect((await check.authenticatePin('5678')).valueOrNull,
          isA<AuthFailure>());
      expect((await check.authenticatePin('1234')).valueOrNull,
          isA<AuthSuccess>());
    });
  });

  group('real manager: counting and lockout are preserved', () {
    test('wrong PINs are counted by the real manager and reach lockout; a '
        'correct PIN during lockout is not recorded', () async {
      final DefaultCredentialManager real = _realManager();
      await real.enrollPin('1234');
      final ChallengeAuthRecorder r = ChallengeAuthRecorder.forPinRoute(real);
      final AuthAttemptResult? first =
          (await r.authenticatePin('0000')).valueOrNull;
      expect(first, isA<AuthFailure>());
      expect((first! as AuthFailure).remainingAttempts, 2);
      expect((await real.status()).valueOrNull!.failedAttempts, 1);
      await r.authenticatePin('0000');
      final AuthAttemptResult? third =
          (await r.authenticatePin('0000')).valueOrNull;
      expect(third, isA<AuthLockedOut>());
      expect((await real.status()).valueOrNull!.lockedOutUntil, isNotNull);
      expect((await r.authenticatePin('1234')).valueOrNull,
          isA<AuthLockedOut>());
      expect(r.close(), isFalse);
    });

    test('attempts made through different recorders share ONE counter (a '
        'new challenge does not reset the attempt budget)', () async {
      final DefaultCredentialManager real = _realManager();
      await real.enrollPin('1234');
      await ChallengeAuthRecorder.forPinRoute(real).authenticatePin('0000');
      await ChallengeAuthRecorder.forPinRoute(real).authenticatePin('0000');
      final AuthAttemptResult? third =
          (await ChallengeAuthRecorder.forPinRoute(real).authenticatePin('0000'))
              .valueOrNull;
      expect(third, isA<AuthLockedOut>());
    });

    test('a real correct PIN and a real correct pattern are recorded once',
        () async {
      final DefaultCredentialManager pinReal = _realManager();
      await pinReal.enrollPin('1234');
      final ChallengeAuthRecorder pin =
          ChallengeAuthRecorder.forPinRoute(pinReal);
      expect((await pin.authenticatePin('1234')).valueOrNull,
          isA<AuthSuccess>());
      expect(pin.close(), isTrue);
      expect(pin.close(), isFalse);

      final DefaultCredentialManager patReal = _realManager();
      await patReal.enrollPattern(_pattern);
      final ChallengeAuthRecorder pat =
          ChallengeAuthRecorder.forPatternRoute(patReal);
      expect((await pat.authenticatePattern(_pattern)).valueOrNull,
          isA<AuthSuccess>());
      expect(pat.close(), isTrue);
      expect(pat.close(), isFalse);
    });

    test('biometric with no biometric service wired is a real notAvailable '
        'failure and is not recorded', () async {
      final DefaultCredentialManager real = _realManager();
      await real.enrollPin('1234');
      final ChallengeAuthRecorder r = ChallengeAuthRecorder.forPinRoute(real);
      expect((await r.authenticateBiometric()).valueOrNull,
          isA<AuthFailure>());
      expect(r.close(), isFalse);
    });
  });
}
