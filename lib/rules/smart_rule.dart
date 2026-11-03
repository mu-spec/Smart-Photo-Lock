/// Phase 10 / M1 (PRD 10A, 10C, 10D, 10E): the Smart Rule domain model.
///
/// Pure Dart, immutable and validated at construction. A [SmartRule] is
/// configuration only: it says WHICH apps, on WHICH days and at WHAT local
/// time a rule applies. It carries no action yet (security-level actions are
/// Phase 10 / M2) and nothing in the app acts on it. Evaluation lives in
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

/// One Smart Rule (PRD 10A): stable id, name, enabled state, exact target
/// packages (10E), selected days (10D) and a local time condition (10C).
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
  factory SmartRule({
    required String id,
    required String name,
    required Iterable<String> targetPackages,
    required Iterable<int> days,
    required SmartRuleTime time,
    bool enabled = true,
  }) {
    return SmartRule._(
      id: _validId(id),
      name: _validName(name),
      enabled: enabled,
      targetPackages: _validTargets(targetPackages),
      days: _validDays(days),
      time: time,
    );
  }

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

  /// True when [packageName] is one of [targetPackages] (exact match).
  bool targets(String packageName) => targetPackages.contains(packageName);

  /// True for a well-formed Android package name (see [_packagePattern]).
  static bool isValidPackageName(Object? value) =>
      value is String &&
      value.length <= maxPackageNameLength &&
      _packagePattern.hasMatch(value);

  /// A copy with the given fields replaced, validated again. The [id] never
  /// changes.
  SmartRule copyWith({
    String? name,
    Iterable<String>? targetPackages,
    Iterable<int>? days,
    SmartRuleTime? time,
    bool? enabled,
  }) {
    return SmartRule(
      id: id,
      name: name ?? this.name,
      targetPackages: targetPackages ?? this.targetPackages,
      days: days ?? this.days,
      time: time ?? this.time,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'enabled': enabled,
        'targets': List<String>.of(targetPackages),
        'days': List<int>.of(days),
        'time': time.toJson(),
      };

  static const Set<String> _jsonKeys = <String>{
    'id',
    'name',
    'enabled',
    'targets',
    'days',
    'time',
  };

  /// Strict decode of persisted [toJson] output. Rejects missing, unknown or
  /// mistyped fields and anything not already canonical (untrimmed name,
  /// unsorted or duplicated packages or days). Throws
  /// [SmartRuleFormatException]; never returns a repaired rule.
  static SmartRule fromJson(Object? raw) {
    if (raw is! Map) {
      throw const SmartRuleFormatException('rule', 'Not an object.');
    }
    _exactKeys(raw, _jsonKeys, 'rule');
    final Object? id = raw['id'];
    final Object? name = raw['name'];
    final Object? enabled = raw['enabled'];
    final Object? targets = raw['targets'];
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
      other.time == time;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        enabled,
        Object.hashAll(targetPackages),
        Object.hashAll(days),
        time,
      );

  @override
  String toString() => 'SmartRule($id, "$name", '
      '${enabled ? 'enabled' : 'disabled'}, targets=$targetPackages, '
      'days=$days, time=$time)';

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
