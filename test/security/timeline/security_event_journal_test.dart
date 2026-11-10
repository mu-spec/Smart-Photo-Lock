// Phase 13 / Milestone 1 — Security Event Database.
//
// SecurityEventJournal + store + strict codec: ciphertext only, corrupt /
// tampered / newer / unreadable rows, quarantine, bounded storage under a
// flood, retention, restart order, loss accounting and failure isolation
// of the producer API (corrections A/B/C/D/F).
//
// SIMULATED: pure Dart VM, in-memory storage, deterministic clocks.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/security/encryption/settings_cipher.dart';
import 'package:smart_app_lock/security/encryption/settings_cipher_impl.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';
import 'package:smart_app_lock/security/timeline/security_event_journal.dart';
import 'package:smart_app_lock/security/timeline/security_event_journal_store.dart';
import 'package:smart_app_lock/security/timeline/security_journal_event.dart';

const String _key = SecurityEventJournalStore.storageKey;
const String _qKey = SecurityEventJournalStore.quarantineKey;

/// Database with switchable faults on the journal keys.
class _FaultDb extends InMemoryLocalDatabase {
  bool failReads = false;
  bool failWrites = false;
  bool failQuarantineWrites = false;
  int writes = 0;

  @override
  Future<String?> getSetting(String key) async {
    if (failReads && (key == _key || key == _qKey)) {
      throw StateError('read fault');
    }
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) async {
    if (failWrites && key == _key) {
      throw StateError('write fault');
    }
    if (failQuarantineWrites && key == _qKey) {
      throw StateError('quarantine fault');
    }
    if (key == _key) writes++;
    return super.setSetting(key, value);
  }
}

class _ThrowingSink implements SecurityEventSink {
  int calls = 0;

  @override
  void record(SecurityJournalEventType type) {
    calls++;
    throw StateError('sink violated its contract');
  }
}

final DateTime _t0 = DateTime(2026, 10, 22, 12);

Map<String, Object?> _doc({
  int nextSeq = 1,
  int discarded = 0,
  int lost = 0,
  List<Object?>? events,
  int v = 1,
  String schema = SecurityJournalDocument.schema,
}) =>
    <String, Object?>{
      'schema': schema,
      'v': v,
      'nextSeq': nextSeq,
      'discarded': discarded,
      'lost': lost,
      'events': events ??
          <Object?>[
            <String, Object?>{
              'seq': 0,
              'at': _t0.millisecondsSinceEpoch,
              'type': 'journalStarted',
            },
          ],
    };

void main() {
  late _FaultDb db;
  late SettingsCipher cipher;
  late DateTime now;

  SecurityEventJournal journal({
    int maxEvents = SecurityEventJournal.defaultMaxEvents,
    int maxPending = SecurityEventJournal.defaultMaxPending,
    int maxBytes = SecurityEventJournal.defaultMaxEncodedBytes,
    SettingsCipher? withCipher,
    bool plaintext = false,
  }) =>
      SecurityEventJournal(
        store: SecurityEventJournalStore(db,
            cipher: plaintext ? null : (withCipher ?? cipher)),
        now: () => now,
        maxEvents: maxEvents,
        maxPending: maxPending,
        maxEncodedBytes: maxBytes,
      );

  Future<SecurityJournalDocument> stored({bool plaintext = false}) async {
    final SecurityJournalRead r =
        await SecurityEventJournalStore(db, cipher: plaintext ? null : cipher)
            .read();
    expect(r, isA<SecurityJournalLoaded>());
    return (r as SecurityJournalLoaded).document;
  }

  setUp(() {
    db = _FaultDb();
    cipher = AesGcmSettingsCipher(InMemorySecretStore());
    now = _t0;
  });

  group('codec (strict v1)', () {
    test('round-trips', () {
      final SecurityJournalDocument d = SecurityJournalDocument.fromJson(
          jsonDecode(jsonEncode(_doc(nextSeq: 5, discarded: 3, lost: 2))));
      expect(d.nextSeq, 5);
      expect(d.discarded, 3);
      expect(d.lost, 2);
      expect(d.events.single.type, SecurityJournalEventType.journalStarted);
      expect(SecurityJournalDocument.fromJson(d.toJson()).toJson(), d.toJson());
    });

    final Map<String, Map<String, Object?>> invalid =
        <String, Map<String, Object?>>{
      'unknown event type': _doc(events: <Object?>[
        <String, Object?>{'seq': 0, 'at': 1, 'type': 'successfulUnlock'},
      ]),
      'unknown event field': _doc(events: <Object?>[
        <String, Object?>{
          'seq': 0,
          'at': 1,
          'type': 'journalStarted',
          'pin': '1234',
        },
      ]),
      'unknown top-level field': <String, Object?>{..._doc(), 'x': 1},
      'seq not increasing': _doc(nextSeq: 3, events: <Object?>[
        <String, Object?>{'seq': 1, 'at': 1, 'type': 'journalStarted'},
        <String, Object?>{'seq': 1, 'at': 2, 'type': 'journalRecovered'},
      ]),
      'seq >= nextSeq': _doc(nextSeq: 0),
      'negative discarded': _doc(discarded: -1),
      'negative lost': _doc(lost: -1),
      'negative at': _doc(events: <Object?>[
        <String, Object?>{'seq': 0, 'at': -5, 'type': 'journalStarted'},
      ]),
      'string seq': _doc(events: <Object?>[
        <String, Object?>{'seq': '0', 'at': 1, 'type': 'journalStarted'},
      ]),
      'wrong schema': _doc(schema: 'sal.intruder_log'),
      'too many events': _doc(
        nextSeq: 2000,
        events: <Object?>[
          for (int i = 0; i < 1001; i++)
            <String, Object?>{'seq': i, 'at': 1, 'type': 'journalStarted'},
        ],
      ),
    };
    for (final MapEntry<String, Map<String, Object?>> c in invalid.entries) {
      test('rejects ${c.key}', () {
        expect(() => SecurityJournalDocument.fromJson(c.value),
            throwsFormatException);
      });
    }

    test('no event type for successful unlocks or routine usage (TL-4)', () {
      final Set<String> names = SecurityJournalEventType.values
          .map((SecurityJournalEventType t) => t.name.toLowerCase())
          .toSet();
      for (final String n in names) {
        expect(n.contains('success'), isFalse);
        expect(n.contains('unlocked'), isFalse);
        expect(n.contains('usage'), isFalse);
        expect(n.contains('opened'), isFalse);
      }
    });
  });

  group('storage', () {
    test(
        'startup is quiet: a missing journal is NOT created (no startup '
        'write)', () async {
      final SecurityEventJournal j = journal();
      await j.startup();
      expect(await db.getSetting(_key), isNull);
      expect(db.writes, 0);
      expect(j.health, SecurityJournalHealth.ok);
    });

    test(
        'first read creates an encrypted row with a journalStarted marker '
        '(ciphertext only, A1-2)', () async {
      final SecurityEventJournal j = journal();
      await j.startup();
      final SecurityJournalView v = await j.read();
      expect(v.events.single.type, SecurityJournalEventType.journalStarted);
      final String raw = (await db.getSetting(_key))!;
      expect(raw.startsWith('enc:v1:'), isTrue);
      expect(raw.contains('journalStarted'), isFalse);
      expect(raw.contains('sal.security_journal'), isFalse);
      final SecurityJournalDocument d = await stored();
      expect(d.events.single.type, SecurityJournalEventType.journalStarted);
      expect(d.events.single.at, _t0);
      expect(d.nextSeq, 1);
      expect(j.health, SecurityJournalHealth.ok);
    });

    test(
        'A-1: the marker is stamped at FIRST USE, not at construction or '
        'startup', () async {
      final SecurityEventJournal j = journal();
      await j.startup();
      now = _t0.add(const Duration(hours: 5));
      final SecurityJournalView v = await j.read();
      expect(v.events.single.at, _t0.add(const Duration(hours: 5)));
      expect(
          (await stored()).events.single.at, _t0.add(const Duration(hours: 5)));
    });

    test(
        'newer schema present at startup: zero writes to either journal key '
        'across startup and repeated reads', () async {
      final String raw =
          'enc:v1:${await cipher.encryptString(jsonEncode(_doc(v: 7)))}';
      await db.setSetting(_key, raw);
      db.writes = 0;
      final SecurityEventJournal j = journal();
      await j.startup();
      for (int i = 0; i < 3; i++) {
        expect((await j.read()).availability,
            SecurityJournalAvailability.unsupported);
      }
      j.record(SecurityJournalEventType.journalRecovered);
      await j.idle();
      expect(db.writes, 0);
      expect(await db.getSetting(_key), raw);
      expect(await db.getSetting(_qKey), isNull);
    });

    test(
        'corrupt row at startup: exactly one quarantine copy and one '
        'replacement write, nothing more on later reads', () async {
      await db.setSetting(_key, 'garbage');
      db.writes = 0;
      final SecurityEventJournal j = journal();
      await j.startup();
      expect(await db.getSetting(_qKey), 'garbage');
      expect(db.writes, 1);
      for (int i = 0; i < 3; i++) {
        await j.read();
      }
      await j.idle();
      expect(db.writes, 1);
    });

    test('a second instance (restart) does not add a second marker', () async {
      await journal().read();
      final SecurityEventJournal j2 = journal();
      await j2.startup();
      await j2.read();
      expect((await stored()).events.length, 1);
    });

    test(
        'plaintext where ciphertext belongs is corrupt: quarantined then '
        'reinitialized with journalRecovered', () async {
      await db.setSetting(_key, jsonEncode(_doc()));
      final SecurityEventJournal j = journal();
      await j.startup();
      expect(await db.getSetting(_qKey), jsonEncode(_doc()));
      expect(j.quarantinedCorruptJournal, isTrue);
      final SecurityJournalDocument d = await stored();
      expect(d.events.single.type, SecurityJournalEventType.journalRecovered);
    });

    test('GCM-tampered row is corrupt (A1-3)', () async {
      await journal().read();
      final String raw = (await db.getSetting(_key))!;
      final String flipped = raw.substring(0, raw.length - 3) +
          (raw[raw.length - 3] == 'A' ? 'B' : 'A') +
          raw.substring(raw.length - 2);
      await db.setSetting(_key, flipped);
      final SecurityEventJournal j = journal();
      await j.startup();
      expect(await db.getSetting(_qKey), flipped);
      expect((await stored()).events.single.type,
          SecurityJournalEventType.journalRecovered);
    });

    test('only the FIRST corrupt value is quarantined (bounded)', () async {
      await db.setSetting(_key, 'garbage-1');
      await journal().startup();
      await db.setSetting(_key, 'garbage-2');
      await journal().startup();
      expect(await db.getSetting(_qKey), 'garbage-1');
    });

    test('quarantine failure: corrupt row is NOT overwritten', () async {
      await db.setSetting(_key, 'garbage');
      db.failQuarantineWrites = true;
      final SecurityEventJournal j = journal();
      await j.startup();
      expect(await db.getSetting(_key), 'garbage');
      expect(await db.getSetting(_qKey), isNull);
      expect(j.health, SecurityJournalHealth.storageError);
      final SecurityJournalView v = await j.read();
      expect(v.availability, SecurityJournalAvailability.unreadable);
      // Recovers once quarantine works.
      db.failQuarantineWrites = false;
      final SecurityJournalView v2 = await j.read();
      expect(v2.availability, SecurityJournalAvailability.available);
      expect(await db.getSetting(_qKey), 'garbage');
    });

    test('newer schema is read-only and NEVER overwritten (A1-3)', () async {
      final String newer = '{"schema":"sal.security_journal","v":2,'
          '"nextSeq":9,"events":[{"seq":1,"futureField":true}]}';
      await db.setSetting(_key, newer);
      final SecurityEventJournal j = journal(plaintext: true);
      await j.startup();
      j.record(SecurityJournalEventType.journalRecovered);
      await j.idle();
      final SecurityJournalView v = await j.read();
      expect(v.availability, SecurityJournalAvailability.unsupported);
      expect(v.events, isEmpty);
      expect(v.lost, 1, reason: 'the unstorable event is counted, not hidden');
      expect(await db.getSetting(_key), newer);
      expect(await db.getSetting(_qKey), isNull);
      expect(j.health, SecurityJournalHealth.readOnly);
    });

    test('newer encrypted schema is read-only too', () async {
      final String json = jsonEncode(_doc(v: 7));
      final String raw = 'enc:v1:${await cipher.encryptString(json)}';
      await db.setSetting(_key, raw);
      final SecurityEventJournal j = journal();
      await j.startup();
      expect((await j.read()).availability,
          SecurityJournalAvailability.unsupported);
      expect(await db.getSetting(_key), raw);
    });

    test('ciphertext without a cipher is permanently unreadable, untouched',
        () async {
      await journal().read();
      final String raw = (await db.getSetting(_key))!;
      final SecurityEventJournal j = journal(plaintext: true);
      await j.startup();
      final SecurityJournalView v = await j.read();
      expect(v.availability, SecurityJournalAvailability.unreadable);
      expect(await db.getSetting(_key), raw);
      expect(j.health, SecurityJournalHealth.readOnly);
    });

    test(
        'transient read failure: unreadable (never empty), nothing written, '
        'retried next time', () async {
      await journal().read();
      final String raw = (await db.getSetting(_key))!;
      db.failReads = true;
      final SecurityEventJournal j = journal();
      await j.startup();
      final SecurityJournalView v = await j.read();
      expect(v.availability, SecurityJournalAvailability.unreadable);
      expect(v.events, isEmpty);
      db.failReads = false;
      expect(await db.getSetting(_key), raw);
      final SecurityJournalView v2 = await j.read();
      expect(v2.availability, SecurityJournalAvailability.available);
      expect(v2.events.single.type, SecurityJournalEventType.journalStarted);
    });
  });

  group('bounds (A1-4)', () {
    test(
        'flood of 1,000 appends in bursts: events, bytes and pending stay '
        'bounded; every drop is counted', () async {
      final SecurityEventJournal j = journal();
      await j.startup();
      for (int burst = 0; burst < 10; burst++) {
        for (int i = 0; i < 100; i++) {
          j.record(SecurityJournalEventType.journalRecovered);
        }
        await j.idle();
      }
      final SecurityJournalView v = await j.read();
      final SecurityJournalDocument d = await stored();
      final int accepted = d.nextSeq - 1; // minus the startup marker
      expect(accepted, 10 * SecurityEventJournal.defaultMaxPending);
      expect(accepted + v.lost, 1000, reason: 'overflow counted as lost');
      expect(v.lost, greaterThan(0));
      expect(d.lost, v.lost, reason: 'losses persisted on later writes');
      expect(d.events.length, SecurityEventJournal.defaultMaxEvents);
      expect(v.events.length, SecurityEventJournal.defaultMaxEvents);
      expect(d.discarded, d.nextSeq - d.events.length);
      expect(utf8.encode(SecurityEventJournalStore.encode(d)).length,
          lessThanOrEqualTo(SecurityEventJournal.defaultMaxEncodedBytes));
      expect(d.events.last.seq, d.nextSeq - 1);
    });

    test('count cap drops oldest first, seq strictly increasing', () async {
      final SecurityEventJournal j = journal(maxEvents: 5);
      await j.startup();
      for (int i = 0; i < 12; i++) {
        now = _t0.add(Duration(seconds: i + 1));
        j.record(SecurityJournalEventType.journalRecovered);
        await j.idle();
      }
      final SecurityJournalDocument d = await stored();
      expect(d.events.map((SecurityJournalEvent e) => e.seq),
          <int>[8, 9, 10, 11, 12]);
      expect(d.discarded, 8);
    });

    test('size cap drops oldest until it fits', () async {
      final SecurityEventJournal j = journal(maxBytes: 400);
      await j.startup();
      for (int i = 0; i < 20; i++) {
        j.record(SecurityJournalEventType.journalRecovered);
        await j.idle();
      }
      final SecurityJournalDocument d = await stored();
      expect(utf8.encode(SecurityEventJournalStore.encode(d)).length,
          lessThanOrEqualTo(400));
      expect(d.events.length + d.discarded, 21);
      expect(d.discarded, greaterThan(0));
    });

    test(
        '30-day retention drops and COUNTS old events; future-stamped '
        'events are kept', () async {
      final SecurityEventJournal j = journal();
      await j.read(); // creates the marker at t0
      now = _t0.add(const Duration(days: 2));
      j.record(SecurityJournalEventType.journalRecovered);
      await j.idle();
      // Clock moves backwards: new event stamped "earlier" than the last.
      now = _t0.subtract(const Duration(days: 1));
      j.record(SecurityJournalEventType.journalRecovered);
      await j.idle();
      // Restart 31 days after t0: only the t0 marker and the t0-1d event
      // are older than 30 days.
      now = _t0.add(const Duration(days: 31));
      final SecurityEventJournal j2 = journal();
      final SecurityJournalView v = await j2.read();
      expect(v.events.map((SecurityJournalEvent e) => e.seq), <int>[1]);
      expect(v.discarded, 2);
      expect((await stored()).discarded, 2);
    });
  });

  test('events stamped in the future (clock moved back) are never purged',
      () async {
    final SecurityEventJournal j = journal();
    now = _t0.add(const Duration(days: 10));
    await j.read(); // marker stamped t0 + 10 days
    now = _t0; // clock moved backwards by 10 days
    final SecurityJournalView v = await j.read();
    expect(v.events.single.type, SecurityJournalEventType.journalStarted);
    expect(v.discarded, 0);
  });

  group('restart and ordering (A1-1)', () {
    test('order and nextSeq survive a restart', () async {
      final SecurityEventJournal j = journal();
      await j.startup();
      for (int i = 0; i < 3; i++) {
        now = _t0.add(Duration(minutes: i));
        j.record(SecurityJournalEventType.journalRecovered);
      }
      await j.idle();
      final SecurityEventJournal j2 = journal(); // "process restart"
      await j2.startup();
      now = _t0.add(const Duration(minutes: 9));
      j2.record(SecurityJournalEventType.journalRecovered);
      await j2.idle();
      final SecurityJournalView v = await j2.read();
      expect(v.events.map((SecurityJournalEvent e) => e.seq),
          <int>[0, 1, 2, 3, 4]);
      expect(v.events.last.at, _t0.add(const Duration(minutes: 9)));
    });

    test('record stamps the OBSERVED time, not the write time', () async {
      final SecurityEventJournal j = journal();
      await j.startup();
      now = _t0.add(const Duration(hours: 1));
      j.record(SecurityJournalEventType.journalRecovered);
      now = _t0.add(const Duration(hours: 5)); // before the write runs
      await j.idle();
      expect(
          (await stored()).events.last.at, _t0.add(const Duration(hours: 1)));
    });
  });

  group('failure isolation (corrections A/B)', () {
    test(
        'record is synchronous and never throws, even with a throwing '
        'clock', () {
      final SecurityEventJournal j = SecurityEventJournal(
        store: SecurityEventJournalStore(db, cipher: cipher),
        now: () => throw StateError('clock fault'),
      );
      expect(() => j.record(SecurityJournalEventType.journalRecovered),
          returnsNormally);
      expect(j.pendingLost, 1);
    });

    test(
        'write failures are counted as lost and persisted on the next '
        'successful write', () async {
      final SecurityEventJournal j = journal();
      await j.startup();
      db.failWrites = true;
      j.record(SecurityJournalEventType.journalRecovered);
      j.record(SecurityJournalEventType.journalRecovered);
      await j.idle();
      expect(j.health, SecurityJournalHealth.storageError);
      expect(j.pendingLost, 2);
      db.failWrites = false;
      j.record(SecurityJournalEventType.journalRecovered);
      await j.idle();
      final SecurityJournalDocument d = await stored();
      expect(d.lost, 2);
      expect(d.events.length, 2);
      expect(j.pendingLost, 0);
      expect(j.health, SecurityJournalHealth.ok);
    });

    test('queue overflow is counted, never blocks', () async {
      final SecurityEventJournal j = journal(maxPending: 3);
      await j.startup();
      final Stopwatch sw = Stopwatch()..start();
      for (int i = 0; i < 50; i++) {
        j.record(SecurityJournalEventType.journalRecovered);
      }
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(1000));
      expect(j.pendingLost, 47);
      await j.idle();
      final SecurityJournalView v = await j.read();
      expect(v.lost, 47);
      expect(v.events.length, 4);
    });

    test(
        'recordSecurityEventSafely contains a sink that throws '
        'synchronously', () {
      final _ThrowingSink sink = _ThrowingSink();
      expect(
          () => recordSecurityEventSafely(
              sink, SecurityJournalEventType.journalRecovered),
          returnsNormally);
      expect(sink.calls, 1);
      expect(
          () => recordSecurityEventSafely(
              null, SecurityJournalEventType.journalRecovered),
          returnsNormally);
    });

    test('async storage failure never escapes as an unhandled error', () async {
      final List<Object> errors = <Object>[];
      await runZonedGuarded(() async {
        db.failReads = true;
        db.failWrites = true;
        final SecurityEventJournal j = journal();
        unawaited(j.startup());
        for (int i = 0; i < 10; i++) {
          j.record(SecurityJournalEventType.journalRecovered);
        }
        await j.idle();
        await j.read();
        await j.idle();
      }, (Object e, StackTrace _) => errors.add(e));
      expect(errors, isEmpty);
    });
  });

  group('source invariants', () {
    test('journal sources import nothing from enforcement, UI or platform', () {
      final Directory dir = Directory('lib/security/timeline');
      for (final FileSystemEntity f in dir.listSync()) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final String src = f.readAsStringSync();
        for (final String banned in <String>[
          'package:flutter',
          'dart:ui',
          'dart:io',
          'protection/',
          'credential_manager',
          'lock_host',
          'access_controller',
          'MethodChannel',
          'print(',
          'debugPrint',
          'developer.log',
        ]) {
          expect(src.contains(banned), isFalse,
              reason: '${f.path} must not contain "$banned"');
        }
      }
    });

    test(
        'timeline screen has no print / log / clipboard / share / export / '
        'network / selectable-text paths (A1-7)', () {
      final String src =
          File('lib/ui/screens/security/security_timeline_screen.dart')
              .readAsStringSync();
      for (final String banned in <String>[
        'print(',
        'debugPrint',
        'developer.log',
        'dart:developer',
        'Clipboard',
        'services.dart',
        'Share',
        'share_plus',
        'SelectableText',
        'dart:io',
        'http',
        'MethodChannel',
        'setSecureWindow(false)',
      ]) {
        expect(src.contains(banned), isFalse,
            reason: 'timeline screen must not contain "$banned"');
      }
    });

    test('nothing in enforcement imports the journal or the timeline', () {
      for (final String root in <String>[
        'lib/protection',
        'lib/security/credentials',
        'lib/security/intruder',
        'lib/ui/screens/lock',
      ]) {
        final Directory d = Directory(root);
        if (!d.existsSync()) continue;
        for (final FileSystemEntity f in d.listSync(recursive: true)) {
          if (f is! File || !f.path.endsWith('.dart')) continue;
          final String src = f.readAsStringSync();
          expect(src.contains('security/timeline/'), isFalse,
              reason: '${f.path} must not depend on the timeline');
          expect(src.contains('timeline/security_'), isFalse,
              reason: '${f.path} must not depend on the timeline');
        }
      }
    });
  });
}
