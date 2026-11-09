// Phase 10 / M1 (PRD 10A, 10C, 10D, 10E): Smart Rule model, validation and
// versioned serialization. Pure Dart over the production model and codec.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_lock/rules/smart_rule.dart';
import 'package:smart_app_lock/rules/smart_rule_document.dart';

const String _mail = 'com.example.mail';
const String _bank = 'com.example.bank';

SmartRule _rule({
  String id = 'r1',
  String name = 'Work hours',
  Iterable<String> targets = const <String>[_mail],
  Iterable<int> days = SmartRuleDays.weekdays,
  SmartRuleTime? time,
  bool enabled = true,
}) =>
    SmartRule(
      id: id,
      name: name,
      targetPackages: targets,
      days: days,
      time: time ?? SmartRuleTime.window(startMinute: 540, endMinute: 1020),
      enabled: enabled,
    );

Matcher _formatError(String field) => isA<SmartRuleFormatException>()
    .having((SmartRuleFormatException e) => e.field, 'field', field);

TypeMatcher<SmartRuleDocumentException> _docError(
  SmartRuleDocumentProblem p,
) =>
    isA<SmartRuleDocumentException>()
        .having((SmartRuleDocumentException e) => e.problem, 'problem', p);

Map<String, Object?> _ruleJson([Map<String, Object?> patch = const {}]) =>
    <String, Object?>{..._rule().toJson(), ...patch};

String _doc(List<Object?> rules, {Object? version = 2}) => jsonEncode(
      <String, Object?>{
        'schema': 'smart_rules',
        'version': version,
        'rules': rules,
      },
    );

void main() {
  group('1. valid construction', () {
    test('every field is kept; enabled by default; lists are unmodifiable', () {
      final SmartRule r = _rule();
      expect(r.id, 'r1');
      expect(r.name, 'Work hours');
      expect(r.enabled, isTrue);
      expect(r.targetPackages, <String>[_mail]);
      expect(r.days, <int>[1, 2, 3, 4, 5]);
      expect(
        r.time,
        SmartRuleTime.window(startMinute: 540, endMinute: 1020),
      );
      expect(() => r.targetPackages.add(_bank), throwsUnsupportedError);
      expect(() => r.days.add(6), throwsUnsupportedError);
    });

    test('explicit disabled state is kept (not a deletion)', () {
      expect(_rule(enabled: false).enabled, isFalse);
    });

    test('name is trimmed at the input boundary', () {
      expect(_rule(name: '  Night  ').name, 'Night');
    });

    test('id grammar: letters, digits, "_" and "-", 1–64', () {
      expect(_rule(id: 'a').id, 'a');
      expect(_rule(id: 'Rule_2-b').id, 'Rule_2-b');
      expect(_rule(id: 'x' * 64).id, 'x' * 64);
      for (final String bad in <String>[
        '',
        '-a',
        '_a',
        'a b',
        'a.b',
        'x' * 65
      ]) {
        expect(() => _rule(id: bad), throwsA(_formatError('id')), reason: bad);
      }
    });

    test('equality and hashCode cover every field; copyWith keeps the id', () {
      expect(_rule(), _rule());
      expect(_rule().hashCode, _rule().hashCode);
      expect(_rule(), isNot(_rule(name: 'Other')));
      expect(_rule(), isNot(_rule(enabled: false)));
      expect(_rule(), isNot(_rule(targets: <String>[_bank])));
      expect(_rule(), isNot(_rule(days: <int>[1])));
      expect(_rule(), isNot(_rule(time: const SmartRuleTime.allDay())));
      final SmartRule c = _rule().copyWith(enabled: false, name: 'X');
      expect(c.id, 'r1');
      expect(c.enabled, isFalse);
      expect(c.name, 'X');
      expect(c.targetPackages, _rule().targetPackages);
      expect(_rule().copyWith(), _rule());
    });

    test('copyWith validates again', () {
      expect(
        () => _rule().copyWith(targetPackages: <String>[]),
        throwsA(_formatError('targetPackages')),
      );
      expect(() => _rule().copyWith(name: ' '), throwsA(_formatError('name')));
    });
  });

  group('2. invalid name', () {
    test('blank, whitespace-only, too long, control characters', () {
      for (final String bad in <String>['', '   ', '\t\n']) {
        expect(() => _rule(name: bad), throwsA(_formatError('name')));
      }
      expect(() => _rule(name: 'a' * 81), throwsA(_formatError('name')));
      expect(_rule(name: 'a' * 80).name, 'a' * 80);
      expect(() => _rule(name: 'a\nb'), throwsA(_formatError('name')));
      expect(() => _rule(name: 'a\u0000b'), throwsA(_formatError('name')));
      expect(() => _rule(name: 'a\u007Fb'), throwsA(_formatError('name')));
      expect(_rule(name: 'Nuit 🌙 é').name, 'Nuit 🌙 é');
    });
  });

  group('3. empty / invalid targets', () {
    test('an empty selection is rejected; it never means all apps', () {
      expect(
        () => _rule(targets: const <String>[]),
        throwsA(_formatError('targetPackages')),
      );
    });

    test('blank and malformed package names are rejected, never rewritten', () {
      for (final String bad in <String>[
        '',
        ' ',
        ' com.example.mail',
        'com.example.mail ',
        'whatsapp', // one segment
        'com..mail',
        '.com.mail',
        'com.mail.',
        '1com.mail',
        'com.1mail',
        'com.ma il',
        'com.mail*',
        '*',
        'com/mail.x',
        'com.example.${'a' * 250}', // over 255
      ]) {
        expect(
          () => _rule(targets: <String>[_mail, bad]),
          throwsA(_formatError('targetPackages')),
          reason: '"$bad"',
        );
      }
      expect(SmartRule.isValidPackageName('com.Example_1.mail'), isTrue);
      expect(SmartRule.isValidPackageName(null), isFalse);
      expect(SmartRule.isValidPackageName(42), isFalse);
    });
  });

  group('4. duplicate package normalization', () {
    test('exact duplicates removed and sorted; distinct ids never merged', () {
      final SmartRule r = _rule(
        targets: <String>[
          _mail,
          'com.Example.mail',
          _bank,
          _mail,
          'com.example.mail2'
        ],
      );
      expect(r.targetPackages, <String>[
        'com.Example.mail', // case differs: a different package
        _bank,
        _mail,
        'com.example.mail2',
      ]);
      expect(r.targets(_mail), isTrue);
      expect(r.targets('com.Example.mail'), isTrue);
      expect(r.targets('com.example.MAIL'), isFalse);
    });

    test('input order does not change the rule', () {
      expect(
        _rule(targets: <String>[_mail, _bank]),
        _rule(targets: <String>[_bank, _mail, _bank]),
      );
    });
  });

  group('5. invalid weekday values', () {
    test('0, 8 and negatives are rejected', () {
      for (final int bad in <int>[0, 8, -1, 70]) {
        expect(
          () => _rule(days: <int>[1, bad]),
          throwsA(_formatError('days')),
          reason: '$bad',
        );
      }
    });

    test('Monday = 1 … Sunday = 7, matching DateTime; previous() wraps', () {
      expect(SmartRuleDays.monday, DateTime.monday);
      expect(SmartRuleDays.sunday, DateTime.sunday);
      expect(DateTime(2026, 11, 2).weekday, 1); // a Monday
      expect(DateTime(2026, 11, 8).weekday, 7); // a Sunday
      expect(SmartRuleDays.previous(1), 7);
      expect(SmartRuleDays.previous(2), 1);
      expect(SmartRuleDays.previous(7), 6);
      expect(SmartRuleDays.weekdays, <int>[1, 2, 3, 4, 5]);
      expect(SmartRuleDays.weekend, <int>[6, 7]);
      expect(SmartRuleDays.everyDay, <int>[1, 2, 3, 4, 5, 6, 7]);
    });
  });

  group('6. selected days', () {
    test('an empty selection is rejected', () {
      expect(() => _rule(days: const <int>[]), throwsA(_formatError('days')));
    });

    test('duplicates removed and sorted; one or many days', () {
      expect(_rule(days: <int>[7, 1, 7, 3, 1]).days, <int>[1, 3, 7]);
      expect(_rule(days: <int>[6]).days, <int>[6]);
    });
  });

  group('7. invalid start / end minutes', () {
    test('outside 0..1439 is rejected', () {
      for (final List<int> bad in <List<int>>[
        <int>[-1, 60],
        <int>[60, -1],
        <int>[1440, 60],
        <int>[60, 1440],
      ]) {
        expect(
          () => SmartRuleTime.window(startMinute: bad[0], endMinute: bad[1]),
          throwsA(_formatError('time')),
          reason: '$bad',
        );
      }
    });

    test('zero length is rejected, never read as all day', () {
      for (final int m in <int>[0, 540, 1439]) {
        expect(
          () => SmartRuleTime.window(startMinute: m, endMinute: m),
          throwsA(_formatError('time')),
        );
      }
    });

    test('valid extremes; all day is its own explicit value', () {
      final SmartRuleWindow w = SmartRuleTime.window(
        startMinute: 1439,
        endMinute: 0,
      ) as SmartRuleWindow;
      expect(w.crossesMidnight, isTrue);
      expect(
        (SmartRuleTime.window(startMinute: 0, endMinute: 1439)
                as SmartRuleWindow)
            .crossesMidnight,
        isFalse,
      );
      expect(const SmartRuleTime.allDay(), isA<SmartRuleAllDay>());
      expect(const SmartRuleTime.allDay(), const SmartRuleTime.allDay());
      expect(w.toString(), '23:59–00:00');
    });
  });

  group('8. serialization round trip', () {
    test('rule JSON round trip is exact and deterministic', () {
      final SmartRule r = _rule(
        targets: <String>[_mail, _bank],
        days: <int>[6, 7],
        time: SmartRuleTime.window(startMinute: 1320, endMinute: 360),
        enabled: false,
      );
      expect(SmartRule.fromJson(r.toJson()), r);
      expect(jsonEncode(r.toJson()), jsonEncode(r.toJson()));
      expect(
          jsonEncode(r.toJson()),
          jsonEncode(_rule(
            targets: <String>[_bank, _mail, _mail],
            days: <int>[7, 6],
            time: SmartRuleTime.window(startMinute: 1320, endMinute: 360),
            enabled: false,
          ).toJson()));
    });

    test(
        'document v3 (level rules keep the v2 layout): exact format, order '
        'kept, round trip', () {
      final List<SmartRule> rules = <SmartRule>[
        _rule(id: 'b'),
        _rule(id: 'a', time: const SmartRuleTime.allDay(), days: <int>[1]),
      ];
      final String encoded = SmartRuleDocument.encode(rules);
      expect(
        encoded,
        '{"schema":"smart_rules","version":3,"rules":['
        '{"id":"b","name":"Work hours","enabled":true,'
        '"targets":["com.example.mail"],"days":[1,2,3,4,5],'
        '"time":{"type":"window","start":540,"end":1020},'
        '"action":"standard"},'
        '{"id":"a","name":"Work hours","enabled":true,'
        '"targets":["com.example.mail"],"days":[1],'
        '"time":{"type":"allDay"},"action":"standard"}]}',
      );
      expect(SmartRuleDocument.decode(encoded), rules);
      expect(SmartRuleDocument.decode(SmartRuleDocument.encode(const [])),
          isEmpty);
    });

    test('encode refuses duplicate ids', () {
      expect(
        () => SmartRuleDocument.encode(<SmartRule>[_rule(), _rule()]),
        throwsArgumentError,
      );
    });
  });

  group('9. schema versions', () {
    test('a newer version is reported as unsupported, with the version', () {
      expect(
        () => SmartRuleDocument.decode(_doc(<Object?>[], version: 4)),
        throwsA(
          _docError(SmartRuleDocumentProblem.unsupportedVersion).having(
            (SmartRuleDocumentException e) => e.version,
            'version',
            4,
          ),
        ),
      );
    });

    test('versions no build wrote, or a missing version, are corrupt', () {
      for (final Object? v in <Object?>[0, -1, null, '1', 1.0]) {
        expect(
          () => SmartRuleDocument.decode(_doc(<Object?>[], version: v)),
          throwsA(_docError(SmartRuleDocumentProblem.corrupt)),
          reason: '$v',
        );
      }
    });
  });

  group('10. corrupt persisted data', () {
    test('broken JSON, wrong shape, wrong schema, extra fields', () {
      for (final String bad in <String>[
        '',
        '{',
        'null',
        '[]',
        '"x"',
        '{"schema":"other","version":1,"rules":[]}',
        '{"version":1,"rules":[]}',
        '{"schema":"smart_rules","version":1}',
        '{"schema":"smart_rules","version":1,"rules":{}}',
        '{"schema":"smart_rules","version":1,"rules":[],"extra":1}',
      ]) {
        expect(
          () => SmartRuleDocument.decode(bad),
          throwsA(_docError(SmartRuleDocumentProblem.corrupt)),
          reason: bad,
        );
      }
    });

    test('one bad rule makes the whole document corrupt (no partial list)', () {
      final List<Map<String, Object?>> badRules = <Map<String, Object?>>[
        _ruleJson(<String, Object?>{'name': ''}),
        _ruleJson(<String, Object?>{'name': ' Work hours'}), // not canonical
        _ruleJson(<String, Object?>{'targets': <Object?>[]}),
        _ruleJson(<String, Object?>{
          'targets': <Object?>['*']
        }),
        _ruleJson(<String, Object?>{
          'targets': <Object?>[_mail, _bank]
        }),
        _ruleJson(<String, Object?>{
          'targets': <Object?>[_mail, _mail]
        }),
        _ruleJson(<String, Object?>{
          'targets': <Object?>[1]
        }),
        _ruleJson(<String, Object?>{'targets': null}),
        _ruleJson(<String, Object?>{'days': <Object?>[]}),
        _ruleJson(<String, Object?>{
          'days': <Object?>[0]
        }),
        _ruleJson(<String, Object?>{
          'days': <Object?>[2, 1]
        }),
        _ruleJson(<String, Object?>{
          'days': <Object?>[1, 1]
        }),
        _ruleJson(<String, Object?>{
          'days': <Object?>['1']
        }),
        _ruleJson(<String, Object?>{'enabled': 1}),
        _ruleJson(<String, Object?>{'id': 7}),
        _ruleJson(<String, Object?>{'id': 'a b'}),
        _ruleJson(<String, Object?>{'extra': true}),
        _ruleJson(<String, Object?>{
          'time': <String, Object?>{'type': 'window', 'start': 60, 'end': 60},
        }),
        _ruleJson(<String, Object?>{
          'time': <String, Object?>{'type': 'window', 'start': 60},
        }),
        _ruleJson(<String, Object?>{
          'time': <String, Object?>{'type': 'window', 'start': 60.0, 'end': 9},
        }),
        _ruleJson(<String, Object?>{
          'time': <String, Object?>{'type': 'always'},
        }),
        _ruleJson(<String, Object?>{
          'time': <String, Object?>{'type': 'allDay', 'start': 0},
        }),
        _ruleJson(<String, Object?>{'time': null}),
      ];
      final Map<String, Object?> good = _rule(id: 'ok').toJson();
      for (final Map<String, Object?> bad in badRules) {
        expect(
          () => SmartRuleDocument.decode(_doc(<Object?>[good, bad])),
          throwsA(_docError(SmartRuleDocumentProblem.corrupt)),
          reason: '$bad',
        );
      }
      final Map<String, Object?> missing = _ruleJson()..remove('enabled');
      expect(
        () => SmartRuleDocument.decode(_doc(<Object?>[missing])),
        throwsA(_docError(SmartRuleDocumentProblem.corrupt)),
      );
    });

    test('duplicate ids in storage are corrupt', () {
      final Map<String, Object?> r = _rule().toJson();
      expect(
        () => SmartRuleDocument.decode(_doc(<Object?>[r, r])),
        throwsA(_docError(SmartRuleDocumentProblem.corrupt)),
      );
    });
  });
}
