// Phase 11 / M1: Security Profile model, presets, validation and the
// exactly-one-active invariant. Pure Dart (SIMULATED; no device).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/data/models/app_security_level.dart';
import 'package:smart_app_lock/profiles/security_profile.dart';
import 'package:smart_app_lock/profiles/security_profile_document.dart';

const String _notes = 'com.example.notes';
const String _bank = 'com.example.bank';

Matcher _rejected(String field) => throwsA(
      isA<SecurityProfileFormatException>().having(
          (SecurityProfileFormatException e) => e.field, 'field', field),
    );

void main() {
  group('presets (M1: Normal default, nothing auto-enrolled)', () {
    test('five presets in canonical order, Normal active by default', () {
      final SecurityProfileSet set = SecurityProfileSet.defaults();
      expect(set.profiles.map((SecurityProfile p) => p.id).toList(),
          <String>['normal', 'home', 'work', 'guest', 'kids']);
      expect(set.activeProfileId, 'normal');
      expect(set.active.kind, SecurityProfileKind.normal);
      expect(set.active.isEmpty, isTrue);
    });

    test('defaults: only Guest adds protection (every protected app Critical)',
        () {
      for (final SecurityProfileKind k in SecurityProfileKind.values) {
        final SecurityProfile p = SecurityProfile.preset(k);
        expect(p.appLevels, isEmpty, reason: k.id);
        expect(
          p.allProtectedLevel,
          k == SecurityProfileKind.guest ? AppSecurityLevel.critical : null,
          reason: k.id,
        );
      }
    });

    test('D3: no preset enrolls Settings, Play Store or any app', () {
      final String doc =
          SecurityProfileDocument.encode(SecurityProfileSet.defaults());
      expect(doc, isNot(contains('com.android.settings')));
      expect(doc, isNot(contains('com.android.vending')));
      expect(doc, isNot(contains('"apps":{"')));
    });

    test('D2: Work is an in-app profile label, not a managed profile', () {
      expect(SecurityProfileKind.work.label, 'Work');
      expect(SecurityProfile.preset(SecurityProfileKind.work).isEmpty, isTrue);
    });
  });

  group('raise-only validation (D1)', () {
    test('Standard is never an overlay level (all, apps)', () {
      for (final SecurityProfileKind k in <SecurityProfileKind>[
        SecurityProfileKind.home,
        SecurityProfileKind.work,
        SecurityProfileKind.kids,
      ]) {
        expect(
          () => SecurityProfile(
              kind: k, allProtectedLevel: AppSecurityLevel.standard),
          _rejected('all'),
        );
        expect(
          () => SecurityProfile(
            kind: k,
            appLevels: const <String, AppSecurityLevel>{
              _notes: AppSecurityLevel.standard,
            },
          ),
          _rejected('apps'),
        );
      }
    });

    test('Sensitive and Critical are accepted', () {
      final SecurityProfile p = SecurityProfile(
        kind: SecurityProfileKind.kids,
        allProtectedLevel: AppSecurityLevel.sensitive,
        appLevels: const <String, AppSecurityLevel>{
          _notes: AppSecurityLevel.critical,
          _bank: AppSecurityLevel.sensitive,
        },
      );
      expect(p.appLevels.keys.toList(), <String>[_bank, _notes]); // sorted
      expect(() => p.appLevels[_notes] = AppSecurityLevel.standard,
          throwsUnsupportedError);
    });

    test('Normal adds no protection', () {
      expect(
        () => SecurityProfile(
          kind: SecurityProfileKind.normal,
          allProtectedLevel: AppSecurityLevel.sensitive,
        ),
        _rejected('normal'),
      );
      expect(
        () => SecurityProfile(
          kind: SecurityProfileKind.normal,
          appLevels: const <String, AppSecurityLevel>{
            _notes: AppSecurityLevel.critical,
          },
        ),
        _rejected('normal'),
      );
    });

    test('Guest is every protected app Critical, nothing else', () {
      expect(() => SecurityProfile(kind: SecurityProfileKind.guest),
          _rejected('guest'));
      expect(
        () => SecurityProfile(
          kind: SecurityProfileKind.guest,
          allProtectedLevel: AppSecurityLevel.sensitive,
        ),
        _rejected('guest'),
      );
      expect(
        () => SecurityProfile(
          kind: SecurityProfileKind.guest,
          allProtectedLevel: AppSecurityLevel.critical,
          appLevels: const <String, AppSecurityLevel>{
            _notes: AppSecurityLevel.critical,
          },
        ),
        _rejected('guest'),
      );
    });

    test('invalid package, own package and too many apps are rejected', () {
      expect(
        () => SecurityProfile(
          kind: SecurityProfileKind.work,
          appLevels: const <String, AppSecurityLevel>{
            'not a package': AppSecurityLevel.critical,
          },
        ),
        _rejected('apps'),
      );
      expect(
        () => SecurityProfile(
          kind: SecurityProfileKind.kids,
          appLevels: const <String, AppSecurityLevel>{
            SecurityProfile.ownPackage: AppSecurityLevel.critical,
          },
        ),
        _rejected('apps'),
      );
      final Map<String, AppSecurityLevel> many = <String, AppSecurityLevel>{
        for (int i = 0; i <= SecurityProfile.maxApps; i++)
          'com.example.app$i': AppSecurityLevel.sensitive,
      };
      expect(
        () => SecurityProfile(kind: SecurityProfileKind.home, appLevels: many),
        _rejected('apps'),
      );
      many.remove(many.keys.first);
      expect(
        SecurityProfile(kind: SecurityProfileKind.home, appLevels: many)
            .appLevels,
        hasLength(SecurityProfile.maxApps),
      );
    });
  });

  group('exactly one active profile', () {
    List<SecurityProfile> presets() => <SecurityProfile>[
          for (final SecurityProfileKind k in SecurityProfileKind.values)
            SecurityProfile.preset(k),
        ];

    test('the active id must name exactly one existing profile', () {
      expect(
        () => SecurityProfileSet(profiles: presets(), activeProfileId: 'party'),
        _rejected('activeProfileId'),
      );
      expect(
        () => SecurityProfileSet(profiles: presets(), activeProfileId: ''),
        _rejected('activeProfileId'),
      );
      for (final SecurityProfileKind k in SecurityProfileKind.values) {
        final SecurityProfileSet set =
            SecurityProfileSet(profiles: presets(), activeProfileId: k.id);
        expect(set.active.kind, k);
        expect(
          set.profiles
              .where((SecurityProfile p) => p.id == set.activeProfileId),
          hasLength(1),
        );
      }
    });

    test('duplicates and missing presets are rejected', () {
      expect(
        () => SecurityProfileSet(
          profiles: <SecurityProfile>[
            ...presets(),
            SecurityProfile.preset(SecurityProfileKind.kids),
          ],
          activeProfileId: 'normal',
        ),
        _rejected('profiles'),
      );
      expect(
        () => SecurityProfileSet(
          profiles: presets().sublist(1),
          activeProfileId: 'home',
        ),
        _rejected('profiles'),
      );
    });

    test('input order does not matter; output is canonical', () {
      final SecurityProfileSet a =
          SecurityProfileSet(profiles: presets(), activeProfileId: 'kids');
      final SecurityProfileSet b = SecurityProfileSet(
        profiles: presets().reversed,
        activeProfileId: 'kids',
      );
      expect(b, a);
      expect(b.hashCode, a.hashCode);
      expect(
          SecurityProfileDocument.encode(b), SecurityProfileDocument.encode(a));
    });

    test('the profile list is unmodifiable', () {
      final SecurityProfileSet set = SecurityProfileSet.defaults();
      expect(() => set.profiles.add(set.active), throwsUnsupportedError);
    });
  });

  group('document', () {
    test('round trip keeps every field', () {
      final SecurityProfileSet set = SecurityProfileSet(
        profiles: <SecurityProfile>[
          SecurityProfile.preset(SecurityProfileKind.normal),
          SecurityProfile(
            kind: SecurityProfileKind.home,
            allProtectedLevel: AppSecurityLevel.sensitive,
          ),
          SecurityProfile(
            kind: SecurityProfileKind.work,
            appLevels: const <String, AppSecurityLevel>{
              _bank: AppSecurityLevel.critical,
            },
          ),
          SecurityProfile.preset(SecurityProfileKind.guest),
          SecurityProfile(
            kind: SecurityProfileKind.kids,
            appLevels: const <String, AppSecurityLevel>{
              _notes: AppSecurityLevel.critical,
              _bank: AppSecurityLevel.sensitive,
            },
          ),
        ],
        activeProfileId: 'work',
      );
      final String raw = SecurityProfileDocument.encode(set);
      final SecurityProfileSet back = SecurityProfileDocument.decode(raw);
      expect(back, set);
      expect(SecurityProfileDocument.encode(back), raw);
      final Map<String, Object?> json = jsonDecode(raw) as Map<String, Object?>;
      expect(json.keys.toSet(),
          <String>{'version', 'activeProfileId', 'profiles'});
      expect(json['version'], SecurityProfileDocument.version);
    });

    test('not JSON / not an object are corrupt, never defaults', () {
      for (final String raw in <String>['', '{', '[]', 'null', '42']) {
        expect(
          () => SecurityProfileDocument.decode(raw),
          throwsA(isA<SecurityProfileDocumentException>().having(
            (SecurityProfileDocumentException e) => e.problem,
            'problem',
            SecurityProfileDocumentProblem.corrupt,
          )),
          reason: raw,
        );
      }
    });

    test('a per-profile isActive flag (legacy style) is rejected', () {
      final Map<String, Object?> json = jsonDecode(
        SecurityProfileDocument.encode(SecurityProfileSet.defaults()),
      ) as Map<String, Object?>;
      ((json['profiles']! as List<Object?>).first!
          as Map<String, Object?>)['isActive'] = true;
      expect(() => SecurityProfileDocument.decode(jsonEncode(json)),
          throwsA(isA<SecurityProfileDocumentException>()));
    });
  });
}
