/// An app the user chose to protect.
///
/// Persisted in the local database (`protected_apps` table). Pure Dart —
/// no Flutter imports — so it flows through repositories without UI coupling.
class ProtectedApp {
  const ProtectedApp({
    required this.packageName,
    required this.label,
    required this.addedAt,
    this.sortOrder = 0,
  });

  /// Android package name, e.g. `com.whatsapp`. Unique per protected app.
  final String packageName;

  /// Display label captured at the time the app was protected.
  final String label;

  /// When the user protected the app.
  final DateTime addedAt;

  /// Manual/user ordering position (lower = earlier in the list).
  final int sortOrder;

  ProtectedApp copyWith({
    String? label,
    DateTime? addedAt,
    int? sortOrder,
  }) {
    return ProtectedApp(
      packageName: packageName,
      label: label ?? this.label,
      addedAt: addedAt ?? this.addedAt,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'packageName': packageName,
        'label': label,
        'addedAt': addedAt.toIso8601String(),
        'sortOrder': sortOrder,
      };

  factory ProtectedApp.fromJson(Map<String, dynamic> json) => ProtectedApp(
        packageName: json['packageName'] as String,
        label: json['label'] as String,
        addedAt: DateTime.parse(json['addedAt'] as String),
        sortOrder: json['sortOrder'] as int? ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is ProtectedApp && other.packageName == packageName;

  @override
  int get hashCode => packageName.hashCode;

  @override
  String toString() => 'ProtectedApp($packageName, "$label")';
}
