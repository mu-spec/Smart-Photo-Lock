// Phase 13 / Milestone 1 — SecurityTimeline read model.
//
// Merge order, explicit unavailable states (never "empty"), completeness
// notices (discarded / lost / damaged / integrity unknown), restart, and
// the read-only guarantee over the real AppContainer wiring (correction E:
// failure log, credential counters, lockout state and evidence rows are
// byte-identical across timeline loads).
//
// SIMULATED: pure Dart VM over AppContainer.inMemory and in-memory storage.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/app/app_container.dart';
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
import 'package:smart_app_lock/security/timeline/security_event_journal.dart';
import 'package:smart_app_lock/security/timeline/security_event_journal_store.dart';
import 'package:smart_app_lock/security/timeline/security_journal_event.dart';
import 'package:smart_app_lock/security/timeline/security_timeline.dart';
import 'package:smart_app_lock/services/impl/static_intruder_evidence_service.dart';

const String _pin = '482916';
final DateTime _t0 = DateTime(2026, 10, 22, 12);

class _FaultDb extends InMemoryLocalDatabase {
  final Set<String> failReadKeys = <String>{};

  @override
  Future<String?> getSetting(String key) async {
    if (failReadKeys.contains(key)) {
      throw StateError('read fault');
    }
    return super.getSetting(key);
  }
}

class _RecordingDb extends InMemoryLocalDatabase {
  final List<String> writes = <String>[];

  @override
  Future<void> setSetting(String key, String value) {
    writes.add(key);
    return super.setSetting(key, value);
  }
}

int _vid = 0;

VerifiedAttempt _wrong({DateTime? at, AuthAttemptContext? context}) =>
    VerifiedAttempt(
      verificationId: 'tl:${++_vid}',
      type: AuthType.pin,
      matched: false,
      result: const AuthFailure(
        reason: AuthFailureReason.wrongCredential,
        remainingAttempts: 2,
      ),
      counterPersisted: true,
      lockoutStreak: 0,
      context: context ?? AuthAttemptContext.smartAppLock,
      at: at ?? _t0,
    );

TimelineEntry _e(TimelineSource s, int seq, DateTime at) => TimelineEntry(
      source: s,
      sourceSeq: seq,
      at: at,
      kind: s == TimelineSource.journal
          ? TimelineEntryKind.journalStarted
          : TimelineEntryKind.failedUnlock,
    );

void main() {
  group('ordering', () {
    test('newest first; equal times: journal before failures, then seq desc',
        () {
      final List<TimelineEntry> list = <TimelineEntry>[
        _e(TimelineSource.failedAttempts, 1, _t0),
        _e(TimelineSource.journal, 0, _t0),
        _e(TimelineSource.failedAttempts, 2, _t0),
        _e(TimelineSource.failedAttempts, 0,
            _t0.add(const Duration(seconds: 1))),
        _e(TimelineSource.journal, 1, _t0.subtract(const Duration(days: 1))),
      ]..sort(SecurityTimelineReader.compare);
      expect(
          list.map((TimelineEntry e) => '${e.source.name}:${e.sourceSeq}'),
          <String>[
            'failedAttempts:0',
            'journal:0',
            'failedAttempts:2',
            'failedAttempts:1',
            'journal:1',
          ]);
    });

    test('total order: sorting any permutation gives the same result', () {
      final List<TimelineEntry> base = <TimelineEntry>[
        for (int i = 0; i < 6; i++)
          _e(i.isEven ? TimelineSource.journal : TimelineSource.failedAttempts,
              i ~/ 2, _t0.add(Duration(seconds: i % 3))),
      ];
      final List<String> expected = (List<TimelineEntry>.of(base)
            ..sort(SecurityTimelineReader.compare))
          .map((TimelineEntry e) => '${e.source.name}:${e.sourceSeq}')
          .toList();
      for (int r = 0; r < 20; r++) {
        final List<TimelineEntry> p = List<TimelineEntry>.of(base)
          ..shuffle()
          ..sort(SecurityTimelineReader.compare);
        expect(p.map((TimelineEntry e) => '${e.source.name}:${e.sourceSeq}'),
            expected);
      }
    });
  });

  group('sources (component wiring)', () {
    late _FaultDb db;
    late SettingsCipher cipher;
    late IntruderMonitor monitor;
    late SecurityEventJournal journal;
    late SecurityEventJournalStore jStore;

    SecurityTimelineReader reader() => SecurityTimelineReader(
          monitor: monitor,
          journal: journal,
          journalStore: jStore,
          database: db,
        );

    setUp(() {
      db = _FaultDb();
      cipher = AesGcmSettingsCipher(InMemorySecretStore());
      monitor = IntruderMonitor(
        store: IntruderFailureLogStore(db, cipher: cipher),
        now: () => _t0,
        maxEvents: 3,
      );
      jStore = SecurityEventJournalStore(db, cipher: cipher);
      journal = SecurityEventJournal(store: jStore, now: () => _t0);
    });

    test('merges failures and journal; reports discarded = nextSeq - kept',
        () async {
      for (int i = 0; i < 5; i++) {
        monitor.onVerifiedAttempt(_wrong(
          at: _t0.add(Duration(minutes: i)),
          context: const AuthAttemptContext.protectedAppChallenge(
            packageName: 'com.bank.app',
            generation: 1,
            challengeSerial: 1,
          ),
        ));
      }
      await monitor.idle();
      await journal.startup();
      final SecurityTimelineSnapshot s = await reader().load();
      expect(s.entries.length, 4);
      expect(s.entries.first.kind, TimelineEntryKind.failedUnlock);
      expect(s.entries.first.packageName, 'com.bank.app');
      expect(s.entries.first.sourceSeq, 4);
      expect(s.entries.last.kind, TimelineEntryKind.journalStarted);
      final TimelineSourceStatus f = s.sources[0];
      expect(f.source, TimelineSource.failedAttempts);
      expect(f.available, isTrue);
      expect(f.discarded, 2);
      expect(f.damagedEarlier, isFalse);
      expect(s.sources[1].available, isTrue);
      expect(s.confirmedEmpty, isFalse);
      expect(s.hasGaps, isTrue);
    });

    test('Smart App Lock surface never carries a package', () async {
      monitor.onVerifiedAttempt(_wrong());
      await monitor.idle();
      final SecurityTimelineSnapshot s = await reader().load();
      final TimelineEntry e = s.entries.firstWhere(
          (TimelineEntry e) => e.source == TimelineSource.failedAttempts);
      expect(e.surface, AuthAttemptSurface.smartAppLock);
      expect(e.packageName, isNull);
      expect(e.method, FailedAttemptMethod.pin);
    });

    test('both sources empty and readable -> confirmedEmpty only then',
        () async {
      // Journal read creates its marker; check the failure-log side alone.
      final SecurityTimelineSnapshot s = await reader().load();
      expect(s.sources[0].available, isTrue);
      expect(
          s.entries.where(
              (TimelineEntry e) => e.source == TimelineSource.failedAttempts),
          isEmpty);
      expect(s.allSourcesAvailable, isTrue);
    });

    test('newer failure log -> unavailableNewerVersion, NOT empty (C)',
        () async {
      final String json = jsonEncode(<String, Object?>{
        'schema': 'sal.intruder_log',
        'v': 9,
        'nextSeq': 4,
        'events': <Object?>[],
      });
      await db.setSetting(IntruderFailureLogStore.storageKey,
          'enc:v1:${await cipher.encryptString(json)}');
      final SecurityTimelineSnapshot s = await reader().load();
      expect(s.sources[0].state, TimelineSourceState.unavailableNewerVersion);
      expect(s.allSourcesAvailable, isFalse);
      expect(s.confirmedEmpty, isFalse);
    });

    test('unreadable failure log -> unavailableUnreadable, NOT empty (C)',
        () async {
      db.failReadKeys.add(IntruderFailureLogStore.storageKey);
      final SecurityTimelineSnapshot s = await reader().load();
      expect(s.sources[0].state, TimelineSourceState.unavailableUnreadable);
      expect(s.confirmedEmpty, isFalse);
      expect(s.hasGaps, isTrue);
    });

    test('unreadable journal -> unavailableUnreadable, failures still shown',
        () async {
      monitor.onVerifiedAttempt(_wrong());
      await monitor.idle();
      db.failReadKeys.add(SecurityEventJournalStore.storageKey);
      final SecurityTimelineSnapshot s = await reader().load();
      expect(s.sources[1].state, TimelineSourceState.unavailableUnreadable);
      expect(s.entries.single.kind, TimelineEntryKind.failedUnlock);
      expect(s.confirmedEmpty, isFalse);
    });

    test(
        'BOTH sources unreadable and zero entries -> never confirmedEmpty '
        '(C)', () async {
      db.failReadKeys
        ..add(IntruderFailureLogStore.storageKey)
        ..add(SecurityEventJournalStore.storageKey);
      final SecurityTimelineSnapshot s = await reader().load();
      expect(s.entries, isEmpty);
      expect(s.allSourcesAvailable, isFalse);
      expect(s.confirmedEmpty, isFalse);
    });

    test(
        'quarantine present -> damagedEarlier; unreadable marker -> null '
        '(never assumed clean, D)', () async {
      await db.setSetting(IntruderFailureLogStore.quarantineKey, 'old');
      SecurityTimelineSnapshot s = await reader().load();
      expect(s.sources[0].damagedEarlier, isTrue);
      expect(s.sources[1].damagedEarlier, isFalse);
      db.failReadKeys.add(SecurityEventJournalStore.quarantineKey);
      s = await reader().load();
      expect(s.sources[1].damagedEarlier, isNull);
      expect(s.hasGaps, isTrue);
    });

    test('corrupt journal -> journalRecovered entry + damagedEarlier',
        () async {
      await db.setSetting(SecurityEventJournalStore.storageKey, 'garbage');
      final SecurityTimelineSnapshot s = await reader().load();
      expect(s.entries.single.kind, TimelineEntryKind.journalRecovered);
      expect(s.sources[1].damagedEarlier, isTrue);
    });

    test('journal lost / discarded counts are surfaced', () async {
      final SecurityEventJournal small = SecurityEventJournal(
          store: jStore, now: () => _t0, maxEvents: 2, maxPending: 2);
      journal = small;
      await small.startup();
      for (int i = 0; i < 6; i++) {
        small.record(SecurityJournalEventType.journalRecovered);
      }
      await small.idle();
      final SecurityTimelineSnapshot s = await reader().load();
      expect(s.sources[1].lost, 4);
      expect(s.sources[1].discarded, 1);
    });

    test('dropped failure events this session are surfaced as lost', () async {
      final IntruderMonitor m = IntruderMonitor(
        store: IntruderFailureLogStore(db, cipher: cipher),
        now: () => _t0,
        maxPending: 1,
      );
      monitor = m;
      for (int i = 0; i < 4; i++) {
        m.onVerifiedAttempt(_wrong());
      }
      await m.idle();
      final SecurityTimelineSnapshot s = await reader().load();
      expect(s.sources[0].lost, m.status.droppedEvents);
      expect(s.sources[0].lost, greaterThan(0));
    });
  });

  group('real container', () {
    test(
        'REGRESSION: container startup performs NO journal write (startup '
        'is quiet; other components\' "touches only its own key" '
        'guarantees stay intact)', () async {
      final _RecordingDb db = _RecordingDb();
      final AppContainer c = AppContainer.inMemory(
        intruderEvidence: StaticIntruderEvidenceService(),
        database: db,
      );
      await c.intruderStartup;
      await c.securityJournalStartup;
      await c.securityJournal.idle();
      expect(
          db.writes.where((String k) => k.startsWith('security_event_journal')),
          isEmpty);
      // First timeline use creates it.
      await c.securityTimeline.load();
      expect(db.writes, contains(SecurityEventJournalStore.storageKey));
    });

    test(
        'read-only: every non-journal settings row is byte-identical across '
        'loads, including failure log, counters and lockout (E)', () async {
      final InMemoryLocalDatabase db = InMemoryLocalDatabase();
      final AppContainer c = AppContainer.inMemory(
        intruderEvidence: StaticIntruderEvidenceService(),
        database: db,
      );
      await c.intruderStartup;
      await c.securityJournalStartup;
      await c.auth.enrollPin(_pin);
      // App lockout threshold is 3 counted failures; later attempts are
      // lockout-blocked and (correctly) not recorded as failures.
      for (int i = 0; i < 5; i++) {
        await c.auth.authenticatePin('000000');
      }
      await c.intruderMonitor.idle();
      expect((await c.auth.status()).valueOrNull!.lockedOutUntil, isNotNull);
      final int recorded = (await c.intruderMonitor.snapshot())!.events.length;
      expect(recorded, 3);
      Map<String, String> rows(Map<String, String> all) => <String, String>{
            for (final MapEntry<String, String> e in all.entries)
              if (!e.key.startsWith('security_event_journal')) e.key: e.value,
          };
      final Map<String, String> before = rows(await db.getAllSettings());
      expect(before.containsKey(IntruderFailureLogStore.storageKey), isTrue);
      for (int i = 0; i < 3; i++) {
        final SecurityTimelineSnapshot s = await c.securityTimeline.load();
        expect(
            s.entries
                .where((TimelineEntry e) =>
                    e.kind == TimelineEntryKind.failedUnlock)
                .length,
            recorded);
      }
      await c.intruderMonitor.idle();
      await c.securityJournal.idle();
      expect(rows(await db.getAllSettings()), before);
    });

    Future<(AppContainer, _RecordingDb)> restartWith(
        Future<String> Function(AppContainer first) seed) async {
      final _RecordingDb db = _RecordingDb();
      final InMemorySecretStore secrets = InMemorySecretStore();
      final AppContainer c1 = AppContainer.inMemory(
          database: db,
          secretStore: secrets,
          intruderEvidence: StaticIntruderEvidenceService());
      await c1.securityJournalStartup;
      await db.setSetting(SecurityEventJournalStore.storageKey, await seed(c1));
      db.writes.clear();
      final AppContainer c2 = AppContainer.inMemory(
          database: db,
          secretStore: secrets,
          intruderEvidence: StaticIntruderEvidenceService());
      await c2.intruderStartup;
      await c2.securityJournalStartup;
      return (c2, db);
    }

    Iterable<String> journalWrites(_RecordingDb db) =>
        db.writes.where((String k) => k.startsWith('security_event_journal'));

    test(
        'newer-schema journal at container startup: no journal write at '
        'startup or across loads; row unchanged; shown as unavailable',
        () async {
      late String raw;
      final (AppContainer c, _RecordingDb db) =
          await restartWith((AppContainer c1) async {
        final String json = jsonEncode(<String, Object?>{
          'schema': SecurityJournalDocument.schema,
          'v': 9,
          'nextSeq': 1,
          'discarded': 0,
          'lost': 0,
          'events': <Object?>[],
        });
        return raw = 'enc:v1:${await c1.settingsCipher.encryptString(json)}';
      });
      expect(journalWrites(db), isEmpty);
      for (int i = 0; i < 3; i++) {
        final SecurityTimelineSnapshot s = await c.securityTimeline.load();
        expect(s.sources[TimelineSource.journal.index].state,
            TimelineSourceState.unavailableNewerVersion);
        expect(s.confirmedEmpty, isFalse);
      }
      await c.securityJournal.idle();
      expect(journalWrites(db), isEmpty);
      expect(await db.getSetting(SecurityEventJournalStore.storageKey), raw);
    });

    test(
        'corrupt journal at container startup: only the quarantine copy and '
        'the replacement are written; damage disclosed', () async {
      final (AppContainer c, _RecordingDb db) =
          await restartWith((_) async => 'not-a-journal');
      await c.securityJournal.idle();
      expect(journalWrites(db), <String>[
        SecurityEventJournalStore.quarantineKey,
        SecurityEventJournalStore.storageKey,
      ]);
      final SecurityTimelineSnapshot s = await c.securityTimeline.load();
      expect(s.sources[TimelineSource.journal.index].damagedEarlier, isTrue);
      expect(
          s.entries.where((TimelineEntry e) =>
              e.kind == TimelineEntryKind.journalRecovered),
          hasLength(1));
      await c.securityJournal.idle();
      expect(journalWrites(db), hasLength(2));
    });

    test('journal survives a process restart (shared DB + secret store)',
        () async {
      final InMemoryLocalDatabase db = InMemoryLocalDatabase();
      final InMemorySecretStore secrets = InMemorySecretStore();
      final AppContainer c1 = AppContainer.inMemory(
          database: db,
          secretStore: secrets,
          intruderEvidence: StaticIntruderEvidenceService());
      await c1.securityJournalStartup;
      await c1.auth.enrollPin(_pin);
      await c1.auth.authenticatePin('000000');
      await c1.intruderMonitor.idle();
      final List<String> first = (await c1.securityTimeline.load())
          .entries
          .map((TimelineEntry e) => '${e.source.name}:${e.sourceSeq}')
          .toList();
      final AppContainer c2 = AppContainer.inMemory(
          database: db,
          secretStore: secrets,
          intruderEvidence: StaticIntruderEvidenceService());
      await c2.securityJournalStartup;
      final SecurityTimelineSnapshot s = await c2.securityTimeline.load();
      expect(
          s.entries.map((TimelineEntry e) => '${e.source.name}:${e.sourceSeq}'),
          first);
      expect(s.allSourcesAvailable, isTrue);
      expect(
          s.entries.where(
              (TimelineEntry e) => e.kind == TimelineEntryKind.journalStarted),
          hasLength(1),
          reason: 'restart must not add a second start marker');
    });
  });
}
