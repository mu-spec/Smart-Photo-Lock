/// Immutable description of an installed application.
///
/// Pure Dart — no Flutter imports — so it can flow freely between the
/// repositories, the rule engine, and (later) the local database without
/// any UI coupling.
class AppEntry {
  const AppEntry({
    required this.packageName,
    required this.label,
    this.isSystemApp = false,
    this.versionName,
  });

  /// Android package name, e.g. `com.whatsapp`. Unique per app.
  final String packageName;

  /// User-facing display name, e.g. `WhatsApp`.
  final String label;

  /// True for pre-installed/system apps (launcher, settings, ...).
  final bool isSystemApp;

  /// Optional version string as reported by the system.
  final String? versionName;

  AppEntry copyWith({
    String? packageName,
    String? label,
    bool? isSystemApp,
    String? versionName,
  }) {
    return AppEntry(
      packageName: packageName ?? this.packageName,
      label: label ?? this.label,
      isSystemApp: isSystemApp ?? this.isSystemApp,
      versionName: versionName ?? this.versionName,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'packageName': packageName,
        'label': label,
        'isSystemApp': isSystemApp,
        'versionName': versionName,
      };

  factory AppEntry.fromJson(Map<String, dynamic> json) => AppEntry(
        packageName: json['packageName'] as String,
        label: json['label'] as String,
        isSystemApp: json['isSystemApp'] as bool? ?? false,
        versionName: json['versionName'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is AppEntry && other.packageName == packageName;

  @override
  int get hashCode => packageName.hashCode;

  @override
  String toString() => 'AppEntry($packageName, "$label")';
}
