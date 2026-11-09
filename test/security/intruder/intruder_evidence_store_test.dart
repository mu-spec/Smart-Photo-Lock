// Phase 12 / M2 — encrypted evidence store + owner settings store.
// SIMULATED: Dart VM, in-memory database, real AES-GCM cipher over an
// in-memory secret store (the Keystore is not exercised).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/security/encryption/settings_cipher.dart';
import 'package:smart_app_lock/security/encryption/settings_cipher_impl.dart';
import 'package:smart_app_lock/security/intruder/intruder_defense_settings.dart';
import 'package:smart_app_lock/security/intruder/intruder_evidence_store.dart';
import 'package:smart_app_lock/security/intruder/intruder_failure_log_store.dart';
import 'package:smart_app_lock/security/storage/impl/in_memory_secret_store.dart';

import '../../support/intruder_fixtures.dart';

class _FailingDb extends InMemoryLocalDatabase {
  bool failIndexWrite = false;
  bool failReads = false;

  @override
  Future<String?> getSetting(String key) async {
    if (failReads) throw StateError('read fault');
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) async {
    if (failIndexWrite && key == IntruderEvidenceStore.indexKey) {
      throw StateError('disk full');
    }
    return super.setSetting(key, value);
  }
}

class _BrokenCipher implements SettingsCipher {
  @override
  Future<String> encryptString(String plaintext) async =>
      throw StateError('keystore unavailable');

  @override
  Future<String> decryptString(String ciphertext) async =>
      throw StateError('keystore unavailable');
}

void main() {
  late InMemoryLocalDatabase db;
  late SettingsCipher cipher;
  late DateTime now;

  setUp(() {
    db = InMemoryLocalDatabase();
    cipher = AesGcmSettingsCipher(InMemorySecretStore());
    now = DateTime(2026, 10, 22, 12);
  });

  IntruderEvidenceStore store({
    int maxItems = IntruderEvidenceStore.defaultMaxItems,
    int maxTotalBytes = IntruderEvidenceStore.defaultMaxTotalBytes,
    int maxImageBytes = IntruderEvidenceStore.defaultMaxImageBytes,
  }) =>
      IntruderEvidenceStore(db, cipher,
          now: () => now,
          maxItems: maxItems,
          maxTotalBytes: maxTotalBytes,
          maxImageBytes: maxImageBytes);

  group('JpegSanitizer', () {
    test('strips APP1..APP15 and COM, keeps APP0, tables and scan data', () {
      final Uint8List src = jpegWithMetadata();
      expect(containsAscii(src, secretExif), isTrue);
      final Uint8List out = JpegSanitizer.strip(src)!;
      expect(containsAscii(out, secretExif), isFalse);
      expect(containsAscii(out, secretComment), isFalse);
      expect(containsAscii(out, 'JFIF'), isTrue);
      expect(JpegSanitizer.looksLikeJpeg(out), isTrue);
      expect(out.length, lessThan(src.length));
    });

    test('rejects non-JPEG, truncated segments and a missing scan', () {
      expect(JpegSanitizer.strip(Uint8List.fromList(utf8.encode('GIF89a..'))),
          isNull);
      final Uint8List good = jpegWithMetadata();
      // Corrupt the APP0 length so it runs past the end.
      final Uint8List bad = Uint8List.fromList(good)..[4] = 0x7F;
      expect(JpegSanitizer.strip(bad), isNull);
      expect(
          JpegSanitizer.strip(
              Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9])),
          isNull);
      expect(JpegSanitizer.strip(Uint8List(0)), isNull);
    });
  });

  group('IntruderEvidenceStore', () {
    test('save -> readImage round-trips the sanitized image under the M1 seq',
        () async {
      final IntruderEvidenceStore s = store();
      expect(
          await s.save(seq: 7, jpeg: jpegWithMetadata(), packageName: 'com.x'),
          EvidenceSaveResult.saved);
      final List<EvidenceItem> items = await s.list();
      expect(items.single.seq, 7);
      expect(items.single.packageName, 'com.x');
      expect(items.single.at, now);
      final Uint8List img = (await s.readImage(7))!;
      expect(img, JpegSanitizer.strip(jpegWithMetadata()));
      expect(items.single.bytes, img.length);
      expect(await s.readImage(8), isNull);
      expect(await s.contains(7), isTrue);
    });

    test('everything at rest is ciphertext: no image, EXIF or package leaks',
        () async {
      await store()
          .save(seq: 3, jpeg: jpegWithMetadata(), packageName: 'com.leak');
      final Map<String, String> all = await db.getAllSettings();
      expect(all.keys.toSet(), <String>{
        IntruderEvidenceStore.indexKey,
        IntruderEvidenceStore.blobKey(3),
      });
      final String b64 = base64Encode(JpegSanitizer.strip(jpegWithMetadata())!);
      for (final String v in all.values) {
        expect(v, startsWith('enc:v1:'));
        expect(v, isNot(contains('com.leak')));
        expect(v, isNot(contains(b64.substring(0, 24))));
        expect(v, isNot(contains(secretExif)));
      }
    });

    test(
        'invalid, oversized, negative-seq and duplicate saves write nothing new',
        () async {
      final IntruderEvidenceStore s = store(maxImageBytes: 200);
      expect(await s.save(seq: 1, jpeg: Uint8List.fromList(<int>[1, 2, 3])),
          EvidenceSaveResult.invalidImage);
      expect(await s.save(seq: 1, jpeg: jpegWithMetadata(padding: 500)),
          EvidenceSaveResult.oversized);
      expect(await s.save(seq: -1, jpeg: jpegWithMetadata()),
          EvidenceSaveResult.invalidImage);
      expect(await db.getAllSettings(), isEmpty);

      expect(await s.save(seq: 1, jpeg: jpegWithMetadata(fill: 0x22)),
          EvidenceSaveResult.saved);
      final Uint8List first = (await s.readImage(1))!;
      expect(await s.save(seq: 1, jpeg: jpegWithMetadata(fill: 0x33)),
          EvidenceSaveResult.duplicate);
      expect(await s.readImage(1), first, reason: 'never overwritten');
      expect(() => IntruderEvidenceStore.blobKey(-1), throwsArgumentError);
    });

    test('count bound evicts the OLDEST seq and deletes its blob', () async {
      final IntruderEvidenceStore s = store(maxItems: 3);
      for (int seq = 10; seq < 15; seq++) {
        expect(await s.save(seq: seq, jpeg: jpegWithMetadata()),
            EvidenceSaveResult.saved);
      }
      expect(
          (await s.list()).map((EvidenceItem e) => e.seq), <int>[12, 13, 14]);
      final Map<String, String> all = await db.getAllSettings();
      expect(all.containsKey(IntruderEvidenceStore.blobKey(10)), isFalse);
      expect(all.containsKey(IntruderEvidenceStore.blobKey(11)), isFalse);
      expect(
          all.keys.where(
              (String k) => k.startsWith(IntruderEvidenceStore.blobPrefix)),
          hasLength(3));
    });

    test('eviction is by seq, not wall clock (clock moved backwards)',
        () async {
      final IntruderEvidenceStore s = store(maxItems: 2);
      await s.save(seq: 1, jpeg: jpegWithMetadata());
      now = now.subtract(const Duration(hours: 5)); // clock set back
      await s.save(seq: 2, jpeg: jpegWithMetadata());
      await s.save(seq: 3, jpeg: jpegWithMetadata());
      expect((await s.list()).map((EvidenceItem e) => e.seq), <int>[2, 3]);
    });

    test('total-bytes bound evicts until the total fits', () async {
      final int one = JpegSanitizer.strip(jpegWithMetadata())!.length;
      final IntruderEvidenceStore s = store(maxTotalBytes: one * 2 + 1);
      for (int seq = 0; seq < 4; seq++) {
        await s.save(seq: seq, jpeg: jpegWithMetadata());
      }
      final List<EvidenceItem> items = await s.list();
      expect(items.map((EvidenceItem e) => e.seq), <int>[2, 3]);
      expect(items.fold<int>(0, (int a, EvidenceItem e) => a + e.bytes),
          lessThanOrEqualTo(one * 2 + 1));
    });

    test('30-day retention removes expired evidence on the next save',
        () async {
      final IntruderEvidenceStore s = store();
      await s.save(seq: 1, jpeg: jpegWithMetadata());
      now = now.add(const Duration(days: 31));
      await s.save(seq: 2, jpeg: jpegWithMetadata());
      expect((await s.list()).map((EvidenceItem e) => e.seq), <int>[2]);
      expect(
          (await db.getAllSettings())
              .containsKey(IntruderEvidenceStore.blobKey(1)),
          isFalse);
    });

    test('a corrupt index is quarantined once and the store starts empty',
        () async {
      await db.setSetting(IntruderEvidenceStore.indexKey, 'enc:v1:garbage');
      final IntruderEvidenceStore s = store();
      expect(await s.list(), isEmpty);
      expect(await db.getSetting(IntruderEvidenceStore.quarantineKey),
          'enc:v1:garbage');
      expect(await s.save(seq: 1, jpeg: jpegWithMetadata()),
          EvidenceSaveResult.saved);
      await db.setSetting(IntruderEvidenceStore.indexKey, 'plaintext-corrupt');
      expect(await s.list(), isEmpty);
      expect(await db.getSetting(IntruderEvidenceStore.quarantineKey),
          'enc:v1:garbage',
          reason: 'first quarantine is kept');
    });

    test('a NEWER schema is read-only: never overwritten, swept or appended',
        () async {
      final String newer =
          'enc:v1:${await cipher.encryptString(jsonEncode(<String, Object?>{
            'v': 2,
            'items': <Object?>[]
          }))}';
      await db.setSetting(IntruderEvidenceStore.indexKey, newer);
      await db.setSetting(IntruderEvidenceStore.blobKey(99), 'enc:v1:future');
      final IntruderEvidenceStore s = store();
      expect(await s.health(), EvidenceIndexHealth.unsupported);
      expect(await s.save(seq: 1, jpeg: jpegWithMetadata()),
          EvidenceSaveResult.unsupportedSchema);
      expect(await s.sweepOrphans(), 0);
      expect(await db.getSetting(IntruderEvidenceStore.indexKey), newer);
      expect(await db.getSetting(IntruderEvidenceStore.blobKey(99)),
          'enc:v1:future');
      expect(await db.getSetting(IntruderEvidenceStore.blobKey(1)), isNull);
    });

    test('a failed index write rolls the blob back (no partial evidence)',
        () async {
      final _FailingDb fdb = _FailingDb();
      final IntruderEvidenceStore s =
          IntruderEvidenceStore(fdb, cipher, now: () => now);
      await s.save(seq: 1, jpeg: jpegWithMetadata());
      fdb.failIndexWrite = true;
      expect(await s.save(seq: 2, jpeg: jpegWithMetadata()),
          EvidenceSaveResult.storageFailed);
      fdb.failIndexWrite = false;
      expect((await s.list()).map((EvidenceItem e) => e.seq), <int>[1]);
      expect(await fdb.getSetting(IntruderEvidenceStore.blobKey(2)), isNull);
    });

    test('an unreadable database fails the save without writing', () async {
      final _FailingDb fdb = _FailingDb()..failReads = true;
      final IntruderEvidenceStore s =
          IntruderEvidenceStore(fdb, cipher, now: () => now);
      expect(await s.save(seq: 1, jpeg: jpegWithMetadata()),
          EvidenceSaveResult.storageFailed);
      fdb.failReads = false;
      expect(await fdb.getAllSettings(), isEmpty);
    });

    test(
        'an unavailable Keystore cipher stores nothing (no plaintext fallback)',
        () async {
      final IntruderEvidenceStore s =
          IntruderEvidenceStore(db, _BrokenCipher(), now: () => now);
      expect(await s.save(seq: 1, jpeg: jpegWithMetadata()),
          EvidenceSaveResult.encryptionFailed);
      expect(await db.getSetting(IntruderEvidenceStore.blobKey(1)), isNull);
    });

    test('sweepOrphans removes crash leftovers and dangling index entries',
        () async {
      final IntruderEvidenceStore s = store();
      await s.save(seq: 1, jpeg: jpegWithMetadata());
      await s.save(seq: 2, jpeg: jpegWithMetadata());
      // Crash after the blob write, before the index write:
      await db.setSetting(IntruderEvidenceStore.blobKey(3), 'enc:v1:orphan');
      // A blob lost underneath the index:
      await db.removeSetting(IntruderEvidenceStore.blobKey(2));
      expect(await s.sweepOrphans(), 1);
      expect(await db.getSetting(IntruderEvidenceStore.blobKey(3)), isNull);
      expect((await s.list()).map((EvidenceItem e) => e.seq), <int>[1]);
    });

    test('concurrent saves are serialized; the index stays consistent',
        () async {
      final IntruderEvidenceStore s = store();
      final List<EvidenceSaveResult> r =
          await Future.wait(<Future<EvidenceSaveResult>>[
        for (int seq = 0; seq < 6; seq++)
          s.save(seq: seq, jpeg: jpegWithMetadata()),
        s.save(seq: 2, jpeg: jpegWithMetadata()),
      ]);
      expect(r.where((EvidenceSaveResult x) => x == EvidenceSaveResult.saved),
          hasLength(6));
      expect(r.last, EvidenceSaveResult.duplicate);
      expect((await s.list()).map((EvidenceItem e) => e.seq),
          <int>[0, 1, 2, 3, 4, 5]);
    });

    test('never touches the M1 failure log or unrelated settings', () async {
      await db.setSetting(IntruderFailureLogStore.storageKey, 'M1-LOG');
      await db.setSetting('security_settings', 'CREDENTIALS');
      final IntruderEvidenceStore s = store(maxItems: 1);
      await s.save(seq: 1, jpeg: jpegWithMetadata());
      await s.save(seq: 2, jpeg: jpegWithMetadata());
      await db.setSetting(IntruderEvidenceStore.indexKey, 'corrupt');
      await s.list();
      await s.sweepOrphans();
      expect(await db.getSetting(IntruderFailureLogStore.storageKey), 'M1-LOG');
      expect(await db.getSetting('security_settings'), 'CREDENTIALS');
    });
  });

  group('IntruderDefenseSettingsStore', () {
    test('missing record = everything disabled, threshold 3, writable',
        () async {
      final IntruderSettingsRead r =
          await IntruderDefenseSettingsStore(db, cipher).read();
      expect(r.settings, IntruderDefenseSettings.disabled);
      expect(r.settings.evidenceEnabled, isFalse);
      expect(r.settings.alarmEnabled, isFalse);
      expect(r.settings.threshold, 3);
      expect(r.health, IntruderSettingsHealth.missing);
      expect(r.writable, isTrue);
    });

    test('round-trips encrypted', () async {
      final IntruderDefenseSettingsStore s =
          IntruderDefenseSettingsStore(db, cipher);
      const IntruderDefenseSettings v = IntruderDefenseSettings(
          evidenceEnabled: true, alarmEnabled: true, threshold: 5);
      expect(await s.write(v), isTrue);
      expect((await s.read()).settings, v);
      final String raw =
          (await db.getSetting(IntruderDefenseSettingsStore.storageKey))!;
      expect(raw, startsWith('enc:v1:'));
      expect(raw, isNot(contains('evidence')));
    });

    for (final (String name, Future<String> Function() raw)
        in <(String, Future<String> Function())>[
      (
        'plaintext',
        () async => '{"v":1,"evidence":true,"alarm":true,"threshold":3}'
      ),
      ('bad ciphertext', () async => 'enc:v1:AAAA'),
      (
        'wrong types',
        () async =>
            'enc:v1:${await cipher.encryptString('{"v":1,"evidence":"yes","alarm":true,"threshold":3}')}'
      ),
      (
        'threshold 0',
        () async =>
            'enc:v1:${await cipher.encryptString('{"v":1,"evidence":true,"alarm":true,"threshold":0}')}'
      ),
      (
        'threshold 11',
        () async =>
            'enc:v1:${await cipher.encryptString('{"v":1,"evidence":true,"alarm":true,"threshold":11}')}'
      ),
      ('not json', () async => 'enc:v1:${await cipher.encryptString('nope')}'),
    ]) {
      test('corrupt ($name) reads disabled and is never overwritten', () async {
        final String stored = await raw();
        await db.setSetting(IntruderDefenseSettingsStore.storageKey, stored);
        final IntruderDefenseSettingsStore s =
            IntruderDefenseSettingsStore(db, cipher);
        final IntruderSettingsRead r = await s.read();
        expect(r.settings, IntruderDefenseSettings.disabled);
        expect(r.health, IntruderSettingsHealth.corrupt);
        expect(
            await s.write(const IntruderDefenseSettings(evidenceEnabled: true)),
            isFalse);
        expect(await db.getSetting(IntruderDefenseSettingsStore.storageKey),
            stored);
      });
    }

    test('a newer schema reads disabled and is never overwritten', () async {
      final String stored =
          'enc:v1:${await cipher.encryptString('{"v":2,"evidence":true,"alarm":true,"threshold":3,"x":1}')}';
      await db.setSetting(IntruderDefenseSettingsStore.storageKey, stored);
      final IntruderDefenseSettingsStore s =
          IntruderDefenseSettingsStore(db, cipher);
      final IntruderSettingsRead r = await s.read();
      expect(r.health, IntruderSettingsHealth.unsupported);
      expect(r.settings.evidenceEnabled, isFalse);
      expect(await s.write(IntruderDefenseSettings.disabled), isFalse);
      expect(
          await db.getSetting(IntruderDefenseSettingsStore.storageKey), stored);
    });

    test('an unreadable database reads disabled', () async {
      final _FailingDb fdb = _FailingDb()..failReads = true;
      final IntruderSettingsRead r =
          await IntruderDefenseSettingsStore(fdb, cipher).read();
      expect(r.health, IntruderSettingsHealth.unreadable);
      expect(r.settings, IntruderDefenseSettings.disabled);
      expect(r.writable, isFalse);
    });

    test('a broken cipher refuses to save (no plaintext fallback)', () async {
      expect(
          await IntruderDefenseSettingsStore(db, _BrokenCipher())
              .write(const IntruderDefenseSettings(alarmEnabled: true)),
          isFalse);
      expect(
          await db.getSetting(IntruderDefenseSettingsStore.storageKey), isNull);
    });
  });
}
