// Phase 11 / M3 (§3, §5): the "Apply profile" rule model and the strict
// schema v2 → v3 migration: lossless, idempotent, no invented actions,
// newer documents never overwritten, bad ids / variants / days / duplicates
// rejected, rule-count and size limits, the original preserved on failure.
// Pure Dart + in-memory storage; no device.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/data/repositories/impl/smart_rule_repository_impl.dart';
import 'package:smart_app_lock/data/repositories/smart_rule_repository.dart';
import 'package:smart_app_lock/data/storage/impl/in_memory_local_database.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/rules/smart_rule_document.dart';
import 'package:smart_app_lock/utilities/result.dart';

typedef _A = SmartRuleAction;
typedef _K = SmartRuleStoreErrorKind;

const String _key = SmartRuleRepositoryImpl.storageKey;

SmartRule _level(String id, {_A action = _A.critical}) => SmartRule(
      id: id,
      name: 'Rule $id',
      targetPackages: const <String>['com.example.bank'],
      days: const <int>[1, 2, 3, 4, 5],
      time: SmartRuleTime.window(startMinute: 540, endMinute: 1020),
      action: action,
    );

SmartRule _profile(String id, {String profile = 'guest', bool on = true}) =>
    SmartRule(
      id: id,
      name: 'Profile $id',
      targetPackages: const <String>[],
      days: const <int>[6, 7],
      time: SmartRuleTime.window(startMinute: 1320, endMinute: 360),
      action: _A.applyProfile,
      profileId: profile,
      enabled: on,
    );

Map<String, Object?> _profileJson({
  Object? profile = 'guest',
  Object? action = 'profile',
  Map<String, Object?> extra = const <String, Object?>{},
  bool withTargets = false,
  List<int> days = const <int>[6, 7],
}) =>
    <String, Object?>{
      'id': 'p1',
      'name': 'Weekend',
      'enabled': true,
      if (withTargets) 'targets': <String>['com.example.bank'],
      'days': days,
      'time': <String, Object?>{'type': 'allDay'},
      'action': action,
      if (profile != null) 'profile': profile,
      ...extra,
    };

String _doc(List<Object?> rules, {int version = 3}) =>
    jsonEncode(<String, Object?>{
      'schema': 'smart_rules',
      'version': version,
      'rules': rules
    });

Matcher _corrupt() => throwsA(isA<SmartRuleDocumentException>().having(
    (SmartRuleDocumentException e) => e.problem,
    'problem',
    SmartRuleDocumentProblem.corrupt));

class _Db extends InMemoryLocalDatabase {
  bool failRuleWrites = false;
  bool failConfirm = false;
  int ruleWrites = 0;

  @override
  Future<void> setSetting(String key, String value) async {
    if (key == _key) {
      ruleWrites++;
      if (failRuleWrites) throw StateError('simulated rule write failure');
    }
    await super.setSetting(key, value);
    if (key == _key && failConfirm) {
      // SIMULATED torn write (once): the stored bytes differ from what was
      // sent; the rollback write that follows lands normally.
      failConfirm = false;
      await super.setSetting(key, value.substring(0, value.length - 1));
    }
  }
}

void main() {
  group('§3 the Apply profile rule model', () {
    test('valid ids: the five presets and custom-<12 hex>', () {
      for (final String id in <String>[
        'normal',
        'home',
        'work',
        'guest',
        'kids',
        'custom-0123456789ab',
      ]) {
        final SmartRule r = _profile('r', profile: id);
        expect(r.profileId, id);
        expect(r.isProfileRule, isTrue);
        expect(r.targetPackages, isEmpty);
        expect(r.action.raisesTo, isNull, reason: 'never raises by itself');
      }
    });

    test('invalid or missing references are rejected at construction', () {
      for (final String? bad in <String?>[
        null,
        '',
        'Guest',
        'GUEST',
        ' guest',
        'custom-',
        'custom-0123456789AB',
        'custom-0123456789a',
        'custom-0123456789abc',
        'profile-guest',
        'unlocked',
      ]) {
        expect(() => _profile('r', profile: bad ?? ''),
            throwsA(isA<SmartRuleFormatException>()),
            reason: '$bad');
      }
      expect(
        () => SmartRule(
          id: 'r',
          name: 'R',
          targetPackages: const <String>[],
          days: const <int>[1],
          time: const SmartRuleTime.allDay(),
          action: _A.applyProfile,
        ),
        throwsA(isA<SmartRuleFormatException>()),
        reason: 'no profile id',
      );
    });

    test('a profile rule never enrols apps: targets are refused', () {
      expect(
        () => SmartRule(
          id: 'r',
          name: 'R',
          targetPackages: const <String>['com.example.bank'],
          days: const <int>[1],
          time: const SmartRuleTime.allDay(),
          action: _A.applyProfile,
          profileId: 'guest',
        ),
        throwsA(isA<SmartRuleFormatException>()),
      );
    });

    test('a level rule cannot carry a profile id; existing actions unchanged',
        () {
      for (final _A a in _A.levelActions) {
        expect(
          () => SmartRule(
            id: 'r',
            name: 'R',
            targetPackages: const <String>['com.example.bank'],
            days: const <int>[1],
            time: const SmartRuleTime.allDay(),
            action: a,
            profileId: 'guest',
          ),
          throwsA(isA<SmartRuleFormatException>()),
          reason: a.name,
        );
        expect(_level('l', action: a).profileId, isNull);
      }
      expect(_A.levelActions, isNot(contains(_A.applyProfile)));
      expect(_A.values.toSet(), <_A>{..._A.levelActions, _A.applyProfile});
      expect(_A.fromStorageId('profile'), _A.applyProfile);
      expect(_A.fromStorageId('Profile'), isNull);
    });

    test('equality and copyWith cover profileId', () {
      expect(_profile('r'), _profile('r'));
      expect(_profile('r') == _profile('r', profile: 'kids'), isFalse);
      expect(_profile('r').copyWith(profileId: 'kids'),
          _profile('r', profile: 'kids'));
      expect(_profile('r').copyWith(enabled: false), _profile('r', on: false));
    });
  });

  group('§5 schema v3 encoding and strict decoding', () {
    test('profile rule exact v3 layout (no targets, a profile key)', () {
      final String encoded = SmartRuleDocument.encode(<SmartRule>[
        _profile('p1'),
      ]);
      expect(
        encoded,
        '{"schema":"smart_rules","version":3,"rules":[{"id":"p1",'
        '"name":"Profile p1","enabled":true,"days":[6,7],"time":'
        '{"type":"window","start":1320,"end":360},"action":"profile",'
        '"profile":"guest"}]}',
      );
      expect(SmartRuleDocument.decode(encoded), <SmartRule>[_profile('p1')]);
    });

    test('mixed round trip is lossless and idempotent (byte-identical)', () {
      final List<SmartRule> rules = <SmartRule>[
        _level('b'),
        _profile('p1'),
        _level('a', action: _A.sensitive),
        _profile('p2', profile: 'custom-00000000000a', on: false),
      ];
      final String once = SmartRuleDocument.encode(rules);
      final List<SmartRule> back = SmartRuleDocument.decode(once);
      expect(back, rules, reason: 'order and every field kept');
      final String twice = SmartRuleDocument.encode(back);
      expect(twice, once);
      expect(SmartRuleDocument.decodeDocument(twice).migrated, isFalse);
    });

    test(
        'v2 → v3 migration: lossless, no invented action, level layout '
        'unchanged except the version number', () {
      final List<SmartRule> rules = <SmartRule>[
        _level('a'),
        _level('b', action: _A.standard),
        _level('c', action: _A.unlocked),
      ];
      final String v3 = SmartRuleDocument.encode(rules);
      final String v2 = v3.replaceFirst('"version":3', '"version":2');
      final SmartRuleDocumentRead read = SmartRuleDocument.decodeDocument(v2);
      expect(read.storedVersion, 2);
      expect(read.migrated, isTrue);
      expect(read.rules, rules);
      expect(read.rules.any((SmartRule r) => r.isProfileRule), isFalse,
          reason: 'migration never invents a profile action');
      expect(SmartRuleDocument.encode(read.rules), v3);
    });

    test('a "profile" action never existed in v1/v2: rejected', () {
      expect(
          () => SmartRuleDocument.decode(
              _doc(<Object?>[_profileJson()], version: 2)),
          _corrupt());
      expect(
          () => SmartRuleDocument.decode(
              _doc(<Object?>[_profileJson()], version: 1)),
          _corrupt());
    });

    test(
        'bad ids, unknown variants, bad days, extra / missing keys and '
        'duplicates make the WHOLE document corrupt', () {
      final List<Map<String, Object?>> bad = <Map<String, Object?>>[
        _profileJson(profile: 'Guest'),
        _profileJson(profile: 'custom-XYZ'),
        _profileJson(profile: 7),
        _profileJson(profile: null),
        _profileJson(action: 'Profile'),
        _profileJson(action: 'profiles'),
        _profileJson(action: 'applyProfile'),
        _profileJson(withTargets: true),
        _profileJson(extra: <String, Object?>{'targets': <String>[]}),
        _profileJson(extra: <String, Object?>{'until': 'expiry'}),
        _profileJson(days: <int>[]),
        _profileJson(days: <int>[0]),
        _profileJson(days: <int>[8]),
        _profileJson(days: <int>[7, 6]),
        _profileJson(days: <int>[6, 6]),
      ];
      for (final Map<String, Object?> rule in bad) {
        expect(
          () => SmartRuleDocument.decode(
              _doc(<Object?>[_level('ok').toJson(), rule])),
          _corrupt(),
          reason: '$rule',
        );
      }
      expect(
        () => SmartRuleDocument.decode(
            _doc(<Object?>[_profileJson(), _profileJson()])),
        _corrupt(),
        reason: 'duplicate ids',
      );
      expect(
        () => SmartRuleDocument.encode(<SmartRule>[_profile('x'), _level('x')]),
        throwsArgumentError,
      );
    });

    test('a newer document (v4+) is unsupported, never read as v3', () {
      for (final int v in <int>[4, 5, 99]) {
        expect(
          () => SmartRuleDocument.decode(_doc(<Object?>[], version: v)),
          throwsA(isA<SmartRuleDocumentException>().having(
              (SmartRuleDocumentException e) => e.problem,
              'problem',
              SmartRuleDocumentProblem.unsupportedVersion)),
        );
      }
    });
  });

  group('§5 limits (rule count, profile rules, document size)', () {
    test(
        '200 rules and 32 profile rules are accepted; one more is refused '
        'by encode and corrupt on decode', () {
      final List<SmartRule> max = <SmartRule>[
        for (int i = 0; i < 168; i++) _level('l$i'),
        for (int i = 0; i < 32; i++) _profile('p$i'),
      ];
      expect(max, hasLength(SmartRuleDocument.maxRules));
      expect(SmartRuleDocument.limitProblem(max), isNull);
      final String ok = SmartRuleDocument.encode(max);
      expect(SmartRuleDocument.decode(ok), max);

      final List<SmartRule> tooMany = <SmartRule>[...max, _level('extra')];
      expect(SmartRuleDocument.limitProblem(tooMany), isNotNull);
      expect(() => SmartRuleDocument.encode(tooMany), throwsArgumentError);
      expect(
        () => SmartRuleDocument.decode(_doc(<Object?>[
          for (final SmartRule r in tooMany) r.toJson(),
        ])),
        _corrupt(),
      );

      final List<SmartRule> tooManyProfiles = <SmartRule>[
        for (int i = 0; i < 33; i++) _profile('p$i'),
      ];
      expect(SmartRuleDocument.limitProblem(tooManyProfiles), isNotNull);
      expect(
          () => SmartRuleDocument.encode(tooManyProfiles), throwsArgumentError);
      expect(
        () => SmartRuleDocument.decode(_doc(<Object?>[
          for (final SmartRule r in tooManyProfiles) r.toJson(),
        ])),
        _corrupt(),
      );
    });

    test('a document over 256 KiB is refused by encode and corrupt on decode',
        () {
      final String longPkg = 'com.${'a' * 240}.x';
      final List<SmartRule> big = <SmartRule>[
        for (int i = 0; i < 120; i++)
          SmartRule(
            id: 'big$i',
            name: 'Big $i',
            targetPackages: <String>[
              for (int j = 0; j < 10; j++) '$longPkg$j',
            ],
            days: const <int>[1],
            time: const SmartRuleTime.allDay(),
            action: _A.critical,
          ),
      ];
      expect(SmartRuleDocument.limitProblem(big), isNull,
          reason: 'under the count limits');
      expect(() => SmartRuleDocument.encode(big), throwsArgumentError);
      final String raw =
          _doc(<Object?>[for (final SmartRule r in big) r.toJson()]);
      expect(raw.length, greaterThan(SmartRuleDocument.maxDocumentLength));
      expect(() => SmartRuleDocument.decode(raw), _corrupt());
    });
  });

  group('§5 repository: migration, rollback and corruption', () {
    Future<(SmartRuleRepositoryImpl, _Db)> open([String? raw]) async {
      final _Db db = _Db();
      if (raw != null) await db.setSetting(_key, raw);
      db.ruleWrites = 0;
      return (SmartRuleRepositoryImpl(db), db);
    }

    test(
        'a v2 store is read without rewriting; written as v3 only by the '
        'next confirmed change; then idempotent', () async {
      final String v2 = SmartRuleDocument.encode(<SmartRule>[_level('a')])
          .replaceFirst('"version":3', '"version":2');
      final (SmartRuleRepositoryImpl repo, _Db db) = await open(v2);
      expect((await repo.getRules()).valueOrNull, <SmartRule>[_level('a')]);
      expect(await db.getSetting(_key), v2);
      expect(db.ruleWrites, 0, reason: 'reading never migrates in place');

      expect((await repo.saveRule(_profile('p1'), mustBeNew: true)).isSuccess,
          isTrue);
      final String v3 = (await db.getSetting(_key))!;
      expect(jsonDecode(v3)['version'], 3);
      expect(SmartRuleDocument.decode(v3),
          <SmartRule>[_level('a'), _profile('p1')]);
      final int writes = db.ruleWrites;
      expect(
          (await repo.saveRule(_profile('p1'), expected: _profile('p1')))
              .isSuccess,
          isTrue);
      expect(db.ruleWrites, writes, reason: 'identical save writes nothing');
      expect(await db.getSetting(_key), v3);
    });

    test(
        'final gate: a v1 store (no action key) is read losslessly without '
        'rewriting; v1 → v3 is idempotent (decode ∘ encode is a fixed point)',
        () async {
      const String v1 = '{"schema":"smart_rules","version":1,"rules":['
          '{"id":"a","name":"Night a","enabled":true,'
          '"targets":["com.example.bank","com.example.chat"],"days":[1,7],'
          '"time":{"type":"window","start":1320,"end":360}},'
          '{"id":"b","name":"Off b","enabled":false,'
          '"targets":["com.example.chat"],"days":[3],'
          '"time":{"type":"allDay"}}]}';
      final SmartRuleDocumentRead read = SmartRuleDocument.decodeDocument(v1);
      expect(read.storedVersion, 1);
      expect(read.migrated, isTrue);
      expect(read.rules.map((SmartRule r) => r.id), <String>['a', 'b']);
      expect(read.rules.first.time,
          SmartRuleTime.window(startMinute: 1320, endMinute: 360));
      expect(read.rules.last.enabled, isFalse);
      expect(read.rules.any((SmartRule r) => r.isProfileRule), isFalse,
          reason: 'migration never invents a profile action');
      final String v3 = SmartRuleDocument.encode(read.rules);
      expect(jsonDecode(v3)['version'], 3);
      expect(SmartRuleDocument.decode(v3), read.rules);
      expect(SmartRuleDocument.encode(SmartRuleDocument.decode(v3)), v3);

      final (SmartRuleRepositoryImpl repo, _Db db) = await open(v1);
      expect((await repo.getRules()).valueOrNull, read.rules);
      expect(await db.getSetting(_key), v1);
      expect(db.ruleWrites, 0, reason: 'reading never migrates in place');
    });

    test(
        'interrupted migration (write fails): the ORIGINAL v2 bytes are '
        'preserved; nothing claimed', () async {
      final String v2 = SmartRuleDocument.encode(<SmartRule>[_level('a')])
          .replaceFirst('"version":3', '"version":2');
      final (SmartRuleRepositoryImpl repo, _Db db) = await open(v2);
      db.failRuleWrites = true;
      final Result<void> r =
          await repo.saveRule(_profile('p1'), mustBeNew: true);
      expect(r.isFailure, isTrue);
      expect((r.errorOrNull! as SmartRuleStoreException).kind, _K.writeFailed);
      db.failRuleWrites = false;
      expect(await db.getSetting(_key), v2);
      expect((await repo.getRules()).valueOrNull, <SmartRule>[_level('a')]);
    });

    test('torn write (unconfirmed read-back): rolled back to the original',
        () async {
      final String v2 = SmartRuleDocument.encode(<SmartRule>[_level('a')])
          .replaceFirst('"version":3', '"version":2');
      final (SmartRuleRepositoryImpl repo, _Db db) = await open(v2);
      db.failConfirm = true;
      final Result<void> r =
          await repo.saveRule(_profile('p1'), mustBeNew: true);
      expect(r.isFailure, isTrue);
      expect(db.failConfirm, isFalse, reason: 'the torn write happened');
      expect(await db.getSetting(_key), v2);
    });

    test('over a limit: refused as not saved, NOTHING written', () async {
      final List<SmartRule> full = <SmartRule>[
        for (int i = 0; i < 32; i++) _profile('p$i'),
      ];
      final (SmartRuleRepositoryImpl repo, _Db db) =
          await open(SmartRuleDocument.encode(full));
      final String before = (await db.getSetting(_key))!;
      final Result<void> r =
          await repo.saveRule(_profile('p32'), mustBeNew: true);
      expect(r.isFailure, isTrue);
      expect((r.errorOrNull! as SmartRuleStoreException).kind, _K.writeFailed);
      expect(db.ruleWrites, 0);
      expect(await db.getSetting(_key), before);
    });

    for (final (String label, String raw, _K kind) in <(String, String, _K)>[
      (
        'a v4 document',
        '{"schema":"smart_rules","version":4,"rules":[{"action":"until"}]}',
        _K.unsupportedVersion,
      ),
      (
        'a v3 document with an unknown profile id',
        _doc(<Object?>[_profileJson(profile: 'Guest')]),
        _K.corrupt,
      ),
      (
        'a v2 document with a profile action',
        _doc(<Object?>[_profileJson()], version: 2),
        _K.corrupt,
      ),
    ]) {
      test('$label: read fails closed; every write refused; byte-for-byte',
          () async {
        final (SmartRuleRepositoryImpl repo, _Db db) = await open(raw);
        final Result<List<SmartRule>> read = await repo.getRules();
        expect(read.valueOrNull, isNull);
        expect((read.errorOrNull! as SmartRuleStoreException).kind, kind);
        for (final Result<void> w in <Result<void>>[
          await repo.saveRule(_profile('n'), mustBeNew: true),
          await repo.deleteRule('p1'),
          await repo.setRuleEnabled('p1', enabled: false),
          await repo
              .replaceRules(const <SmartRule>[], expected: const <SmartRule>[]),
        ]) {
          expect(w.isFailure, isTrue);
        }
        expect(db.ruleWrites, 0);
        expect(await db.getSetting(_key), raw);
      });
    }
  });
}
