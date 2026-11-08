// Phase 11 / M2: custom profiles in the model and the version 2 document.

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/profiles/security_profile.dart';
import 'package:smart_app_lock/profiles/security_profile_document.dart';
import 'package:smart_app_lock/profiles/security_profile_policy.dart';

typedef _L = AppSecurityLevel;

const String _a = 'com.example.notes';
const String _b = 'com.example.bank';

SecurityProfile _custom(
  String hex,
  String name, {
  _L? all,
  Map<String, _L> apps = const <String, _L>{},
}) =>
    SecurityProfile.custom(
      id: 'custom-$hex',
      name: name,
      allProtectedLevel: all,
      appLevels: apps,
    );

Matcher _rejects(String field) => throwsA(
      isA<SecurityProfileFormatException>().having(
          (SecurityProfileFormatException e) => e.field, 'field', field),
    );

void main() {
  group('P11-M2 model: custom profiles (#1–#8)', () {
    test('MD-1. a valid custom profile: id, trimmed name, raise-only overlay',
        () {
      final SecurityProfile p = _custom('0123456789ab', '  Travel  ',
          apps: const <String, _L>{_a: _L.critical});
      expect(p.id, 'custom-0123456789ab');
      expect(p.name, 'Travel');
      expect(p.isCustom, isTrue);
      expect(p.kind, isNull);
      expect(p.isEditable, isTrue);
      expect(p.isRemovable, isTrue);
    });

    test('MD-2. strict ids: only custom- + 12 lowercase hex', () {
      for (final String bad in <String>[
        'custom-0123456789AB',
        'custom-0123456789a',
        'custom-0123456789abc',
        'normal',
        'guest',
        'profile-x',
        '',
      ]) {
        expect(
          () => SecurityProfile.custom(id: bad, name: 'X'),
          _rejects('id'),
          reason: bad,
        );
      }
    });

    test('MD-3. names: required, ≤ 32 chars, no control characters', () {
      expect(() => _custom('000000000001', '   '), _rejects('name'));
      expect(() => _custom('000000000001', 'a' * 33), _rejects('name'));
      expect(() => _custom('000000000001', 'Line\nbreak'), _rejects('name'));
      expect(() => _custom('000000000001', 'Tab\there'), _rejects('name'));
      expect(_custom('000000000001', 'a' * 32).name, 'a' * 32);
      expect(_custom('000000000001', 'Café 😀').name, 'Café 😀');
    });

    test('MD-4. custom overlays are raise-only (never Standard)', () {
      expect(
        () => _custom('000000000001', 'X', all: _L.standard),
        _rejects('all'),
      );
      expect(
        () => _custom('000000000001', 'X',
            apps: const <String, _L>{_a: _L.standard}),
        _rejects('apps'),
      );
      expect(
        () => _custom('000000000001', 'X',
            apps: const <String, _L>{SecurityProfile.ownPackage: _L.critical}),
        _rejects('apps'),
      );
    });

    test('MD-5. presets: Normal/Guest immutable, no preset rename', () {
      final SecurityProfile normal =
          SecurityProfile.preset(SecurityProfileKind.normal);
      final SecurityProfile guest =
          SecurityProfile.preset(SecurityProfileKind.guest);
      final SecurityProfile home =
          SecurityProfile.preset(SecurityProfileKind.home);
      expect(normal.isEditable, isFalse);
      expect(guest.isEditable, isFalse);
      expect(home.isEditable, isTrue);
      expect(home.isRemovable, isFalse);
      expect(() => normal.copyWith(allProtectedLevel: _L.critical),
          _rejects('normal'));
      expect(() => guest.copyWith(clearAll: true), _rejects('guest'));
      expect(() => home.copyWith(name: 'House'), _rejects('name'));
      expect(
          home.copyWith(
              appLevels: const <String, _L>{_a: _L.sensitive}).appLevels,
          const <String, _L>{_a: _L.sensitive});
    });

    test('MD-6. set: duplicate names (any case, incl. presets) are rejected',
        () {
      final SecurityProfileSet d = SecurityProfileSet.defaults();
      expect(() => d.withAdded(_custom('000000000001', 'guest')),
          _rejects('name'));
      final SecurityProfileSet one =
          d.withAdded(_custom('000000000001', 'Trip'));
      expect(() => one.withAdded(_custom('000000000002', 'TRIP')),
          _rejects('name'));
      expect(one.isNameAvailable('trip'), isFalse);
      expect(
          one.isNameAvailable('trip', exceptId: 'custom-000000000001'), isTrue);
      expect(() => one.withAdded(_custom('000000000001', 'Other')),
          _rejects('profiles'),
          reason: 'duplicate id');
    });

    test('MD-7. set limits: ≤ 20 custom profiles; ≤ 2048 entries in total', () {
      SecurityProfileSet s = SecurityProfileSet.defaults();
      for (int i = 0; i < SecurityProfileSet.maxCustomProfiles; i++) {
        s = s.withAdded(_custom(i.toRadixString(16).padLeft(12, '0'), 'P$i'));
      }
      expect(s.canAddCustom, isFalse);
      expect(() => s.withAdded(_custom('ffffffffffff', 'One more')),
          _rejects('profiles'));
      Map<String, _L> many(int from) => <String, _L>{
            for (int i = from; i < from + SecurityProfile.maxApps; i++)
              'com.example.app$i': _L.critical,
          };
      SecurityProfileSet t = SecurityProfileSet.defaults();
      for (int i = 0; i < 4; i++) {
        t = t
            .withAdded(_custom('00000000000$i', 'Big $i', apps: many(i * 512)));
      }
      expect(
          () => t.withAdded(_custom('000000000009', 'Too big',
              apps: const <String, _L>{_a: _L.critical})),
          _rejects('apps'));
    });

    test('MD-8. stable canonical order: presets, then custom by id', () {
      final SecurityProfileSet s = SecurityProfileSet.defaults()
          .withAdded(_custom('00000000000b', 'B'))
          .withAdded(_custom('00000000000a', 'A'));
      expect(s.profiles.map((SecurityProfile p) => p.id).toList(), <String>[
        'normal',
        'home',
        'work',
        'guest',
        'kids',
        'custom-00000000000a',
        'custom-00000000000b',
      ]);
    });

    test(
        'MD-9. delete: custom only; deleting the active one makes Normal '
        'active; unknown/preset ids are refused', () {
      final SecurityProfileSet s = SecurityProfileSet.defaults()
          .withAdded(_custom('000000000001', 'Trip', all: _L.critical))
          .withActive('custom-000000000001');
      final SecurityProfileSet after = s.without('custom-000000000001');
      expect(after.activeProfileId, 'normal');
      expect(after.byId('custom-000000000001'), isNull);
      expect(() => s.without('guest'), _rejects('profiles'));
      expect(() => s.without('custom-000000000999'), _rejects('profiles'));
      expect(() => s.withActive('custom-000000000999'),
          _rejects('activeProfileId'));
    });

    test('MD-10. new ids are unique and well-formed', () {
      final Set<String> taken = <String>{};
      final Random rng = Random(7);
      for (int i = 0; i < 200; i++) {
        final String id = SecurityProfile.newCustomId(taken, random: rng);
        expect(SecurityProfile.customIdPattern.hasMatch(id), isTrue);
        expect(taken.add(id), isTrue);
      }
    });

    test(
        'MD-11. overlay compilation is identical for a custom profile and '
        'a preset with the same levels (name/id not in the transport)', () {
      final SecurityProfile kids = SecurityProfile(
        kind: SecurityProfileKind.kids,
        appLevels: const <String, _L>{_a: _L.critical},
      );
      final SecurityProfile mine = _custom('000000000001', 'Mine',
          apps: const <String, _L>{_a: _L.critical});
      expect(
        SecurityProfilePolicy.nativeTransport(
            const [], kids, const <String>{_a, _b}).toString(),
        SecurityProfilePolicy.nativeTransport(
            const [], mine, const <String>{_a, _b}).toString(),
      );
    });
  });

  group('P11-M2 document v2 (#9–#12)', () {
    test('DOC-1. round trip with custom profiles; version 2 with names', () {
      final SecurityProfileSet s = SecurityProfileSet.defaults()
          .withAdded(_custom('000000000001', 'Trip',
              all: _L.sensitive, apps: const <String, _L>{_a: _L.critical}))
          .withActive('custom-000000000001');
      final String raw = SecurityProfileDocument.encode(s);
      final Map<String, Object?> json = jsonDecode(raw) as Map<String, Object?>;
      expect(json['version'], 2);
      expect(
        (json['profiles']! as List<Object?>)
            .map((Object? e) => (e! as Map<String, Object?>)['name'])
            .toList(),
        <String>['Normal', 'Home', 'Work', 'Guest', 'Kids', 'Trip'],
      );
      expect(SecurityProfileDocument.decode(raw), s);
    });

    test('DOC-2. a version 1 (M1) document decodes losslessly', () {
      const String v1 = '{"version":1,"activeProfileId":"guest","profiles":['
          '{"id":"normal","all":null,"apps":{}},'
          '{"id":"home","all":null,"apps":{"com.example.notes":"sensitive"}},'
          '{"id":"work","all":null,"apps":{}},'
          '{"id":"guest","all":"critical","apps":{}},'
          '{"id":"kids","all":null,"apps":{}}]}';
      final SecurityProfileSet s = SecurityProfileDocument.decode(v1);
      expect(s.activeProfileId, 'guest');
      expect(s.byKind(SecurityProfileKind.home).appLevels,
          const <String, _L>{_a: _L.sensitive});
      expect(s.customProfiles, isEmpty);
    });

    test('DOC-3. corrupt v2 variants are rejected (never repaired)', () {
      Map<String, Object?> base() => jsonDecode(SecurityProfileDocument.encode(
            SecurityProfileSet.defaults()
                .withAdded(_custom('000000000001', 'Trip')),
          )) as Map<String, Object?>;
      List<Object?> list(Map<String, Object?> d) =>
          d['profiles']! as List<Object?>;
      Map<String, Object?> entry(Map<String, Object?> d, int i) =>
          list(d)[i]! as Map<String, Object?>;

      final List<Map<String, Object?>> bad = <Map<String, Object?>>[];
      bad.add(base().also((Map<String, Object?> d) =>
          entry(d, 0)['name'] = 'Everyday')); // preset renamed
      bad.add(base().also((Map<String, Object?> d) =>
          entry(d, 5)['name'] = ' Trip')); // not trimmed
      bad.add(base().also((Map<String, Object?> d) =>
          entry(d, 5)['id'] = 'custom-XYZ')); // bad id
      bad.add(base().also((Map<String, Object?> d) =>
          entry(d, 5).remove('name'))); // missing key
      bad.add(base().also(
          (Map<String, Object?> d) => entry(d, 5)['extra'] = 1)); // extra key
      bad.add(
          base().also((Map<String, Object?> d) => list(d).add(<String, Object?>{
                'id': 'custom-000000000002',
                'name': 'trip',
                'all': null,
                'apps': <String, Object?>{},
              }))); // duplicate name
      bad.add(base().also((Map<String, Object?> d) =>
          d['activeProfileId'] = 'custom-000000000009')); // unknown active
      bad.add(base().also((Map<String, Object?> d) =>
          entry(d, 5)['all'] = 'standard')); // not raising
      for (final Map<String, Object?> d in bad) {
        expect(
          () => SecurityProfileDocument.decode(jsonEncode(d)),
          throwsA(isA<SecurityProfileDocumentException>().having(
              (SecurityProfileDocumentException e) => e.problem,
              'problem',
              SecurityProfileDocumentProblem.corrupt)),
          reason: jsonEncode(d),
        );
      }
    });

    test(
        'DOC-4. a v1 document with a custom entry or a name is corrupt; a '
        'newer version is unsupported', () {
      const String v1Custom =
          '{"version":1,"activeProfileId":"normal","profiles":['
          '{"id":"custom-000000000001","all":null,"apps":{}}]}';
      expect(() => SecurityProfileDocument.decode(v1Custom),
          throwsA(isA<SecurityProfileDocumentException>()));
      expect(
        () => SecurityProfileDocument.decode(
            '{"version":3,"activeProfileId":"normal","profiles":[]}'),
        throwsA(isA<SecurityProfileDocumentException>().having(
            (SecurityProfileDocumentException e) => e.problem,
            'problem',
            SecurityProfileDocumentProblem.unsupportedVersion)),
      );
    });
  });
}

extension<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}
