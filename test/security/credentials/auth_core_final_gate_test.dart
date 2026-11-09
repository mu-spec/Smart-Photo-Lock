// Phase 12 / Milestone 1 — FINAL AUTH-CORE SECURITY GATE (adversarial).
//
// Gate A  serialization: one lock for every credential-settings
//         read-modify-write; no lost counter update; no preference write
//         can overwrite a newer cooldown/lockout; a throwing operation never
//         wedges the queue; no nested acquisition; callers from any zone; an
//         open biometric prompt never holds the lock.
// Gate B  biometric fresh state: a prompt that started before a credential
//         change, credential clearing, biometric disablement or lockout can
//         never authorize after it; preference writes made during the
//         prompt survive; cancellation / unavailability are unchanged.
// Gate C  observer isolation: monitor storage failure, observer exceptions
//         and monitor queue saturation change no verdict, no lockout, no
//         cooldown and no native protection decision.
//
// SIMULATED: Dart VM + Flutter widget tests with in-memory storage, fake
// biometric prompt and the static platform fakes. NOT device tests — no
// APK, no native shield, no biometric hardware.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app.dart';
import 'package:smart_app_lock/app/app_container.dart';
import 'package:smart_app_lock/app/challenge_auth_recorder.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/data/models/protected_app.dart';
import 'package:smart_app_lock/data/models/security_settings.dart';
import 'package:smart_app_lock/data/repositories/impl/security_settings_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/security_settings_repository.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/protection/impl/default_access_controller.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/credentials/biometric_options.dart';
import 'package:smart_app_lock/security/credentials/credential_change_authorization.dart';
import 'package:smart_app_lock/security/credentials/credential_state.dart';
import 'package:smart_app_lock/security/credentials/credential_state_machine.dart';
import 'package:smart_app_lock/security/credentials/impl/default_credential_manager.dart';
import 'package:smart_app_lock/security/credentials/pattern_hasher.dart';
import 'package:smart_app_lock/security/credentials/verified_attempt.dart';
import 'package:smart_app_lock/security/intruder/intruder_failure_log_store.dart';
import 'package:smart_app_lock/security/intruder/intruder_monitor.dart';
import 'package:smart_app_lock/security/pin_hasher.dart';
import 'package:smart_app_lock/services/biometric_service.dart';
import 'package:smart_app_lock/services/impl/static_accessibility_lock_service.dart';
import 'package:smart_app_lock/services/impl/static_installed_apps_service.dart';
import 'package:smart_app_lock/services/impl/static_watcher_service.dart';
import 'package:smart_app_lock/ui/screens/pin/pin_unlock_screen.dart';
import 'package:smart_app_lock/utilities/result.dart';

// ---------------------------------------------------------------------------
// fakes
// ---------------------------------------------------------------------------

/// Settings repository that measures how many repository calls are in
/// flight at once and yields inside every call (maximal interleaving).
class _OverlapProbe implements SecuritySettingsRepository {
  _OverlapProbe(this._inner);
  final SecuritySettingsRepository _inner;
  int inFlight = 0;
  int maxInFlight = 0;

  Future<T> _probe<T>(Future<T> Function() call) async {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await Future<void>.delayed(Duration.zero);
      final T r = await call();
      await Future<void>.delayed(Duration.zero);
      return r;
    } finally {
      inFlight--;
    }
  }

  @override
  Future<Result<SecuritySettings>> getSettings() => _probe(_inner.getSettings);

  @override
  Future<Result<void>> saveSettings(SecuritySettings settings) =>
      _probe(() => _inner.saveSettings(settings));

  @override
  Future<Result<bool>> hasPin() => _inner.hasPin();
}

/// Repository that THROWS (not a Result failure) on demand.
class _ThrowingSettings implements SecuritySettingsRepository {
  _ThrowingSettings(this._inner);
  final SecuritySettingsRepository _inner;
  int throwReads = 0;
  int throwWrites = 0;

  @override
  Future<Result<SecuritySettings>> getSettings() async {
    await Future<void>.delayed(Duration.zero);
    if (throwReads > 0) {
      throwReads--;
      throw StateError('repository read exploded');
    }
    return _inner.getSettings();
  }

  @override
  Future<Result<void>> saveSettings(SecuritySettings settings) async {
    await Future<void>.delayed(Duration.zero);
    if (throwWrites > 0) {
      throwWrites--;
      throw StateError('repository write exploded');
    }
    return _inner.saveSettings(settings);
  }

  @override
  Future<Result<bool>> hasPin() => _inner.hasPin();
}

/// PIN hasher whose verify THROWS for the next [throwVerifies] calls.
class _ThrowingPinHasher implements PinHasher {
  final Pbkdf2PinHasher _inner = Pbkdf2PinHasher(iterations: 200);
  int throwVerifies = 0;

  @override
  Future<PinHash> hash(String pin) => _inner.hash(pin);

  @override
  Future<bool> verify(String pin, PinHash stored) async {
    await Future<void>.delayed(Duration.zero);
    if (throwVerifies > 0) {
      throwVerifies--;
      throw StateError('hasher exploded');
    }
    return _inner.verify(pin, stored);
  }
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

class _SpyObserver implements VerifiedAttemptObserver {
  final List<VerifiedAttempt> seen = <VerifiedAttempt>[];
  bool throwOnEach = false;
  void Function(VerifiedAttempt)? onEach;

  @override
  void onVerifiedAttempt(VerifiedAttempt attempt) {
    seen.add(attempt);
    onEach?.call(attempt);
    if (throwOnEach) throw StateError('observer exploded');
  }
}

/// Intruder storage whose WRITES never complete (reads see an empty log):
/// the monitor's queue fills and then saturates.
class _HangingIntruderDb extends InMemoryLocalDatabase {
  @override
  Future<String?> getSetting(String key) async {
    if (key.startsWith(IntruderFailureLogStore.storageKey)) return null;
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) {
    if (key.startsWith(IntruderFailureLogStore.storageKey)) {
      return Completer<void>().future; // never completes
    }
    return super.setSetting(key, value);
  }
}

/// Intruder storage that throws on every access.
class _BrokenIntruderDb extends InMemoryLocalDatabase {
  @override
  Future<String?> getSetting(String key) async {
    if (key.startsWith(IntruderFailureLogStore.storageKey)) {
      throw StateError('intruder storage fault');
    }
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) async {
    if (key.startsWith(IntruderFailureLogStore.storageKey)) {
      throw StateError('intruder storage fault');
    }
    return super.setSetting(key, value);
  }
}

/// Fills [monitor]'s bounded queue beyond capacity with synthetic counted
/// failures (direct observer calls, as a flood of verifications would).
void _saturate(IntruderMonitor monitor, {int count = 80}) {
  for (int i = 0; i < count; i++) {
    monitor.onVerifiedAttempt(VerifiedAttempt(
      verificationId: 'flood-$i',
      type: AuthType.pin,
      matched: false,
      result: const AuthFailure(
        reason: AuthFailureReason.wrongCredential,
        remainingAttempts: 2,
      ),
      counterPersisted: true,
      lockoutStreak: 0,
      context: AuthAttemptContext.smartAppLock,
      at: DateTime(2026, 10, 22, 8),
    ));
  }
}

// ---------------------------------------------------------------------------
// static source helpers (Gate A.1 / A.5)
// ---------------------------------------------------------------------------

const String _managerPath =
    'lib/security/credentials/impl/default_credential_manager.dart';

/// Member name -> member source text, for the DefaultCredentialManager class.
Map<String, String> _managerMembers() {
  final String src = File(_managerPath).readAsStringSync();
  final int start = src.indexOf('class DefaultCredentialManager');
  final int end = src.indexOf('\n}\n', start);
  final String body = src.substring(start, end);
  final RegExp header = RegExp(
    r'^  (?:static )?(?:Future<[^\n]*>|[A-Z]\w*(?:<[^\n]*>)?\??|void|bool|int)'
    r'\s+(\w+)\s*[(<]',
    multiLine: true,
  );
  final List<RegExpMatch> hs = header.allMatches(body).toList();
  final Map<String, String> out = <String, String>{};
  for (int i = 0; i < hs.length; i++) {
    final int to = i + 1 < hs.length ? hs[i + 1].start : body.length;
    out[hs[i].group(1)!] = body.substring(hs[i].start, to);
  }
  return out;
}

/// Text after the member's first `=>` (expression-bodied members).
String _afterArrow(String member) {
  final int i = member.indexOf('=>');
  return i < 0 ? '' : member.substring(i + 2).trimLeft();
}

void main() {
  final DateTime t0 = DateTime(2026, 10, 22, 9);

  // -------------------------------------------------------------------------
  group('Gate A.1/A.5 — static lock structure', () {
    late Map<String, String> m;
    setUpAll(() => m = _managerMembers());

    const List<String> lockedPublic = <String>[
      'enrollPin',
      'enrollPattern',
      'updateBiometricOptions',
      'setRandomizedKeypadEnabled',
      'setPatternVisibilityEnabled',
      'authenticatePin',
      'authenticatePattern',
      'clearAll',
    ];

    test(
        'every public mutating method takes the lock as its whole body '
        '(`=> _lock.run(...)`, or only an attribution capture before '
        '`return _lock.run(...)`)', () {
      final RegExp captureThenLock = RegExp(
        r'\{\s*(?://[^\n]*\n\s*)*'
        r'final AuthAttemptContext context = AuthAttemptContext\.current;'
        r'\s*return _lock\.run\(\(\) => _\w+Locked\([^;]*\);\s*\}\s*$',
      );
      for (final String name in lockedPublic) {
        expect(m[name], isNotNull, reason: name);
        final String member = m[name]!;
        final bool arrow = _afterArrow(member).startsWith('_lock.run(');
        final bool capture = captureThenLock.hasMatch(member.trimRight());
        expect(arrow || capture, isTrue,
            reason: '$name must take the lock as its whole body');
      }
      expect(
          captureThenLock.hasMatch(m['authenticatePin']!.trimRight()), isTrue);
      expect(captureThenLock.hasMatch(m['authenticatePattern']!.trimRight()),
          isTrue);
      expect(
          _afterArrow(m['_evaluateLatestAndPersist']!).startsWith('_lock.run('),
          isTrue);
    });

    test('the lock is acquired ONLY in those members', () {
      final Set<String> acquirers = m.entries
          .where((MapEntry<String, String> e) => e.value.contains('_lock.run('))
          .map((MapEntry<String, String> e) => e.key)
          .toSet();
      expect(acquirers, <String>{...lockedPublic, '_evaluateLatestAndPersist'});
    });

    test('every settings / PIN-store write happens in a locked body', () {
      const Set<String> lockedBodies = <String>{
        '_enrollPinLocked',
        '_enrollPatternLocked',
        'updateBiometricOptions',
        'setRandomizedKeypadEnabled',
        'setPatternVisibilityEnabled',
        '_clearAllLocked',
        '_evaluateAndPersist',
      };
      final RegExp write = RegExp(r'saveSettings\(|_pinStore\.(save|delete)\(');
      for (final MapEntry<String, String> e in m.entries) {
        if (write.hasMatch(e.value)) {
          expect(lockedBodies, contains(e.key),
              reason: '${e.key} writes credential settings');
        }
      }
      // `_xLocked` helpers are only ever invoked as a `_lock.run` body.
      final Map<String, String> all = m;
      for (final String helper in all.keys
          .where((String k) => k.startsWith('_') && k.endsWith('Locked'))) {
        for (final MapEntry<String, String> e in all.entries) {
          if (e.key == helper) continue;
          for (final String line in e.value.split('\n')) {
            if (line.contains('$helper(')) {
              expect(line.contains('_lock.run('), isTrue,
                  reason: '$helper called outside _lock.run in ${e.key}');
            }
          }
        }
      }
      // _evaluateAndPersist is reached only from locked bodies.
      final Set<String> callers = all.entries
          .where((MapEntry<String, String> e) =>
              e.key != '_evaluateAndPersist' &&
              e.value.contains('_evaluateAndPersist('))
          .map((MapEntry<String, String> e) => e.key)
          .toSet();
      expect(callers, <String>{
        '_authenticatePinLocked',
        '_authenticatePatternLocked',
        '_evaluateLatestAndPersist',
      });
    });

    test('no locked body re-acquires the lock (no nested acquisition)', () {
      final RegExp acquire = RegExp(
        r'(?<![\w.])(?:_lock\.run|authenticatePin|authenticatePattern|'
        r'authenticateBiometric|enrollPin|enrollPattern|updateBiometricOptions|'
        r'setRandomizedKeypadEnabled|setPatternVisibilityEnabled|clearAll|'
        r'verifyPinForCredentialChange|verifyPatternForCredentialChange|'
        r'_evaluateLatestAndPersist)\(',
      );
      final Iterable<MapEntry<String, String>> lockedHelpers = m.entries.where(
          (MapEntry<String, String> e) =>
              e.key.endsWith('Locked') || e.key == '_evaluateAndPersist');
      expect(lockedHelpers.length, greaterThanOrEqualTo(5));
      for (final MapEntry<String, String> e in lockedHelpers) {
        // Skip the member's own header line.
        final String body = e.value.substring(e.value.indexOf('\n'));
        expect(acquire.hasMatch(body), isFalse, reason: e.key);
      }
      // Inline locked bodies: everything after the single `_lock.run(`.
      for (final String name in <String>[
        'updateBiometricOptions',
        'setRandomizedKeypadEnabled',
        'setPatternVisibilityEnabled',
        '_evaluateLatestAndPersist',
      ]) {
        final String inner =
            _afterArrow(m[name]!).substring('_lock.run('.length);
        expect(acquire.hasMatch(inner), isFalse, reason: name);
      }
      // The biometric prompt itself is awaited OUTSIDE the lock.
      expect(m['authenticateBiometric']!.contains('_lock.run('), isFalse);
    });

    test('nothing else in lib/ writes the credential document', () {
      final List<String> offenders = <String>[];
      for (final FileSystemEntity f
          in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final String p = f.path.replaceAll('\\', '/');
        final String s = f.readAsStringSync();
        const Set<String> repoFiles = <String>{
          'lib/data/repositories/security_settings_repository.dart',
          'lib/data/repositories/impl/security_settings_repository_impl.dart',
        };
        if (s.contains('saveSettings(') &&
            !repoFiles.contains(p) &&
            p != _managerPath &&
            p !=
                'lib/security/credentials/impl/'
                    'default_pin_credential_store.dart') {
          offenders.add('saveSettings: $p');
        }
        if (s.contains('DefaultPinCredentialStore(') &&
            !p.endsWith('default_pin_credential_store.dart') &&
            p != _managerPath &&
            p != 'lib/app/app_container.dart') {
          offenders.add('pin store: $p');
        }
        if (RegExp(r'\.securitySettings\b').hasMatch(s) &&
            p != 'lib/app/app_container.dart') {
          offenders.add('container.securitySettings: $p');
        }
      }
      expect(offenders, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('Gate A — runtime serialization', () {
    DefaultCredentialManager build(
      SecuritySettingsRepository settings, {
      PinHasher? pinHasher,
      BiometricService? bio,
      VerifiedAttemptObserver? observer,
      DateTime Function()? now,
    }) =>
        DefaultCredentialManager(
          settings: settings,
          pinHasher: pinHasher ?? Pbkdf2PinHasher(iterations: 200),
          patternHasher: Pbkdf2PatternHasher(iterations: 200),
          stateMachine: CredentialStateMachine(
            maxFailedAttempts: 3,
            lockoutDuration: const Duration(seconds: 30),
          ),
          biometricService: bio ?? _GatedBiometrics(),
          now: now ?? () => t0,
          attemptObserver: observer,
        );

    test('the overlap probe itself detects unserialized access', () async {
      final _OverlapProbe probe = _OverlapProbe(
          SecuritySettingsRepositoryImpl(InMemoryLocalDatabase()));
      await Future.wait(<Future<Object?>>[
        probe.getSettings(),
        probe.getSettings(),
      ]);
      expect(probe.maxInFlight, 2);
    });

    test(
        'A.1: every mutator fired concurrently — never more than ONE '
        'repository call in flight', () async {
      final _OverlapProbe probe = _OverlapProbe(
          SecuritySettingsRepositoryImpl(InMemoryLocalDatabase()));
      final DefaultCredentialManager mgr = build(probe);
      await mgr.enrollPin('1234');
      final CredentialChangeAuthorization grant =
          (await mgr.verifyPinForCredentialChange('1234'))
              .valueOrNull!
              .authorization!;
      probe.maxInFlight = 0;
      await Future.wait(<Future<Object?>>[
        mgr.authenticatePin('0000'),
        mgr.setRandomizedKeypadEnabled(true),
        mgr.enrollPattern(const <int>[1, 2, 3, 6], authorization: grant),
        mgr.updateBiometricOptions(BiometricOptions.defaults),
        mgr.authenticatePattern(const <int>[7, 8, 9, 6]),
        mgr.setPatternVisibilityEnabled(false),
        mgr.authenticatePin('1111'),
        mgr.updateBiometricOptions(null),
        mgr.clearAll(),
      ]).timeout(const Duration(seconds: 20));
      expect(probe.maxInFlight, 1);
    });

    test(
        'A.1: callers arriving exactly at a lock handoff wait their turn '
        '(no barging past a queued waiter)', () async {
      final _OverlapProbe probe = _OverlapProbe(
          SecuritySettingsRepositoryImpl(InMemoryLocalDatabase()));
      final DefaultCredentialManager mgr = build(probe);
      await mgr.enrollPin('1234');
      probe.maxInFlight = 0;
      final List<Future<Object?>> arrivals = <Future<Object?>>[];
      Future<Object?> chain(Future<Object?> f) => f.then((Object? r) {
            // Runs right after the holder released: a newcomer arrives
            // while the next queued waiter is being handed the lock.
            arrivals
              ..add(mgr.setRandomizedKeypadEnabled(true))
              ..add(mgr.authenticatePin('1111'));
            return r;
          });
      await Future.wait(<Future<Object?>>[
        chain(mgr.authenticatePin('0000')),
        mgr.setPatternVisibilityEnabled(false),
        chain(mgr.updateBiometricOptions(BiometricOptions.defaults)),
        mgr.authenticatePin('2222'),
      ]).timeout(const Duration(seconds: 10));
      await Future.wait(arrivals).timeout(const Duration(seconds: 10));
      expect(probe.maxInFlight, 1);
      final CredentialState s = (await mgr.status()).valueOrNull!;
      expect(s.lockedOutUntil, isNotNull, reason: '3 counted failures');
      expect(s.randomizedKeypadEnabled, isTrue);
    });

    test(
        'A.2: 3 concurrent wrong PINs on the PRODUCTION container count 3 '
        'failures, trip the 30 s cooldown and are all recorded', () async {
      final AppContainer c = AppContainer.inMemory();
      await c.auth.enrollPin('1234');
      final List<Result<AuthAttemptResult>> r =
          await Future.wait(<Future<Result<AuthAttemptResult>>>[
        c.auth.authenticatePin('0000'),
        c.auth.authenticatePin('1111'),
        c.auth.authenticatePin('2222'),
      ]);
      expect(r.map((Result<AuthAttemptResult> x) => x.valueOrNull),
          everyElement(isNot(isA<AuthSuccess>())));
      expect(r.last.valueOrNull, isA<AuthLockedOut>());
      final CredentialState s = (await c.auth.status()).valueOrNull!;
      expect(s.lockedOutUntil, isNotNull);
      expect(s.lockoutStreak, 1);
      expect((await c.auth.authenticatePin('1234')).valueOrNull,
          isA<AuthLockedOut>());
      await c.intruderMonitor.idle();
      expect((await c.intruderMonitor.snapshot())!.events, hasLength(3));
    });

    for (final String writer in <String>[
      'randomizedKeypad',
      'patternVisibility',
      'biometricOptions',
    ]) {
      for (final bool writerFirst in <bool>[true, false]) {
        test(
            'A.3: $writer write racing the lockout-triggering attempt '
            '(${writerFirst ? 'writer first' : 'attempt first'}) — lockout '
            'and preference both survive', () async {
          final SecuritySettingsRepositoryImpl repo =
              SecuritySettingsRepositoryImpl(InMemoryLocalDatabase());
          final DefaultCredentialManager mgr = build(_OverlapProbe(repo));
          await mgr.enrollPin('1234');
          await mgr.authenticatePin('0000');
          await mgr.authenticatePin('1111');
          Future<Object?> write() => switch (writer) {
                'randomizedKeypad' => mgr.setRandomizedKeypadEnabled(true),
                'patternVisibility' => mgr.setPatternVisibilityEnabled(false),
                _ => mgr.updateBiometricOptions(BiometricOptions.defaults),
              };
          final List<Future<Object?>> ops = writerFirst
              ? <Future<Object?>>[write(), mgr.authenticatePin('2222')]
              : <Future<Object?>>[mgr.authenticatePin('2222'), write()];
          await Future.wait(ops);
          final SecuritySettings s = (await repo.getSettings()).valueOrNull!;
          expect(s.lockedOutUntil, t0.add(const Duration(seconds: 30)));
          expect(s.lockoutStreak, 1);
          switch (writer) {
            case 'randomizedKeypad':
              expect(s.randomizedKeypadEnabled, isTrue);
            case 'patternVisibility':
              expect(s.patternVisibilityEnabled, isFalse);
            default:
              expect(s.biometricOptions, BiometricOptions.defaults);
          }

          // During the ACTIVE lockout: all three writers plus blocked
          // attempts concurrently — the cooldown is byte-for-byte kept.
          final SecuritySettings before = s;
          await Future.wait(<Future<Object?>>[
            mgr.setRandomizedKeypadEnabled(false),
            mgr.authenticatePin('1234'),
            mgr.setPatternVisibilityEnabled(true),
            mgr.updateBiometricOptions(null),
            mgr.authenticatePin('9999'),
          ]);
          final SecuritySettings after =
              (await repo.getSettings()).valueOrNull!;
          expect(after.lockedOutUntil, before.lockedOutUntil);
          expect(after.lockoutStreak, before.lockoutStreak);
          expect(after.failedAttempts, before.failedAttempts);
        });
      }
    }

    test(
        'A.4: a hasher that THROWS with two operations queued behind it — '
        'the error propagates, the queue drains, nothing is wedged', () async {
      final _ThrowingPinHasher hasher = _ThrowingPinHasher();
      final DefaultCredentialManager mgr = build(
        SecuritySettingsRepositoryImpl(InMemoryLocalDatabase()),
        pinHasher: hasher,
      );
      await mgr.enrollPin('1234');
      hasher.throwVerifies = 1;
      final Future<Result<AuthAttemptResult>> first =
          mgr.authenticatePin('0000');
      final Future<Result<AuthAttemptResult>> second =
          mgr.authenticatePin('1111');
      final Future<Result<void>> third = mgr.setRandomizedKeypadEnabled(true);
      await expectLater(first, throwsStateError);
      expect((await second.timeout(const Duration(seconds: 5))).valueOrNull,
          isA<AuthFailure>());
      expect(
          (await third.timeout(const Duration(seconds: 5))).isSuccess, isTrue);
      final CredentialState s = (await mgr.status()).valueOrNull!;
      expect(s.failedAttempts, 1, reason: 'the throwing call counted nothing');
      expect(
          (await mgr.authenticatePin('1234')).valueOrNull, isA<AuthSuccess>());
    });

    test(
        'A.4: a repository that THROWS on read and on write — later '
        'operations complete; the failed write left nothing half-applied',
        () async {
      final _ThrowingSettings repo = _ThrowingSettings(
          SecuritySettingsRepositoryImpl(InMemoryLocalDatabase()));
      final DefaultCredentialManager mgr = build(repo);
      await mgr.enrollPin('1234');
      repo.throwReads = 1;
      final Future<Object?> a = mgr.authenticatePin('0000');
      final Future<Result<AuthAttemptResult>> b = mgr.authenticatePin('0000');
      await expectLater(a, throwsStateError);
      expect((await b).valueOrNull, isA<AuthFailure>());
      repo.throwWrites = 1;
      final Future<Object?> c = mgr.authenticatePin('1111');
      final Future<Result<void>> d = mgr.setPatternVisibilityEnabled(false);
      await expectLater(c, throwsStateError);
      expect((await d.timeout(const Duration(seconds: 5))).isSuccess, isTrue);
      final CredentialState s = (await mgr.status()).valueOrNull!;
      expect(s.failedAttempts, 1, reason: 'unwritten failure is not counted');
      expect(s.patternVisibilityEnabled, isFalse);
      expect(
          (await mgr.authenticatePin('1234')).valueOrNull, isA<AuthSuccess>());
    });

    test(
        'A.5: callers from the root zone, a custom zone and a guarded error '
        'zone, concurrently — all complete; 3 failures; lockout', () async {
      final SecuritySettingsRepositoryImpl repo =
          SecuritySettingsRepositoryImpl(InMemoryLocalDatabase());
      final DefaultCredentialManager mgr = build(_OverlapProbe(repo));
      await mgr.enrollPin('1234');
      final Completer<Object?> guarded = Completer<Object?>();
      final List<Future<Object?>> calls = <Future<Object?>>[
        Zone.root.run(() => mgr.authenticatePin('0000')),
        runZoned(() => mgr.authenticatePin('1111'),
            zoneValues: <Object, Object>{#gate: 'custom'}),
        guarded.future,
        Zone.root.run(() => mgr.setRandomizedKeypadEnabled(true)),
      ];
      runZonedGuarded(() {
        mgr.authenticatePin('2222').then(guarded.complete);
      }, (Object e, StackTrace s) => guarded.completeError(e, s));
      await Future.wait(calls).timeout(const Duration(seconds: 10));
      final SecuritySettings s = (await repo.getSettings()).valueOrNull!;
      expect(s.lockedOutUntil, isNotNull);
      expect(s.lockoutStreak, 1);
      expect(s.randomizedKeypadEnabled, isTrue);
    });

    testWidgets(
        'A.5: fake-async (widget) callers and real-async callers interleaved '
        '— no stall, no lost update', (WidgetTester tester) async {
      final SecuritySettingsRepositoryImpl repo =
          SecuritySettingsRepositoryImpl(InMemoryLocalDatabase());
      late DefaultCredentialManager mgr;
      await tester.runAsync(() async {
        mgr = build(repo);
        await mgr.enrollPin('1234');
      });
      final Future<Object?> fakeZoneCall = mgr.authenticatePin('0000');
      await tester.runAsync(() async {
        await Future.wait(<Future<Object?>>[
          mgr.authenticatePin('1111'),
          mgr.setPatternVisibilityEnabled(false),
          fakeZoneCall,
          mgr.authenticatePin('2222'),
        ]).timeout(const Duration(seconds: 10));
      });
      final SecuritySettings s =
          (await tester.runAsync(repo.getSettings))!.valueOrNull!;
      expect(s.lockedOutUntil, isNotNull);
      expect(s.patternVisibilityEnabled, isFalse);
    });

    test(
        'A.5: an observer that re-enters the manager from inside its '
        'callback (under the lock) queues instead of deadlocking', () async {
      final _SpyObserver obs = _SpyObserver();
      final DefaultCredentialManager mgr = build(
        SecuritySettingsRepositoryImpl(InMemoryLocalDatabase()),
        observer: obs,
      );
      await mgr.enrollPin('1234');
      final List<Future<Object?>> reentered = <Future<Object?>>[];
      obs.onEach = (VerifiedAttempt a) {
        if (reentered.isEmpty) {
          reentered
            ..add(mgr.authenticatePin('5555'))
            ..add(mgr.setRandomizedKeypadEnabled(true))
            ..add(mgr.status());
        }
      };
      await mgr.authenticatePin('0000').timeout(const Duration(seconds: 5));
      await Future.wait(reentered).timeout(const Duration(seconds: 5));
      final CredentialState s = (await mgr.status()).valueOrNull!;
      expect(s.failedAttempts, 2);
      expect(s.randomizedKeypadEnabled, isTrue);
    });

    test(
        'A.6: a biometric prompt that NEVER completes blocks no PIN entry, '
        'preference write, enrollment or clearing', () async {
      final _GatedBiometrics bio = _GatedBiometrics();
      final DefaultCredentialManager mgr = build(
        SecuritySettingsRepositoryImpl(InMemoryLocalDatabase()),
        bio: bio,
      );
      await mgr.enrollPin('1234');
      await mgr.updateBiometricOptions(BiometricOptions.defaults);
      unawaited(mgr.authenticateBiometric());
      await pumpEventQueue();
      expect(bio.prompts, 1);
      const Duration t = Duration(seconds: 5);
      expect((await mgr.authenticatePin('0000').timeout(t)).valueOrNull,
          isA<AuthFailure>());
      expect((await mgr.setRandomizedKeypadEnabled(true).timeout(t)).isSuccess,
          isTrue);
      final CredentialChangeAuthorization g =
          (await mgr.verifyPinForCredentialChange('1234').timeout(t))
              .valueOrNull!
              .authorization!;
      expect(
          (await mgr.enrollPattern(const <int>[1, 5, 9, 8],
                  authorization: g).timeout(t))
              .isSuccess,
          isTrue);
      expect((await mgr.clearAll().timeout(t)).isSuccess, isTrue);
      expect(bio.gate.isCompleted, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('Gate B — a stale biometric prompt can never authorize', () {
    late SecuritySettingsRepositoryImpl repo;
    late _GatedBiometrics bio;
    late _SpyObserver obs;
    late DefaultCredentialManager mgr;
    DateTime now = t0;

    DefaultCredentialManager build() => DefaultCredentialManager(
          settings: repo,
          pinHasher: Pbkdf2PinHasher(iterations: 200),
          patternHasher: Pbkdf2PatternHasher(iterations: 200),
          stateMachine: CredentialStateMachine(
            maxFailedAttempts: 3,
            lockoutDuration: const Duration(seconds: 30),
          ),
          biometricService: bio,
          now: () => now,
          attemptObserver: obs,
        );

    Future<SecuritySettings> stored() async =>
        (await repo.getSettings()).valueOrNull!;

    Future<CredentialChangeAuthorization> grant() async =>
        (await mgr.verifyPinForCredentialChange('1234'))
            .valueOrNull!
            .authorization!;

    /// Starts a prompt, runs [during] while it is open, then delivers
    /// [verdict]. Returns the final result.
    Future<AuthAttemptResult> prompt(
      Future<void> Function() during, {
      Result<bool>? verdict,
      DefaultCredentialManager? via,
    }) async {
      final Future<Result<AuthAttemptResult>> pending =
          (via ?? mgr).authenticateBiometric();
      await pumpEventQueue();
      expect(bio.prompts, greaterThan(0), reason: 'prompt is open');
      await during();
      bio.gate.complete(verdict ?? Result.success(true));
      return (await pending).valueOrNull!;
    }

    setUp(() async {
      now = t0;
      repo = SecuritySettingsRepositoryImpl(InMemoryLocalDatabase());
      bio = _GatedBiometrics();
      obs = _SpyObserver();
      mgr = build();
      await mgr.enrollPin('1234');
      await mgr.updateBiometricOptions(BiometricOptions.defaults);
    });

    test('control: no change during the prompt -> success', () async {
      final AuthAttemptResult r = await prompt(() async {});
      expect(r, isA<AuthSuccess>());
      expect(obs.seen.single.result, isA<AuthSuccess>());
    });

    test(
        'PIN replaced through the authorized CR-3 flow during the prompt -> '
        'late success is discarded (cancelled), nothing reset or reported',
        () async {
      late SecuritySettings afterChange;
      final AuthAttemptResult r = await prompt(() async {
        expect(
            (await mgr.enrollPin('8642', authorization: await grant()))
                .isSuccess,
            isTrue);
        await mgr.authenticatePin('0000'); // a failure after the change
        afterChange = await stored();
        obs.seen.clear();
      });
      expect(r, isNot(isA<AuthSuccess>()));
      expect((r as AuthFailure).reason, AuthFailureReason.cancelled);
      expect(r.remainingAttempts, 2);
      final SecuritySettings s = await stored();
      expect(s.toJson(), afterChange.toJson(), reason: 'nothing persisted');
      expect(s.failedAttempts, 1, reason: 'no counter reset');
      expect(obs.seen, isEmpty);
      expect(
          (await mgr.authenticatePin('1234')).valueOrNull, isA<AuthFailure>(),
          reason: 'old PIN stays replaced');
      expect(
          (await mgr.authenticatePin('8642')).valueOrNull, isA<AuthSuccess>());
    });

    test('pattern enrolled (new primary) during the prompt -> cancelled',
        () async {
      final AuthAttemptResult r = await prompt(() async {
        expect(
            (await mgr.enrollPattern(const <int>[1, 2, 3, 6],
                    authorization: await grant()))
                .isSuccess,
            isTrue);
      });
      expect((r as AuthFailure).reason, AuthFailureReason.cancelled);
      expect((await stored()).patternHash, isNotNull);
    });

    test(
        'credentials CLEARED during the prompt -> notConfigured; the old '
        'credential is NOT resurrected', () async {
      final AuthAttemptResult r = await prompt(() async {
        expect((await mgr.clearAll()).isSuccess, isTrue);
      });
      expect((r as AuthFailure).reason, AuthFailureReason.notConfigured);
      final SecuritySettings s = await stored();
      expect(s.pinHash, isNull);
      expect(s.patternHash, isNull);
      expect(s.biometricOptions, isNull);
      expect(obs.seen, isEmpty);
    });

    test('biometric DISABLED during the prompt -> notConfigured; stays off',
        () async {
      final AuthAttemptResult r = await prompt(() async {
        await mgr.updateBiometricOptions(null);
      });
      expect((r as AuthFailure).reason, AuthFailureReason.notConfigured);
      expect((await stored()).biometricOptions, isNull);
      expect(obs.seen, isEmpty);
    });

    test(
        'biometric disabled and RE-ENABLED with identical options during the '
        'prompt -> still stale (epoch), cancelled', () async {
      final AuthAttemptResult r = await prompt(() async {
        await mgr.updateBiometricOptions(null);
        await mgr.updateBiometricOptions(BiometricOptions.defaults);
      });
      expect((r as AuthFailure).reason, AuthFailureReason.cancelled);
    });

    test(
        'a SECOND manager instance replaces the PIN during the prompt '
        '(epoch untouched) -> the credential basis differs, cancelled',
        () async {
      final DefaultCredentialManager other = build();
      final AuthAttemptResult r = await prompt(() async {
        final CredentialChangeAuthorization g =
            (await other.verifyPinForCredentialChange('1234'))
                .valueOrNull!
                .authorization!;
        expect((await other.enrollPin('9753', authorization: g)).isSuccess,
            isTrue);
      });
      expect((r as AuthFailure).reason, AuthFailureReason.cancelled);
    });

    test(
        'a DENIED credential change (no grant) writes nothing and does not '
        'make the prompt stale', () async {
      final AuthAttemptResult r = await prompt(() async {
        expect((await mgr.enrollPin('8642')).isFailure, isTrue);
      });
      expect(r, isA<AuthSuccess>());
    });

    test('lockout activated during the prompt -> AuthLockedOut; kept',
        () async {
      late SecuritySettings locked;
      final AuthAttemptResult r = await prompt(() async {
        for (final String p in <String>['0000', '1111', '2222']) {
          await mgr.authenticatePin(p);
        }
        locked = await stored();
      });
      expect(r, isA<AuthLockedOut>());
      final SecuritySettings s = await stored();
      expect(s.lockedOutUntil, locked.lockedOutUntil);
      expect(s.lockoutStreak, locked.lockoutStreak);
      expect(s.failedAttempts, locked.failedAttempts);
    });

    test(
        'preferences changed during the prompt are preserved and do not '
        'invalidate it', () async {
      final AuthAttemptResult r = await prompt(() async {
        await mgr.setRandomizedKeypadEnabled(true);
        await mgr.setPatternVisibilityEnabled(false);
      });
      expect(r, isA<AuthSuccess>());
      final SecuritySettings s = await stored();
      expect(s.randomizedKeypadEnabled, isTrue);
      expect(s.patternVisibilityEnabled, isFalse);
    });

    test(
        'a late REJECTION after a credential change is still counted '
        '(staleness never reduces counting)', () async {
      final AuthAttemptResult r = await prompt(() async {
        await mgr.enrollPin('8642', authorization: await grant());
      }, verdict: Result.success(false));
      expect((r as AuthFailure).reason, AuthFailureReason.wrongCredential);
      expect((await stored()).failedAttempts, 1);
    });

    test('H-3 unchanged: cancellation after a change persists nothing',
        () async {
      late SecuritySettings mid;
      final AuthAttemptResult r = await prompt(() async {
        await mgr.enrollPin('8642', authorization: await grant());
        await mgr.authenticatePin('0000');
        mid = await stored();
      },
          verdict: Result.failure(const BiometricAuthException(
              code: 'userCanceled', message: 'x')));
      expect((r as AuthFailure).reason, AuthFailureReason.cancelled);
      expect((await stored()).toJson(), mid.toJson());
    });

    test('hardware unavailable after a change: not counted, not granted',
        () async {
      final AuthAttemptResult r = await prompt(() async {
        await mgr.clearAll();
      },
          verdict: Result.failure(const BiometricAuthException(
              code: 'biometricHardwareTemporarilyUnavailable', message: 'x')));
      expect((r as AuthFailure).reason, AuthFailureReason.notAvailable);
      expect((await stored()).failedAttempts, 0);
    });

    test(
        'challenge level: a recorder whose biometric prompt outlived a PIN '
        'change records NO success (close() is false); control is true',
        () async {
      final ChallengeAuthRecorder stale = ChallengeAuthRecorder.forPinRoute(
        mgr,
        attemptContext: const AuthAttemptContext.protectedAppChallenge(
          packageName: 'com.example.bank',
          generation: 3,
          challengeSerial: 1,
        ),
      );
      final Future<Result<AuthAttemptResult>> pending =
          stale.authenticateBiometric();
      await pumpEventQueue();
      await mgr.enrollPin('8642', authorization: await grant());
      bio.gate.complete(Result.success(true));
      expect((await pending).valueOrNull, isNot(isA<AuthSuccess>()));
      expect(stale.close(), isFalse);

      bio.gate = Completer<Result<bool>>();
      final ChallengeAuthRecorder fresh =
          ChallengeAuthRecorder.forPinRoute(mgr);
      final Future<Result<AuthAttemptResult>> ok =
          fresh.authenticateBiometric();
      await pumpEventQueue();
      bio.gate.complete(Result.success(true));
      expect((await ok).valueOrNull, isA<AuthSuccess>());
      expect(fresh.close(), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('Gate C — observer isolation (manager level)', () {
    /// Runs the canonical sequence and returns a transcript that must be
    /// identical with and without a broken observer.
    Future<List<String>> transcript(VerifiedAttemptObserver? observer) async {
      DateTime now = t0;
      final SecuritySettingsRepositoryImpl repo =
          SecuritySettingsRepositoryImpl(InMemoryLocalDatabase());
      final DefaultCredentialManager mgr = DefaultCredentialManager(
        settings: repo,
        pinHasher: Pbkdf2PinHasher(iterations: 200),
        patternHasher: Pbkdf2PatternHasher(iterations: 200),
        stateMachine: CredentialStateMachine(
          maxFailedAttempts: 3,
          lockoutDuration: const Duration(seconds: 30),
        ),
        biometricService: _GatedBiometrics(),
        now: () => now,
        attemptObserver: observer,
      );
      final List<String> out = <String>[];
      String fmt(AuthAttemptResult r) => switch (r) {
            AuthSuccess() => 'success',
            AuthFailure(
              :final AuthFailureReason reason,
              :final int remainingAttempts
            ) =>
              'fail:${reason.name}:$remainingAttempts',
            AuthLockedOut(:final DateTime retryAt) =>
              'locked:${retryAt.difference(t0).inSeconds}',
          };
      Future<void> pin(String p) async =>
          out.add(fmt((await mgr.authenticatePin(p)).valueOrNull!));
      Future<void> pattern(List<int> n) async =>
          out.add(fmt((await mgr.authenticatePattern(n)).valueOrNull!));
      await mgr.enrollPin('1234');
      await pin('0000');
      await pin('1111');
      await pin('2222'); // lockout 30 s
      await pin('1234'); // blocked
      final SecuritySettings locked = (await repo.getSettings()).valueOrNull!;
      out.add('until:${locked.lockedOutUntil!.difference(t0).inSeconds}'
          ' streak:${locked.lockoutStreak}');
      now = t0.add(const Duration(seconds: 31));
      await pin('1234'); // cooldown over: success
      final CredentialChangeAuthorization g =
          (await mgr.verifyPinForCredentialChange('1234'))
              .valueOrNull!
              .authorization!;
      await mgr.enrollPattern(const <int>[1, 2, 3, 6], authorization: g);
      await pattern(const <int>[9, 8, 7, 4]);
      await pattern(const <int>[1, 2, 3, 6]);
      final SecuritySettings end = (await repo.getSettings()).valueOrNull!;
      out.add('end failed:${end.failedAttempts} streak:${end.lockoutStreak} '
          'locked:${end.lockedOutUntil != null}');
      return out;
    }

    late List<String> control;
    setUpAll(() async => control = await transcript(null));

    test('control transcript is the expected security behaviour', () {
      expect(control, <String>[
        'fail:wrongCredential:2',
        'fail:wrongCredential:1',
        'locked:30',
        'locked:30',
        'until:30 streak:1',
        'success',
        'fail:wrongCredential:2',
        'success',
        // A verified success resets the streak (CredentialStateMachine,
        // unchanged since 824b2ae).
        'end failed:0 streak:0 locked:false',
      ]);
    });

    test('observer that throws on every report: identical transcript',
        () async {
      final _SpyObserver obs = _SpyObserver()..throwOnEach = true;
      expect(await transcript(obs), control);
      expect(obs.seen, isNotEmpty);
    });

    test('monitor with broken storage: identical transcript', () async {
      final IntruderMonitor m = IntruderMonitor(
        store: IntruderFailureLogStore(_BrokenIntruderDb()),
      );
      expect(await transcript(m), control);
      await m.idle();
      expect(m.status.health, IntruderMonitorHealth.storageError);
    });

    test(
        'monitor SATURATED (writes hang forever, queue overflowing): '
        'identical transcript, events dropped by design', () async {
      final IntruderMonitor m = IntruderMonitor(
        store: IntruderFailureLogStore(_HangingIntruderDb()),
      );
      _saturate(m);
      final int droppedBefore = m.status.droppedEvents;
      expect(droppedBefore, greaterThan(0));
      expect(await transcript(m).timeout(const Duration(seconds: 20)), control);
      expect(m.status.droppedEvents, greaterThan(droppedBefore));
    });
  });

  // -------------------------------------------------------------------------
  group('Gate C — observer isolation (production container + host)', () {
    const String app = 'com.example.bank';

    Future<AppContainer> pumpApp(WidgetTester tester, AppContainer c) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(SmartAppLockApp(container: c));
      await tester.pumpAndSettle();
      await c.auth.enrollPin('1234');
      await c.protectedApps.add(ProtectedApp(
        packageName: app,
        label: app,
        addedAt: DateTime(2026, 8, 21),
        securityLevel: AppSecurityLevel.defaultLevel,
      ));
      await c.protectionBootstrap.synchronize();
      return c;
    }

    Future<void> open(WidgetTester tester, AppContainer c) async {
      (c.accessibility as StaticAccessibilityLockService)
          .emitForegroundPackage(app);
      await tester.pumpAndSettle();
    }

    Future<void> typePin(WidgetTester tester, String pin) async {
      for (final String d in pin.split('')) {
        await tester.tap(find.byKey(Key('pin_key_$d')));
        await tester.pumpAndSettle();
      }
    }

    Object? session(AppContainer c) =>
        (c.accessController as DefaultAccessController).sessionFor(app);
    Set<String> authorized(AppContainer c) =>
        (c.watcher as StaticWatcherService).authorizedPackages;
    int launches(AppContainer c) =>
        (c.installedAppsService as StaticInstalledAppsService).launchAppCalls;

    testWidgets(
        'saturated monitor: a wrong PIN authorizes nothing natively; the '
        'correct PIN still authorizes exactly as before',
        (WidgetTester tester) async {
      final AppContainer c = await pumpApp(
          tester, AppContainer.inMemory(database: _HangingIntruderDb()));
      _saturate(c.intruderMonitor);
      expect(c.intruderMonitor.status.droppedEvents, greaterThan(0));
      await open(tester, c);
      expect(find.byType(PinUnlockScreen), findsOneWidget);

      await typePin(tester, '9999');
      expect(find.byType(PinUnlockScreen), findsOneWidget);
      expect(session(c), isNull);
      expect(authorized(c), isNot(contains(app)));
      expect(launches(c), 0);
      expect((await c.auth.status()).valueOrNull!.failedAttempts, 1);

      await typePin(tester, '1234');
      expect(find.byType(PinUnlockScreen), findsNothing);
      expect(session(c), isNotNull);
      expect(authorized(c), contains(app));
    });

    testWidgets(
        'saturated monitor: three wrong PINs trip the cooldown; the correct '
        'PIN is then blocked — no session, no native authorization',
        (WidgetTester tester) async {
      final AppContainer c = await pumpApp(
          tester, AppContainer.inMemory(database: _HangingIntruderDb()));
      _saturate(c.intruderMonitor);
      await open(tester, c);
      for (final String p in <String>['1111', '2222', '3333']) {
        await typePin(tester, p);
      }
      final CredentialState s = (await c.auth.status()).valueOrNull!;
      expect(s.lockedOutUntil, isNotNull);
      expect(s.lockoutStreak, 1);
      expect((await c.auth.authenticatePin('1234')).valueOrNull,
          isA<AuthLockedOut>());
      expect(session(c), isNull);
      expect(authorized(c), isNot(contains(app)));
      expect(launches(c), 0);
    });

    testWidgets(
        'broken monitor storage: same — the intruder fault grants nothing '
        'and resets no lockout', (WidgetTester tester) async {
      final AppContainer c = await pumpApp(
          tester, AppContainer.inMemory(database: _BrokenIntruderDb()));
      await open(tester, c);
      for (final String p in <String>['1111', '2222', '3333']) {
        await typePin(tester, p);
      }
      await tester.runAsync(c.intruderMonitor.idle);
      expect(
          c.intruderMonitor.status.health, IntruderMonitorHealth.storageError);
      final CredentialState s = (await c.auth.status()).valueOrNull!;
      expect(s.lockedOutUntil, isNotNull);
      expect(session(c), isNull);
      expect(authorized(c), isNot(contains(app)));
    });
  });
}
