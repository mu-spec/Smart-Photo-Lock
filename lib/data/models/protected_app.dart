import 'app_security_level.dart';

/// An app the user chose to protect.
///
/// Persisted in the local database (`protected_apps` table). Pure Dart —
/// no Flutter imports — so it flows through repositories without UI coupling.
///
/// Phase 8 / M1: each record carries its [securityLevel]. The level lives
/// on the record itself (one row per package), so removing protection
/// retires the level with the row and there is no second level store.
class ProtectedApp {
  const ProtectedApp({
    required this.packageName,
    required this.label,
    required this.addedAt,
    this.sortOrder = 0,
    this.securityLevel = AppSecurityLevel.defaultLevel,
  });

  /// Android package name, e.g. `com.whatsapp`. Unique per protected app.
  final String packageName;

  /// Display label captured at the time the app was protected.
  final String label;

  /// When the user protected the app.
  final DateTime addedAt;

  /// Manual/user ordering position (lower = earlier in the list).
  final int sortOrder;

  /// Per-app security level (Phase 8 / M1: classification only; it does
  /// not change locking until Phase 8 / M2). New records: Standard.
  final AppSecurityLevel securityLevel;

  ProtectedApp copyWith({
    String? label,
    DateTime? addedAt,
    int? sortOrder,
    AppSecurityLevel? securityLevel,
  }) {
    return ProtectedApp(
      packageName: packageName,
      label: label ?? this.label,
      addedAt: addedAt ?? this.addedAt,
      sortOrder: sortOrder ?? this.sortOrder,
      securityLevel: securityLevel ?? this.securityLevel,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'packageName': packageName,
        'label': label,
        'addedAt': addedAt.toIso8601String(),
        'sortOrder': sortOrder,
        'securityLevel': securityLevel.storageId,
      };

  /// Legacy JSON without `securityLevel` reads as Standard; an unreadable
  /// value reads as Critical ([AppSecurityLevel.fromStorage]).
  factory ProtectedApp.fromJson(Map<String, dynamic> json) => ProtectedApp(
        packageName: json['packageName'] as String,
        label: json['label'] as String,
        addedAt: DateTime.parse(json['addedAt'] as String),
        sortOrder: json['sortOrder'] as int? ?? 0,
        securityLevel: AppSecurityLevel.fromStorage(json['securityLevel']),
      );

  @override
  bool operator ==(Object other) =>
      other is ProtectedApp && other.packageName == packageName;

  @override
  int get hashCode => packageName.hashCode;

  @override
  String toString() =>
      'ProtectedApp($packageName, "$label", ${securityLevel.storageId})';
}
