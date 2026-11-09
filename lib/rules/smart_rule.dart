/// Phase 10 / M1 (PRD 10A, 10C, 10D, 10E): the Smart Rule domain model.
///
/// Pure Dart, immutable and validated at construction. A [SmartRule] is
/// configuration only: it says WHICH apps, on WHICH days and at WHAT local
/// time a rule applies. Phase 10 / M2 adds a typed [SmartRuleAction] (the
/// security level the rule asks for). Actions can only RAISE protection
/// above an app's saved level; see `SmartRulePolicy`. Evaluation lives in
/// `SmartRuleEvaluator`; persistence in `SmartRuleRepository`.
///
/// Not to be confused with the Phase 1 scaffolding `LockRule` /
/// `RuleEngine` (single package, `null` = every app), which no production
/// path uses and which these rules never read or write.
///
/// Boundaries (see `docs/architecture.md`, Phase 10 / M1):
///  * [SmartRule.new] and [SmartRuleTime.window] validate and normalize user
///    input (name trimmed; packages and days de-duplicated and sorted).
///  * [SmartRule.fromJson] is strict: persisted data must already be in that
///    canonical form, otherwise it is rejected as corrupt (never repaired).
library;

import '../data/models/app_security_level.dart';

/// Rule data that failed validation. [field] names the offending part
/// (`id`, `name`, `targetPackages`, `days`, `time`, `rule`).
class SmartRuleFormatException implements Exception {
  const SmartRuleFormatException(this.field, this.message);

  final String field;
  final String message;

  @override
  String toString() => 'SmartRuleFormatException($field): $message';
}

/// Weekday convention: Dart's [DateTime.weekday] numbers, Monday = 1 through
/// Sunday = 7. Never locale-dependent (no "first day of week" setting).
abstract final class SmartRuleDays {
  static const int monday = DateTime.monday;
  static const int sunday = DateTime.sunday;

  /// Every day, Monday to Sunday.
  static const List<int> everyDay = <int>[1, 2, 3, 4, 5, 6, 7];

  /// Monday to Friday.
  static const List<int> weekdays = <int>[1, 2, 3, 4, 5];

  /// Saturday and Sunday.
  static const List<int> weekend = <int>[6, 7];

  /// True for an int in 1..7.
  static bool isValid(Object? day) =>
      day is int && day >= DateTime.monday && day <= DateTime.sunday;

  /// The day before [day]; Monday's previous day is Sunday (week rollover).
  static int previous(int day) =>
      day == DateTime.monday ? DateTime.sunday : day - 1;
}

/// The time-of-day condition (PRD 10C), in local minutes since midnight.
///
/// Either an explicit [SmartRuleTime.allDay] or a [SmartRuleTime.window]
/// with `startMinute != endMinute`. A zero-length window is rejected; it is
/// never read as "all day" or "always".
sealed class SmartRuleTime {
  const SmartRuleTime._();

  static const int minutesPerDay = 24 * 60;

  /// The whole selected day, 00:00 up to the next 00:00.
  const factory SmartRuleTime.allDay() = SmartRuleAllDay;

  /// `[startMinute, endMinute)`: start inclusive, end exclusive, both
  /// 0..1439. `startMinute > endMinute` crosses midnight (22:00–06:00); the
  /// part after midnight belongs to the day the window started.
  factory SmartRuleTime.window({
    required int startMinute,
    required int endMinute,
  }) {
    if (!_isMinute(startMinute)) {
      throw SmartRuleFormatException(
        'time',
        'Start minute must be 0..1439, got $startMinute.',
      );
    }
    if (!_isMinute(endMinute)) {
      throw SmartRuleFormatException(
        'time',
        'End minute must be 0..1439, got $endMinute.',
      );
    }
    if (startMinute == endMinute) {
      throw const SmartRuleFormatException(
        'time',
        'A time window cannot start and end at the same minute. Use '
            'SmartRuleTime.allDay() for the whole day.',
      );
    }
    return SmartRuleWindow._(startMinute, endMinute);
  }

  static bool _isMinute(Object? m) => m is int && m >= 0 && m < minutesPerDay;

  Map<String, Object?> toJson();

  /// Strict decode of [toJson] output.
  static SmartRuleTime fromJson(Object? raw) {
    if (raw is! Map) {
      throw const SmartRuleFormatException('time', 'Not an object.');
    }
    final Object? type = raw['type'];
    if (type == SmartRuleAllDay._type) {
      _exactKeys(raw, const <String>{'type'}, 'time');
      return const SmartRuleAllDay();
    }
    if (type == SmartRuleWindow._type) {
      _exactKeys(raw, const <String>{'type', 'start', 'end'}, 'time');
      final Object? start = raw['start'];
      final Object? end = raw['end'];
      if (start is! int || end is! int) {
        throw const SmartRuleFormatException('time', 'Minutes must be ints.');
      }
      return SmartRuleTime.window(startMinute: start, endMinute: end);
    }
    throw SmartRuleFormatException('time', 'Unknown time type: $type.');
  }
}

/// The whole selected day.
final class SmartRuleAllDay extends SmartRuleTime {
  const SmartRuleAllDay() : super._();

  static const String _type = 'allDay';

  @override
  Map<String, Object?> toJson() => const <String, Object?>{'type': _type};

  @override
  bool operator ==(Object other) => other is SmartRuleAllDay;

  @override
  int get hashCode => _type.hashCode;

  @override
  String toString() => 'allDay';
}

/// A validated `[startMinute, endMinute)` window; see [SmartRuleTime.window].
final class SmartRuleWindow extends SmartRuleTime {
  const SmartRuleWindow._(this.startMinute, this.endMinute) : super._();

  static const String _type = 'window';

  /// Inclusive, 0..1439.
  final int startMinute;

  /// Exclusive, 0..1439, never equal to [startMinute].
  final int endMinute;

  /// True for windows such as 22:00–06:00.
  bool get crossesMidnight => startMinute > endMinute;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'type': _type,
        'start': startMinute,
        'end': endMinute,
      };

  @override
  bool operator ==(Object other) =>
      other is SmartRuleWindow &&
      other.startMinute == startMinute &&
      other.endMinute == endMinute;

  @override
  int get hashCode => Object.hash(_type, startMinute, endMinute);

  @override
  String toString() => '${_hhmm(startMinute)}–${_hhmm(endMinute)}';

  static String _hhmm(int m) => '${(m ~/ 60).toString().padLeft(2, '0')}:'
      '${(m % 60).toString().padLeft(2, '0')}';
}

/// Phase 10 / M2 (PRD 10F): the security level a rule asks for while it
/// matches.
///
/// Raise-only: [sensitive] and [critical] can make an app stricter than its
/// saved level. [standard] never changes anything (every protected app is at
/// least Standard). [unlocked] is RESERVED: accepted so stored data stays
/// readable, never offered by the UI, never sent to native enforcement and
/// never lowers protection. An unknown stored id is corrupt data; it never
/// falls back to Standard.
enum SmartRuleAction {
  standard('standard', 'Standard'),
  sensitive('sensitive', 'Sensitive'),
  critical('critical', 'Critical'),
  unlocked('unlocked', 'Unlocked'),

  /// Phase 11 / M3: while the rule matches, the referenced Security
  /// Profile's raise-only overlay applies IN ADDITION to the manually
  /// selected profile ([SmartRule.profileId]). Never raises an app by
  /// itself (no targets); compiled by `SecurityProfilePolicy`. Schema v3.
  applyProfile('profile', 'Apply profile');

  const SmartRuleAction(this.storageId, this.label);

  /// Persisted id (exact, case-sensitive).
  final String storageId;

  /// User-facing name.
  final String label;

  /// The level this action can raise an app to, or null when it can never
  /// raise one ([standard], [unlocked]).
  AppSecurityLevel? get raisesTo => switch (this) {
        SmartRuleAction.sensitive => AppSecurityLevel.sensitive,
        SmartRuleAction.critical => AppSecurityLevel.critical,
        SmartRuleAction.standard ||
        SmartRuleAction.unlocked ||
        SmartRuleAction.applyProfile =>
          null,
      };

  /// Whether this action can ever change enforcement.
  bool get canRaise => raisesTo != null;

  /// The level actions (everything except [applyProfile]), in order of
  /// declaration. A level rule always has targets; a profile rule never
  /// does.
  static const List<SmartRuleAction> levelActions = <SmartRuleAction>[
    standard,
    sensitive,
    critical,
    unlocked,
  ];

  /// Exact id → action; anything else → null (the caller rejects it).
  static SmartRuleAction? fromStorageId(Object? raw) {
    for (final SmartRuleAction a in values) {
      if (a.storageId == raw) return a;
    }
    return null;
  }

  /// The action a migrated v1 rule receives. v1 rules had no action and
  /// were never enforced; [standard] keeps them without any enforcement
  /// effect (no surprise activation) while preserving their enabled state.
  static const SmartRuleAction migratedFromV1 = SmartRuleAction.standard;
}

/// One Smart Rule (PRD 10A): stable id, name, enabled state, exact target
/// packages (10E), selected days (10D), a local time condition (10C) and,
/// from M2, the requested [action] (10F).
///
/// Equality covers every field; lists are sorted, so equal rules serialize
/// to identical JSON. No timestamps are stored: nothing in M1 needs them and
/// reading a clock here would make the model non-deterministic.
final class SmartRule {
  const SmartRule._({
    required this.id,
    required this.name,
    required this.enabled,
    required this.targetPackages,
    required this.days,
    required this.time,
    required this.action,
    required this.profileId,
  });

  /// Validates and normalizes. Throws [SmartRuleFormatException].
  ///
  ///  * [id]: 1–64 of `A-Z a-z 0-9 _ -`, starting with a letter or digit.
  ///  * [name]: trimmed; not blank; at most [maxNameLength] characters; no
  ///    control characters.
  ///  * [targetPackages]: at least one; each an Android package name
  ///    ([isValidPackageName]); exact, case-sensitive, never trimmed or
  ///    rewritten; duplicates removed; sorted. An empty set is rejected; it
  ///    never means "all apps".
  ///  * [days]: at least one of 1..7 (Monday = 1); duplicates removed;
  ///    sorted.
  ///  * Phase 11 / M3: [SmartRuleAction.applyProfile] requires a valid
  ///    [profileId] ([isValidProfileId]) and NO [targetPackages] (the
  ///    profile defines the apps); every other action requires targets and
  ///    no [profileId].
  factory SmartRule({
    required String id,
    required String name,
    required Iterable<String> targetPackages,
    required Iterable<int> days,
    required SmartRuleTime time,
    bool enabled = true,
    SmartRuleAction action = SmartRuleAction.standard,
    String? profileId,
  }) {
    final bool profileRule = action == SmartRuleAction.applyProfile;
    if (profileRule) {
      if (!isValidProfileId(profileId)) {
        throw SmartRuleFormatException(
          'profile',
          'Not a valid profile id: "$profileId".',
        );
      }
      if (targetPackages.isNotEmpty) {
        throw const SmartRuleFormatException(
          'targetPackages',
          'A profile rule has no app list; the profile defines the apps.',
        );
      }
    } else if (profileId != null) {
      throw const SmartRuleFormatException(
        'profile',
        'Only an "Apply profile" rule references a profile.',
      );
    }
    return SmartRule._(
      id: _validId(id),
      name: _validName(name),
      enabled: enabled,
      targetPackages:
          profileRule ? const <String>[] : _validTargets(targetPackages),
      days: _validDays(days),
      time: time,
      action: action,
      profileId: profileRule ? profileId : null,
    );
  }

  /// Phase 11 / M3: profile ids a rule may reference: the five preset ids
  /// or `custom-` + 12 lowercase hex digits (same grammar as
  /// `SecurityProfile`). Existence is checked against the profile set when
  /// the policy is compiled (a missing profile fails closed).
  static bool isValidProfileId(Object? value) =>
      value is String && _profileIdPattern.hasMatch(value);

  static final RegExp _profileIdPattern =
      RegExp(r'^(normal|home|work|guest|kids|custom-[0-9a-f]{12})$');

  static const int maxIdLength = 64;
  static const int maxNameLength = 80;
  static const int maxPackageNameLength = 255;

  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]*$');

  /// Android package grammar: two or more dot-separated segments, each a
  /// letter followed by letters, digits or `_`.
  static final RegExp _packagePattern =
      RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$');

  /// Stable identifier (persistence key; unique within the rule set).
  final String id;

  /// User-readable name.
  final String name;

  /// A disabled rule is kept (not deleted) and never matches.
  final bool enabled;

  /// Exact package names, sorted, unique, never empty.
  final List<String> targetPackages;

  /// Selected weekdays (Monday = 1 … Sunday = 7), sorted, unique, never
  /// empty.
  final List<int> days;

  final SmartRuleTime time;

  /// Phase 10 / M2: the requested security level (raise-only).
  final SmartRuleAction action;

  /// Phase 11 / M3: the profile an [SmartRuleAction.applyProfile] rule
  /// activates while it matches; null for every other action.
  final String? profileId;

  /// Phase 11 / M3: whether this rule activates a profile.
  bool get isProfileRule => action == SmartRuleAction.applyProfile;

  /// True when [packageName] is one of [targetPackages] (exact match).
  bool targets(String packageName) => targetPackages.contains(packageName);

  /// True for a well-formed Android package name (see [_packagePattern]).
  static bool isValidPackageName(Object? value) =>
      value is String &&
      value.length <= maxPackageNameLength &&
      _packagePattern.hasMatch(value);

  /// A copy with the given fields replaced, validated again. The [id] never
  /// changes. (Switching between a level action and
  /// [SmartRuleAction.applyProfile] needs the constructor.)
  SmartRule copyWith({
    String? name,
    Iterable<String>? targetPackages,
    Iterable<int>? days,
    SmartRuleTime? time,
    bool? enabled,
    SmartRuleAction? action,
    String? profileId,
  }) {
    return SmartRule(
      id: id,
      name: name ?? this.name,
      targetPackages: targetPackages ?? this.targetPackages,
      days: days ?? this.days,
      time: time ?? this.time,
      enabled: enabled ?? this.enabled,
      action: action ?? this.action,
      profileId: profileId ?? this.profileId,
    );
  }

  /// Rule JSON layout version written by [toJson] (document schema v3).
  static const int jsonVersion = 3;

  /// Level rules keep the exact v2 layout. A profile rule (v3 only) has no
  /// `targets` and a required `profile`.
  Map<String, Object?> toJson() => isProfileRule
      ? <String, Object?>{
          'id': id,
          'name': name,
          'enabled': enabled,
          'days': List<int>.of(days),
          'time': time.toJson(),
          'action': action.storageId,
          'profile': profileId,
        }
      : <String, Object?>{
          'id': id,
          'name': name,
          'enabled': enabled,
          'targets': List<String>.of(targetPackages),
          'days': List<int>.of(days),
          'time': time.toJson(),
          'action': action.storageId,
        };

  /// v1 (Phase 10 / M1) rule fields: no action.
  static const Set<String> _jsonKeysV1 = <String>{
    'id',
    'name',
    'enabled',
    'targets',
    'days',
    'time',
  };

  /// v2 (Phase 10 / M2) rule fields: v1 plus a required `action`. Also the
  /// v3 layout of every level rule.
  static const Set<String> _jsonKeys = <String>{..._jsonKeysV1, 'action'};

  /// v3 (Phase 11 / M3) profile rule fields: no `targets`, plus `profile`.
  static const Set<String> _jsonKeysProfile = <String>{
    'id',
    'name',
    'enabled',
    'days',
    'time',
    'action',
    'profile',
  };

  /// Strict decode of persisted [toJson] output. Rejects missing, unknown or
  /// mistyped fields and anything not already canonical (untrimmed name,
  /// unsorted or duplicated packages or days). Throws
  /// [SmartRuleFormatException]; never returns a repaired rule.
  ///
  /// Phase 10 / M2: [version] is the rule layout of the containing document.
  /// `1` = M1 layout (no `action` allowed); the rule is migrated explicitly
  /// with [SmartRuleAction.migratedFromV1]. `2` = current layout; `action`
  /// is required and must be an exact known id (no fallback). Any other
  /// value is rejected.
  ///
  /// Phase 11 / M3: `3` = v2 layout for level rules, or the profile layout
  /// ([_jsonKeysProfile]) for `action: "profile"`. A `"profile"` action in a
  /// v1/v2 document is rejected (it never existed there).
  static SmartRule fromJson(Object? raw, {int version = jsonVersion}) {
    if (raw is! Map) {
      throw const SmartRuleFormatException('rule', 'Not an object.');
    }
    if (version != 1 && version != 2 && version != jsonVersion) {
      throw SmartRuleFormatException('rule', 'Unknown rule layout $version.');
    }
    final SmartRuleAction? action = version == 1
        ? SmartRuleAction.migratedFromV1
        : SmartRuleAction.fromStorageId(raw['action']);
    if (action == null ||
        (action == SmartRuleAction.applyProfile && version < 3)) {
      throw SmartRuleFormatException(
        'action',
        'Unknown action: ${raw['action']}.',
      );
    }
    final bool profileRule = action == SmartRuleAction.applyProfile;
    _exactKeys(
      raw,
      version == 1
          ? _jsonKeysV1
          : profileRule
              ? _jsonKeysProfile
              : _jsonKeys,
      'rule',
    );
    final Object? profile = profileRule ? raw['profile'] : null;
    if (profileRule && profile is! String) {
      throw const SmartRuleFormatException('profile', 'Not a string.');
    }
    final Object? id = raw['id'];
    final Object? name = raw['name'];
    final Object? enabled = raw['enabled'];
    final Object? targets = profileRule ? const <String>[] : raw['targets'];
    final Object? days = raw['days'];
    if (id is! String) {
      throw const SmartRuleFormatException('id', 'Not a string.');
    }
    if (name is! String) {
      throw const SmartRuleFormatException('name', 'Not a string.');
    }
    if (enabled is! bool) {
      throw const SmartRuleFormatException('rule', '"enabled" is not a bool.');
    }
    if (targets is! List || targets.any((Object? t) => t is! String)) {
      throw const SmartRuleFormatException(
        'targetPackages',
        'Not a list of strings.',
      );
    }
    if (days is! List || days.any((Object? d) => d is! int)) {
      throw const SmartRuleFormatException('days', 'Not a list of ints.');
    }
    final SmartRule rule = SmartRule(
      id: id,
      name: name,
      targetPackages: targets.cast<String>(),
      days: days.cast<int>(),
      time: SmartRuleTime.fromJson(raw['time']),
      enabled: enabled,
      action: action,
      profileId: profile as String?,
    );
    if (rule.name != name) {
      throw const SmartRuleFormatException('name', 'Not trimmed.');
    }
    if (!_sameList(rule.targetPackages, targets)) {
      throw const SmartRuleFormatException(
        'targetPackages',
        'Not sorted and unique.',
      );
    }
    if (!_sameList(rule.days, days)) {
      throw const SmartRuleFormatException('days', 'Not sorted and unique.');
    }
    return rule;
  }

  @override
  bool operator ==(Object other) =>
      other is SmartRule &&
      other.id == id &&
      other.name == name &&
      other.enabled == enabled &&
      _sameList(other.targetPackages, targetPackages) &&
      _sameList(other.days, days) &&
      other.time == time &&
      other.action == action &&
      other.profileId == profileId;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        enabled,
        Object.hashAll(targetPackages),
        Object.hashAll(days),
        time,
        action,
        profileId,
      );

  @override
  String toString() => 'SmartRule($id, "$name", '
      '${enabled ? 'enabled' : 'disabled'}, targets=$targetPackages, '
      'days=$days, time=$time, action=${action.storageId}'
      '${isProfileRule ? ', profile=$profileId' : ''})';

  // -- validation ------------------------------------------------------------

  static String _validId(String id) {
    if (id.isEmpty || id.length > maxIdLength || !_idPattern.hasMatch(id)) {
      throw SmartRuleFormatException(
        'id',
        'Use 1–$maxIdLength letters, digits, "_" or "-", starting with a '
            'letter or digit.',
      );
    }
    return id;
  }

  static String _validName(String name) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const SmartRuleFormatException('name', 'Name cannot be blank.');
    }
    if (trimmed.runes.length > maxNameLength) {
      throw const SmartRuleFormatException(
        'name',
        'Name is longer than $maxNameLength characters.',
      );
    }
    if (trimmed.runes.any((int r) => r < 0x20 || r == 0x7F)) {
      throw const SmartRuleFormatException(
        'name',
        'Name contains control characters.',
      );
    }
    return trimmed;
  }

  static List<String> _validTargets(Iterable<String> targets) {
    final Set<String> unique = <String>{};
    for (final String t in targets) {
      if (!isValidPackageName(t)) {
        throw SmartRuleFormatException(
          'targetPackages',
          'Not a valid package name: "$t".',
        );
      }
      unique.add(t);
    }
    if (unique.isEmpty) {
      throw const SmartRuleFormatException(
        'targetPackages',
        'Select at least one app. An empty selection never means all apps.',
      );
    }
    return List<String>.unmodifiable(unique.toList()..sort());
  }

  static List<int> _validDays(Iterable<int> days) {
    final Set<int> unique = <int>{};
    for (final int d in days) {
      if (!SmartRuleDays.isValid(d)) {
        throw SmartRuleFormatException(
          'days',
          'Days are 1 (Monday) to 7 (Sunday), got $d.',
        );
      }
      unique.add(d);
    }
    if (unique.isEmpty) {
      throw const SmartRuleFormatException(
        'days',
        'Select at least one day.',
      );
    }
    return List<int>.unmodifiable(unique.toList()..sort());
  }
}

void _exactKeys(Map<dynamic, dynamic> raw, Set<String> keys, String field) {
  if (raw.length != keys.length || !raw.keys.every(keys.contains)) {
    throw SmartRuleFormatException(
      field,
      'Expected exactly the fields $keys, got ${raw.keys.toList()}.',
    );
  }
}

bool _sameList(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
