import '../../../data/models/app_security_level.dart';
import '../../../data/models/protected_app.dart';
import '../../../protection/health/protection_health_engine.dart';

/// Phase 9 / M1 (PRD 9B, 9C) — the Security Center's protected-app summary.
///
/// Pure and read-only. It is computed from the records returned by
/// `ProtectedAppsRepository.getProtectedApps()` (the same list the lock
/// engine's matcher reads) and never writes, protects, unprotects, changes a
/// level, authorizes or touches a challenge.
///
/// Counting rules:
///  * Only saved protected-app records are counted. Installed apps that are
///    not protected are never part of the input.
///  * One app per package name. If a list ever contained the same package
///    twice (the database's primary key prevents it), the FIRST record
///    counts, which is the record the matcher uses for enforcement.
///  * Blank package names are ignored (the matcher never protects them).
///  * Levels are the SAVED levels. [heldStricter] separately counts apps
///    whose saved level is lower than the level native last confirmed it
///    enforces (a downgrade not confirmed yet, Phase 8 / M2).
class ProtectedAppsSummary {
  const ProtectedAppsSummary._({
    required this.standard,
    required this.sensitive,
    required this.critical,
    required this.criticalLabels,
    required this.heldStricter,
  });

  /// Builds the summary from repository records. [nativeLevelFor] is the
  /// read-only `ProtectionBootstrap.nativeLevelFor` (null when unknown).
  factory ProtectedAppsSummary.fromApps(
    Iterable<ProtectedApp> apps, {
    AppSecurityLevel? Function(String packageName)? nativeLevelFor,
  }) {
    final Set<String> seen = <String>{};
    int standard = 0;
    int sensitive = 0;
    int critical = 0;
    int held = 0;
    final List<String> criticalLabels = <String>[];
    for (final ProtectedApp app in apps) {
      final String pkg = app.packageName.trim();
      if (pkg.isEmpty || !seen.add(pkg)) continue;
      switch (app.securityLevel) {
        case AppSecurityLevel.standard:
          standard++;
        case AppSecurityLevel.sensitive:
          sensitive++;
        case AppSecurityLevel.critical:
          critical++;
          criticalLabels.add(app.label.trim().isEmpty ? pkg : app.label);
      }
      final AppSecurityLevel? native = nativeLevelFor?.call(pkg);
      if (native != null && native.isStricterThan(app.securityLevel)) held++;
    }
    return ProtectedAppsSummary._(
      standard: standard,
      sensitive: sensitive,
      critical: critical,
      criticalLabels: List<String>.unmodifiable(criticalLabels),
      heldStricter: held,
    );
  }

  final int standard;
  final int sensitive;
  final int critical;

  /// Display names of the Critical apps, in repository order.
  final List<String> criticalLabels;

  /// Apps still enforced at a stricter level than saved (not confirmed).
  final int heldStricter;

  int get total => standard + sensitive + critical;
  bool get isEmpty => total == 0;

  int countOf(AppSecurityLevel level) => switch (level) {
        AppSecurityLevel.standard => standard,
        AppSecurityLevel.sensitive => sensitive,
        AppSecurityLevel.critical => critical,
      };
}

/// How the Critical summary relates the saved assignment to the CURRENT
/// Protection Health. This is a mapping of the Phase 7 report's overall
/// state; it does not classify health a second time and it does not measure
/// per-app enforcement (no such signal exists).
enum CriticalProtectionStatus {
  /// No app is assigned Critical.
  none,

  /// Critical apps exist and the last health check is SECURE (fresh).
  checksPassed,

  /// Critical apps exist; health is ATTENTION REQUIRED (includes stale).
  attention,

  /// Critical apps exist; health is PROTECTION OFFLINE.
  offline,

  /// Critical apps exist; no usable health report (checking, failed, never
  /// checked or no health source). Never treated as working.
  unconfirmed;

  /// [report] must already have the staleness rule applied (the controller
  /// does this on every read). A null report is never SECURE.
  static CriticalProtectionStatus of(
    int criticalCount,
    ProtectionHealthReport? report,
  ) {
    if (criticalCount <= 0) return CriticalProtectionStatus.none;
    if (report == null) return CriticalProtectionStatus.unconfirmed;
    return switch (report.state) {
      ProtectionHealthState.secure => CriticalProtectionStatus.checksPassed,
      ProtectionHealthState.attentionRequired =>
        CriticalProtectionStatus.attention,
      ProtectionHealthState.protectionOffline =>
        CriticalProtectionStatus.offline,
    };
  }
}
