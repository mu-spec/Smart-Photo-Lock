// Phase 12 / Milestone 1 — Intruder Defense foundation.
//
// IntruderMonitor + IntruderFailureLogStore: which verdicts become
// failed-attempt events, deduplication, ordering, persistence, corrupt /
// unsupported / tampered storage, capacity, retention, bounded queues,
// privacy and the "no path into enforcement" import invariant.
//
// SIMULATED: pure Dart VM with in-memory storage and deterministic clocks.
// No platform channel, APK, device or biometric hardware involved.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/security/credentials/auth_result.dart';
import 'package:smart_app_lock/security/credentials/auth_type.dart';
import 'package:smart_app_lock/security/credentials/verified_attempt.dart';
import 'package:smart_app_lock/security/encryption/settings_cipher.dart';
import 'package:smart_app_lock/security/encryption/settings_cipher_impl.dart';
import 'package:smart_app_lock/security/intruder/failed_attempt_event.dart';
import 'package:smart_app_lock/security/intruder/intruder_failure_log_store.dart';
import 'package:smart_app_lock/security/intruder/intruder_monitor.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';

const String _key = IntruderFailureLogStore.storageKey;
const String _qKey = IntruderFailureLogStore.quarantineKey;

/// Database with switchable read/write faults and an optional write gate.
class _FaultDb extends InMemoryLocalDatabase {
  bool failReads = false;
  bool failWrites = false;
  Completer<void>? writeGate;
  int writes = 0;

  @override
  Future<String?> getSetting(String key) async {
    if (failReads && key == _key) {
      throw StateError('read fault');
    }
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) async {
    final Completer<void>? gate = writeGate;
    if (gate != null && key == _key) {
      await gate.future;
    }
    if (failWrites && key == _key) {
      throw StateError('write fault');
    }
    writes++;
    return super.setSetting(key, value);
  }
}

int _vid = 0;
final DateTime _t0 = DateTime(2026, 10, 22, 12);

VerifiedAttempt _attempt({
  AuthType type = AuthType.pin,
  bool matched = false,
  AuthAttemptResult result = const AuthFailure(
    reason: AuthFailureReason.wrongCredential,
    remainingAttempts: 2,
  ),
  bool persisted = true,
  int streak = 0,
  AuthAttemptContext context = AuthAttemptContext.smartAppLock,
  DateTime? at,
  String? vid,
}) =>
    VerifiedAttempt(
      verificationId: vid ?? 'test:${++_vid}',
      type: type,
      matched: matched,
      result: result,
      counterPersisted: persisted,
      lockoutStreak: streak,
      context: context,
      at: at ?? _t0,
    );

VerifiedAttempt _success(
        [AuthType type = AuthType.pin, bool persisted = true]) =>
    _attempt(
      type: type,
      matched: true,
      result: AuthSuccess(type: type),
      persisted: persisted,
    );

const AuthAttemptContext _chat = AuthAttemptContext.protectedAppChallenge(
  packageName: 'com.example.chat',
  generation: 7,
  challengeSerial: 3,
);

void main() {
  late _FaultDb db;
  late IntruderFailureLogStore store;
  late IntruderMonitor monitor;
  DateTime now = _t0;

  IntruderMonitor build({
    IntruderFailureLogStore? s,
    int maxEvents = IntruderMonitor.defaultMaxEvents,
    int maxPending = IntruderMonitor.defaultMaxPending,
    int maxBytes = IntruderMonitor.defaultMaxEncodedBytes,
  }) =>
      IntruderMonitor(
        store: s ?? store,
        now: () => now,
        maxEvents: maxEvents,
        maxPending: maxPending,
        maxEncodedBytes: maxBytes,
      );

  Future<IntruderFailureLog> log([IntruderMonitor? m]) async =>
      (await (m ?? monitor).snapshot())!;

  setUp(() {
    now = _t0;
    db = _FaultDb();
    store = IntruderFailureLogStore(db);
    monitor = build();
  });

  group('which verdicts create a failed-attempt event', () {
    test('a wrong PIN creates one event with app attribution', () async {
      monitor.onVerifiedAttempt(_attempt());
      final IntruderFailureLog l = await log();
      expect(l.events, hasLength(1));
      final FailedAttemptEvent e = l.events.single;
      expect(e.method, FailedAttemptMethod.pin);
      expect(e.surface, AuthAttemptSurface.smartAppLock);
      expect(e.packageName, isNull);
      expect(e.generation, isNull);
      expect(e.consecutiveFailures, 1);
      expect(e.lockoutTriggered, isFalse);
      expect(e.counterPersisted, isTrue);
      expect(l.consecutiveFailures, 1);
    });

    test('a wrong pattern creates a pattern event with challenge attribution',
        () async {
      monitor.onVerifiedAttempt(
        _attempt(type: AuthType.pattern, context: _chat),
      );
      final FailedAttemptEvent e = (await log()).events.single;
      expect(e.method, FailedAttemptMethod.pattern);
      expect(e.surface, AuthAttemptSurface.protectedAppChallenge);
      expect(e.packageName, 'com.example.chat');
      expect(e.generation, 7);
      expect(e.challengeSerial, 3);
    });

    test('the failure that trips the cooldown is recorded as a lockout',
        () async {
      monitor.onVerifiedAttempt(
        _attempt(
          result: AuthLockedOut(
            retryAt: _t0.add(const Duration(seconds: 30)),
            attemptsMade: 3,
            lockoutStreak: 1,
          ),
          streak: 1,
        ),
      );
      final FailedAttemptEvent e = (await log()).events.single;
      expect(e.lockoutTriggered, isTrue);
      expect(e.lockoutStreak, 1);
    });

    test('an attempt blocked by an active lockout is never recorded', () async {
      monitor.onVerifiedAttempt(
        _attempt(
          result: AuthLockedOut(retryAt: _t0, lockoutStreak: 1), // blocked
        ),
      );
      expect((await log()).events, isEmpty);
      expect((await log()).consecutiveFailures, 0);
    });

    test('non-verification failures are never recorded', () async {
      for (final AuthFailureReason reason in <AuthFailureReason>[
        AuthFailureReason.noCredentialEnrolled,
        AuthFailureReason.invalidInput,
        AuthFailureReason.notConfigured,
        AuthFailureReason.notAvailable,
        AuthFailureReason.cancelled,
      ]) {
        monitor.onVerifiedAttempt(
          _attempt(result: AuthFailure(reason: reason, remainingAttempts: 3)),
        );
      }
      expect((await log()).events, isEmpty);
    });

    test(
        'biometric rejections, errors and cancellations create no event '
        'and leave the run unchanged', () async {
      monitor.onVerifiedAttempt(_attempt()); // run = 1
      for (final AuthFailureReason reason in <AuthFailureReason>[
        AuthFailureReason.wrongCredential,
        AuthFailureReason.cancelled,
        AuthFailureReason.notAvailable,
      ]) {
        monitor.onVerifiedAttempt(
          _attempt(
            type: AuthType.biometric,
            result: AuthFailure(reason: reason, remainingAttempts: 1),
          ),
        );
      }
      final IntruderFailureLog l = await log();
      expect(l.events, hasLength(1));
      expect(l.consecutiveFailures, 1);
    });

    test(
        'a matched credential is never recorded as a failure, even when '
        'the verdict is a lockout (late biometric during a cooldown)',
        () async {
      monitor.onVerifiedAttempt(_attempt()); // run = 1
      monitor.onVerifiedAttempt(
        _attempt(
          type: AuthType.biometric,
          matched: true,
          result: AuthLockedOut(retryAt: _t0, lockoutStreak: 1),
        ),
      );
      final IntruderFailureLog l = await log();
      expect(l.events, hasLength(1));
      expect(l.consecutiveFailures, 1, reason: 'blocked success: no reset');
    });

    test('a verified success resets the run but keeps the evidence', () async {
      monitor.onVerifiedAttempt(_attempt());
      monitor.onVerifiedAttempt(_attempt());
      monitor.onVerifiedAttempt(_success());
      IntruderFailureLog l = await log();
      expect(l.consecutiveFailures, 0);
      expect(l.events, hasLength(2));
      monitor.onVerifiedAttempt(_attempt());
      l = await log();
      expect(l.events.last.consecutiveFailures, 1);
    });

    test('a biometric success also proves the owner and resets the run',
        () async {
      monitor.onVerifiedAttempt(_attempt());
      monitor.onVerifiedAttempt(_success(AuthType.biometric));
      expect((await log()).consecutiveFailures, 0);
    });

    test(
        'a success whose counters were NOT persisted (returned to the UI as '
        'a failure) does not reset the run', () async {
      monitor.onVerifiedAttempt(_attempt());
      monitor.onVerifiedAttempt(_success(AuthType.pin, false));
      expect((await log()).consecutiveFailures, 1);
    });

    test('a success with nothing to reset writes nothing', () async {
      monitor.onVerifiedAttempt(_success());
      await monitor.idle();
      expect(db.writes, 0);
    });
  });

  group('identity, deduplication and ordering', () {
    test('the same verification delivered twice is recorded once', () async {
      final VerifiedAttempt a = _attempt();
      monitor.onVerifiedAttempt(a);
      monitor.onVerifiedAttempt(a);
      final IntruderFailureLog l = await log();
      expect(l.events, hasLength(1));
      expect(l.consecutiveFailures, 1);
    });

    test('a re-delivery after a restart is still recorded once', () async {
      final VerifiedAttempt a = _attempt();
      monitor.onVerifiedAttempt(a);
      await monitor.idle();
      final IntruderMonitor restarted = build();
      restarted.onVerifiedAttempt(a);
      expect((await log(restarted)).events, hasLength(1));
    });

    test('identical timestamps never collapse distinct attempts', () async {
      for (int i = 0; i < 3; i++) {
        monitor.onVerifiedAttempt(_attempt(at: _t0));
      }
      expect((await log()).events, hasLength(3));
    });

    test(
        'events get strictly increasing seq and run in verdict order, and '
        'both continue across a restart', () async {
      for (int i = 0; i < 4; i++) {
        monitor.onVerifiedAttempt(_attempt());
      }
      await monitor.idle();
      final IntruderMonitor restarted = build();
      restarted.onVerifiedAttempt(_attempt());
      final IntruderFailureLog l = await log(restarted);
      expect(
          l.events.map((FailedAttemptEvent e) => e.seq), <int>[0, 1, 2, 3, 4]);
      expect(l.events.map((FailedAttemptEvent e) => e.consecutiveFailures),
          <int>[1, 2, 3, 4, 5]);
      expect(l.nextSeq, 5);
    });

    test('seq never rewinds when the clock goes backwards', () async {
      monitor.onVerifiedAttempt(_attempt(at: _t0));
      monitor.onVerifiedAttempt(
        _attempt(at: _t0.subtract(const Duration(days: 3))),
      );
      final IntruderFailureLog l = await log();
      expect(l.events.map((FailedAttemptEvent e) => e.seq), <int>[0, 1]);
    });

    test('the run saturates instead of overflowing', () async {
      await store.write(
        const IntruderFailureLog(
          nextSeq: 0,
          consecutiveFailures: IntruderFailureLog.maxRun,
          events: <FailedAttemptEvent>[],
        ),
      );
      monitor.onVerifiedAttempt(_attempt());
      final IntruderFailureLog l = await log();
      expect(l.consecutiveFailures, IntruderFailureLog.maxRun);
    });
  });

  group('encryption at rest and privacy', () {
    test('the stored log is AES-GCM ciphertext that hides package names',
        () async {
      final SettingsCipher cipher = AesGcmSettingsCipher(InMemorySecretStore());
      final IntruderFailureLogStore enc =
          IntruderFailureLogStore(db, cipher: cipher);
      final IntruderMonitor m = build(s: enc);
      m.onVerifiedAttempt(_attempt(context: _chat));
      await m.idle();
      final String raw = (await db.getSetting(_key))!;
      expect(raw, startsWith('enc:v1:'));
      expect(raw, isNot(contains('com.example.chat')));
      expect(raw, isNot(contains('pin')));
      // And it round-trips through a fresh monitor with the same key.
      expect((await log(build(s: enc))).events.single.packageName,
          'com.example.chat');
    });

    test('toString of events and contexts redacts the package', () {
      final FailedAttemptEvent e = FailedAttemptEvent(
        seq: 0,
        verificationId: 'x:1',
        at: _t0,
        method: FailedAttemptMethod.pin,
        surface: AuthAttemptSurface.protectedAppChallenge,
        packageName: 'com.example.chat',
        generation: 1,
        challengeSerial: 1,
        consecutiveFailures: 1,
        lockoutTriggered: false,
        lockoutStreak: 0,
        counterPersisted: true,
      );
      expect(e.toString(), isNot(contains('com.example.chat')));
      expect(_chat.toString(), isNot(contains('com.example.chat')));
    });

    test('the persisted event schema has no field for credential material',
        () async {
      monitor.onVerifiedAttempt(_attempt(context: _chat));
      await monitor.idle();
      final Map<String, dynamic> doc =
          jsonDecode((await db.getSetting(_key))!) as Map<String, dynamic>;
      final Map<String, dynamic> event =
          (doc['events'] as List<dynamic>).single as Map<String, dynamic>;
      expect(
        event.keys.toSet(),
        <String>{
          'seq', 'vid', 'at', 'method', 'surface', 'pkg', 'gen', 'chal', //
          'run', 'lockout', 'streak', 'persisted',
        },
      );
    });
  });

  group('corrupt, tampered and unsupported storage', () {
    test('a garbage row is quarantined once and the log reinitializes',
        () async {
      await db.setSetting(_key, '{not json');
      monitor.onVerifiedAttempt(_attempt());
      final IntruderFailureLog l = await log();
      expect(l.events, hasLength(1));
      expect(await db.getSetting(_qKey), '{not json');
      expect(monitor.status.quarantinedCorruptLog, isTrue);

      // A second corruption never overwrites the first quarantined value.
      await db.setSetting(_key, 'garbage-2');
      final IntruderMonitor m2 = build();
      m2.onVerifiedAttempt(_attempt());
      await m2.idle();
      expect(await db.getSetting(_qKey), '{not json');
    });

    test('a tampered ciphertext is treated as corrupt (GCM)', () async {
      final SettingsCipher cipher = AesGcmSettingsCipher(InMemorySecretStore());
      final IntruderFailureLogStore enc =
          IntruderFailureLogStore(db, cipher: cipher);
      final IntruderMonitor m = build(s: enc);
      m.onVerifiedAttempt(_attempt());
      await m.idle();
      final String raw = (await db.getSetting(_key))!;
      final int i = raw.length - 6;
      final String flipped =
          raw.replaceRange(i, i + 1, raw[i] == 'A' ? 'B' : 'A');
      await db.setSetting(_key, flipped);
      expect(await enc.read(), isA<IntruderLogCorrupt>());
    });

    test('plaintext where ciphertext belongs is treated as corrupt', () async {
      await IntruderFailureLogStore(db).write(IntruderFailureLog.empty);
      final IntruderFailureLogStore enc = IntruderFailureLogStore(
        db,
        cipher: AesGcmSettingsCipher(InMemorySecretStore()),
      );
      expect(await enc.read(), isA<IntruderLogCorrupt>());
    });

    final Map<String, Object?> validEvent = <String, Object?>{
      'seq': 0, 'vid': 'a:1', 'at': 0, 'method': 'pin', //
      'surface': 'smartAppLock', 'run': 1, 'lockout': false, 'streak': 0,
      'persisted': true,
    };
    Map<String, Object?> doc(List<Object?> events,
            {int nextSeq = 5, int run = 1}) =>
        <String, Object?>{
          'schema': 'sal.intruder_log',
          'v': 1,
          'nextSeq': nextSeq,
          'run': run,
          'events': events,
        };
    final Map<String, Map<String, Object?>> invalid =
        <String, Map<String, Object?>>{
      'negative run': doc(<Object?>[], run: -1),
      'seq not increasing': doc(<Object?>[validEvent, validEvent]),
      'seq beyond nextSeq': doc(<Object?>[validEvent], nextSeq: 0),
      'unknown method': doc(<Object?>[
        <String, Object?>{...validEvent, 'method': 'face'},
      ]),
      'challenge without package': doc(<Object?>[
        <String, Object?>{...validEvent, 'surface': 'protectedAppChallenge'},
      ]),
      'app event with a package': doc(<Object?>[
        <String, Object?>{...validEvent, 'pkg': 'com.x'},
      ]),
      'run below 1': doc(<Object?>[
        <String, Object?>{...validEvent, 'run': 0},
      ]),
      'wrong field type': doc(<Object?>[
        <String, Object?>{...validEvent, 'lockout': 'yes'},
      ]),
      'wrong schema': <String, Object?>{...doc(<Object?>[]), 'schema': 'x'},
      'oversized list': doc(
        List<Object?>.generate(
          IntruderFailureLog.maxDecodableEvents + 1,
          (int i) => <String, Object?>{
            ...validEvent,
            'seq': i,
            'vid': 'a:$i',
          },
        ),
        nextSeq: IntruderFailureLog.maxDecodableEvents + 5,
      ),
    };
    for (final MapEntry<String, Map<String, Object?>> c in invalid.entries) {
      test('schema-invalid document is corrupt: ${c.key}', () async {
        await db.setSetting(_key, jsonEncode(c.value));
        expect(await store.read(), isA<IntruderLogCorrupt>());
      });
    }

    test('a NEWER schema version is never overwritten (read-only)', () async {
      final String newer = jsonEncode(<String, Object?>{
        'schema': 'sal.intruder_log',
        'v': 2,
        'future': true,
      });
      await db.setSetting(_key, newer);
      monitor.onVerifiedAttempt(_attempt());
      monitor.onVerifiedAttempt(_success());
      await monitor.idle();
      expect(await db.getSetting(_key), newer);
      expect(await db.getSetting(_qKey), isNull);
      expect(monitor.status.health, IntruderMonitorHealth.readOnly);
      expect(monitor.status.droppedEvents, 1);
      expect(await monitor.snapshot(), isNull);
    });

    test('encrypted data without a cipher is read-only, never overwritten',
        () async {
      const String raw = 'enc:v1:AAAA';
      await db.setSetting(_key, raw);
      monitor.onVerifiedAttempt(_attempt());
      await monitor.idle();
      expect(await db.getSetting(_key), raw);
      expect(monitor.status.health, IntruderMonitorHealth.readOnly);
    });
  });

  group('storage faults', () {
    test(
        'a failed write keeps the previous row and is counted as dropped; '
        'the next write recovers from storage', () async {
      monitor.onVerifiedAttempt(_attempt());
      await monitor.idle();
      final String? before = await db.getSetting(_key);

      db.failWrites = true;
      monitor.onVerifiedAttempt(_attempt());
      await monitor.idle();
      expect(await db.getSetting(_key), before);
      expect(monitor.status.health, IntruderMonitorHealth.storageError);
      expect(monitor.status.droppedEvents, 1);

      db.failWrites = false;
      monitor.onVerifiedAttempt(_attempt());
      final IntruderFailureLog l = await log();
      expect(l.events.map((FailedAttemptEvent e) => e.seq), <int>[0, 1]);
      expect(l.consecutiveFailures, 2, reason: 'reloaded from storage');
      expect(monitor.status.health, IntruderMonitorHealth.ok);
    });

    test('a transient read failure never overwrites existing evidence',
        () async {
      monitor.onVerifiedAttempt(_attempt());
      await monitor.idle();
      final IntruderMonitor m = build();
      db.failReads = true;
      m.onVerifiedAttempt(_attempt());
      await m.idle();
      expect(m.status.health, IntruderMonitorHealth.storageError);
      expect(m.status.droppedEvents, 1);
      db.failReads = false;
      m.onVerifiedAttempt(_attempt());
      final IntruderFailureLog l = await log(m);
      expect(l.events, hasLength(2), reason: 'first event preserved');
    });

    test('the pending queue is bounded; overflow is counted, never unbounded',
        () async {
      final IntruderMonitor m = build(maxPending: 2);
      db.writeGate = Completer<void>();
      for (int i = 0; i < 10; i++) {
        m.onVerifiedAttempt(_attempt());
      }
      expect(m.status.droppedEvents, 8);
      db.writeGate!.complete();
      db.writeGate = null;
      expect((await log(m)).events, hasLength(2));
    });
  });

  group('capacity and retention', () {
    test('at most maxEvents are kept (the newest); seq keeps counting',
        () async {
      // Delivered one verdict at a time, as the serialized manager does
      // (a synchronous burst beyond maxPending is the overflow test above).
      for (int i = 0; i < 150; i++) {
        monitor.onVerifiedAttempt(_attempt());
        await monitor.idle();
      }
      final IntruderFailureLog l = await log();
      expect(l.events, hasLength(IntruderMonitor.defaultMaxEvents));
      expect(l.events.first.seq, 50);
      expect(l.events.last.seq, 149);
      expect(l.nextSeq, 150);
      expect(l.consecutiveFailures, 150, reason: 'pruning never resets run');
    });

    test(
        'events older than the retention window are pruned on the next '
        'write; future-dated events (clock rollback) are kept', () async {
      monitor.onVerifiedAttempt(_attempt(at: _t0));
      monitor.onVerifiedAttempt(
        _attempt(at: _t0.add(const Duration(days: 400))), // future-dated
      );
      await monitor.idle();
      now = _t0.add(const Duration(days: 31));
      monitor.onVerifiedAttempt(_attempt(at: now));
      final IntruderFailureLog l = await log();
      expect(l.events.map((FailedAttemptEvent e) => e.seq), <int>[1, 2]);
      expect(l.consecutiveFailures, 3);
    });

    test('the encoded document stays under the byte bound', () async {
      final IntruderMonitor m = build(maxBytes: 1200);
      for (int i = 0; i < 20; i++) {
        m.onVerifiedAttempt(_attempt(context: _chat));
      }
      final IntruderFailureLog l = await log(m);
      expect(IntruderFailureLogStore.encode(l).length, lessThan(1400));
      expect(l.events.last.seq, 19);
      expect(l.events.length, lessThan(20));
    });
  });

  group('zone safety', () {
    testWidgets(
        'a monitor built outside the fake-async zone records attempts '
        'delivered from it and from runAsync', (WidgetTester tester) async {
      await tester.runAsync(() async {
        monitor.onVerifiedAttempt(_attempt());
        await monitor.idle();
      });
      monitor.onVerifiedAttempt(_attempt());
      await monitor.idle();
      expect((await log()).events, hasLength(2));
    });
  });

  group('architecture: monitoring has no path into enforcement', () {
    test(
        'lib/security/intruder imports no protection, rules, profiles, '
        'platform service, app or UI code', () {
      final Directory dir = Directory('lib/security/intruder');
      final List<File> files = dir
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart'))
          .toList();
      expect(files, isNotEmpty);
      final RegExp import = RegExp(r"^import '([^']+)';", multiLine: true);
      for (final File f in files) {
        for (final RegExpMatch m in import.allMatches(f.readAsStringSync())) {
          final String target = m.group(1)!;
          expect(
            RegExp(r'(protection|rules|profiles|services|app|ui|flutter)/')
                .hasMatch(target),
            isFalse,
            reason: '${f.path} imports $target',
          );
        }
      }
    });
  });
}
