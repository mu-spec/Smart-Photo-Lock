/// A named set of lock settings the user can switch between
/// (e.g. "Work mode", "Kids mode", "Night focus").
///
/// Profiles group locked packages; rules are evaluated on top of the active
/// profile's package set. Pure Dart model — no UI or I/O.
class LockProfile {
  const LockProfile({
    required this.id,
    required this.name,
    this.description,
    this.isActive = false,
    this.lockedPackages = const <String>[],
  });

  /// Stable identifier.
  final String id;

  /// Display name shown in the profile picker.
  final String name;

  final String? description;

  /// Exactly one profile is active at a time.
  final bool isActive;

  /// Package names locked while this profile is active.
  final List<String> lockedPackages;

  LockProfile copyWith({
    String? name,
    String? description,
    bool? isActive,
    List<String>? lockedPackages,
  }) {
    return LockProfile(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      isActive: isActive ?? this.isActive,
      lockedPackages: lockedPackages ?? this.lockedPackages,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'description': description,
        'isActive': isActive,
        'lockedPackages': lockedPackages,
      };

  factory LockProfile.fromJson(Map<String, dynamic> json) => LockProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description'] as String?,
        isActive: json['isActive'] as bool? ?? false,
        lockedPackages: (json['lockedPackages'] as List<dynamic>? ??
                const <dynamic>[])
            .cast<String>(),
      );

  @override
  bool operator ==(Object other) => other is LockProfile && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'LockProfile($id, "$name"${isActive ? ', active' : ''})';
}
