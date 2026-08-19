/// The kinds of lock rules a user can attach to apps or profiles.
enum LockRuleType {
  /// App is always locked.
  always,

  /// App is locked only inside a daily time window (may wrap midnight).
  timeWindow,

  /// App locks once it has been launched [LockRule.maxLaunchesPerDay]
  /// times in a day (focus/limit feature).
  launchLimit,
}

/// A single, serializable lock rule.
///
/// Pure Dart — evaluation is done by [RuleEngine], enforcement by the
/// protection layer. Rules never perform I/O.
class LockRule {
  const LockRule({
    required this.id,
    required this.type,
    this.packageName,
    this.startMinuteOfDay,
    this.endMinuteOfDay,
    this.maxLaunchesPerDay,
    this.enabled = true,
  });

  /// Stable identifier (used for persistence and UI keys).
  final String id;

  final LockRuleType type;

  /// Package this rule applies to; null means "every app".
  final String? packageName;

  /// [LockRuleType.timeWindow] only — window start, minutes since midnight.
  final int? startMinuteOfDay;

  /// [LockRuleType.timeWindow] only — window end, minutes since midnight.
  final int? endMinuteOfDay;

  /// [LockRuleType.launchLimit] only — daily launch cap.
  final int? maxLaunchesPerDay;

  /// Disabled rules are kept but ignored during evaluation.
  final bool enabled;

  /// True when this rule covers [package].
  bool appliesTo(String package) =>
      packageName == null || packageName == package;

  LockRule copyWith({
    LockRuleType? type,
    String? packageName,
    int? startMinuteOfDay,
    int? endMinuteOfDay,
    int? maxLaunchesPerDay,
    bool? enabled,
  }) {
    return LockRule(
      id: id,
      type: type ?? this.type,
      packageName: packageName ?? this.packageName,
      startMinuteOfDay: startMinuteOfDay ?? this.startMinuteOfDay,
      endMinuteOfDay: endMinuteOfDay ?? this.endMinuteOfDay,
      maxLaunchesPerDay: maxLaunchesPerDay ?? this.maxLaunchesPerDay,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'type': type.name,
        'packageName': packageName,
        'startMinuteOfDay': startMinuteOfDay,
        'endMinuteOfDay': endMinuteOfDay,
        'maxLaunchesPerDay': maxLaunchesPerDay,
        'enabled': enabled,
      };

  factory LockRule.fromJson(Map<String, dynamic> json) => LockRule(
        id: json['id'] as String,
        type: LockRuleType.values.byName(json['type'] as String),
        packageName: json['packageName'] as String?,
        startMinuteOfDay: json['startMinuteOfDay'] as int?,
        endMinuteOfDay: json['endMinuteOfDay'] as int?,
        maxLaunchesPerDay: json['maxLaunchesPerDay'] as int?,
        enabled: json['enabled'] as bool? ?? true,
      );

  @override
  bool operator ==(Object other) => other is LockRule && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'LockRule($id, ${type.name}, '
      'package=${packageName ?? '<all>'}${enabled ? '' : ', disabled'})';
}
