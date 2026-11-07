/// Phase 11 / M1: what the active Security Profile does to enforcement.
///
/// ONE engine: a raise-only profile overlay is compiled into synthetic,
/// enabled, all-day, every-day raising [SmartRule]s ([overlayRules]) and
/// evaluated by the existing Phase 10 conflict policy. Natively the overlay
/// travels inside the existing Smart Rule transport ([nativeTransport]), so
/// native parsing, durable persistence, acknowledgement, the HELD union and
/// the failed-write "never weaker" restore all apply unchanged.
///
///   effective(app, t) = strictest(saved baseline,
///                                 strictest matching Smart Rule at t,
///                                 active-profile overlay)
///
/// The synthetic rules are never stored in the Smart Rules document and
/// never shown as rules. Pure Dart, no I/O, no clock read.
library;

import '../data/models/app_security_level.dart';
import '../rules/smart_rule.dart';
import '../rules/smart_rule_policy.dart';
import 'security_profile.dart';

abstract final class SecurityProfilePolicy {
  static const List<int> _everyDay = <int>[1, 2, 3, 4, 5, 6, 7];

  /// Id prefix of synthetic overlay rules (diagnostic only; never stored).
  static const String overlayRulePrefix = 'profile-';

  /// The extra level [profile] requires for a PROTECTED [packageName], or
  /// null. (Overlay entries have no effect on unprotected apps.)
  static AppSecurityLevel? overlayLevelFor(
    SecurityProfile profile,
    String packageName,
  ) =>
      _stricter(profile.allProtectedLevel, profile.appLevels[packageName]);

  /// The level the COMPILED overlay ([overlayRules]) gives [packageName],
  /// exactly as the native engine evaluates the transport: "all protected
  /// apps" only when [packageName] is in [protectedPackages] (the set the
  /// overlay was compiled for); per-app entries as compiled. Native ignores
  /// unprotected packages entirely, so for those this only mirrors the
  /// engine level and never protects anything.
  static AppSecurityLevel? transportLevelFor(
    SecurityProfile profile,
    String packageName,
    Set<String> protectedPackages,
  ) =>
      _stricter(
        protectedPackages.contains(packageName)
            ? profile.allProtectedLevel
            : null,
        profile.appLevels[packageName],
      );

  /// [profile] as raise-only all-day rules. "All protected apps" targets
  /// [protectedPackages] (no entry when that set is empty: an empty target
  /// set never means "all apps"). Per-app entries are grouped by level.
  static List<SmartRule> overlayRules(
    SecurityProfile profile,
    Set<String> protectedPackages,
  ) {
    final List<SmartRule> out = <SmartRule>[];
    final AppSecurityLevel? all = profile.allProtectedLevel;
    if (all != null && protectedPackages.isNotEmpty) {
      out.add(_rule(profile, 'all', protectedPackages, all));
    }
    for (final AppSecurityLevel level in const <AppSecurityLevel>[
      AppSecurityLevel.sensitive,
      AppSecurityLevel.critical,
    ]) {
      final List<String> targets = <String>[
        for (final MapEntry<String, AppSecurityLevel> e
            in profile.appLevels.entries)
          if (e.value == level) e.key,
      ];
      if (targets.isNotEmpty) {
        out.add(_rule(profile, level.storageId, targets, level));
      }
    }
    return out;
  }

  /// The ONE native `smartRules` transport: the saved rules plus the active
  /// profile's overlay, in the canonical Phase 10 format. With an empty
  /// overlay (Normal) it equals `SmartRulePolicy.nativeTransport(rules)`.
  static List<Map<String, Object?>> nativeTransport(
    Iterable<SmartRule> rules,
    SecurityProfile profile,
    Set<String> protectedPackages,
  ) =>
      SmartRulePolicy.nativeTransport(<SmartRule>[
        ...rules,
        ...overlayRules(profile, protectedPackages),
      ]);

  /// Rules + overlay extra level for a protected [packageName] at
  /// [localDateTime] (null = none).
  static AppSecurityLevel? extraLevelFor(
    Iterable<SmartRule> rules,
    SecurityProfile profile,
    String packageName,
    DateTime localDateTime,
  ) =>
      _stricter(
        SmartRulePolicy.ruleLevelFor(rules, packageName, localDateTime),
        overlayLevelFor(profile, packageName),
      );

  /// D6: packages whose combined (rules + profile) strictness is LOWER
  /// after switching or editing from [before] to [after] at some weekday
  /// and minute. Non-empty → PIN/Pattern authorization (CR-2 proof) and
  /// `authorizedRuleRelaxation` are required; otherwise native holds the
  /// stricter union. Exact (same week-boundary check as native
  /// `SmartRulePolicy.relaxes` over the combined transport).
  static Set<String> relaxedPackages({
    required Iterable<SmartRule> rules,
    required SecurityProfile before,
    required SecurityProfile after,
    required Set<String> protectedPackages,
  }) =>
      SmartRulePolicy.relaxedPackages(
        <SmartRule>[...rules, ...overlayRules(before, protectedPackages)],
        <SmartRule>[...rules, ...overlayRules(after, protectedPackages)],
      );

  static SmartRule _rule(
    SecurityProfile profile,
    String part,
    Iterable<String> targets,
    AppSecurityLevel level,
  ) =>
      SmartRule(
        id: '$overlayRulePrefix${profile.id}-$part',
        name: '${profile.kind.label} profile',
        targetPackages: targets,
        days: _everyDay,
        time: const SmartRuleTime.allDay(),
        action: level == AppSecurityLevel.critical
            ? SmartRuleAction.critical
            : SmartRuleAction.sensitive,
      );

  static AppSecurityLevel? _stricter(AppSecurityLevel? a, AppSecurityLevel? b) {
    if (a == null) return b;
    if (b == null) return a;
    return b.isStricterThan(a) ? b : a;
  }
}

/// Phase 11 / M1: the Dart engine's copy of the ACTIVE profile, refreshed
/// only from a successful profile read (`ProtectionBootstrap`).
///
/// R-A (extended): [current] is true only while the latest read succeeded.
/// Before the first successful read and after a failed, corrupt or
/// unsupported read, the access controller treats every protected app as
/// Critical. A failed read keeps the last good copy (never "Normal" by
/// default). Native keeps its own persisted copy and is the final gate.
class SecurityProfileEnforcementCache {
  /// A cache that still needs a read ([current] false until [update]).
  SecurityProfileEnforcementCache() : _loaded = false;

  /// For a container with no profile repository wired: Normal, current.
  SecurityProfileEnforcementCache.normalOnly() : _loaded = true;

  SecurityProfile _active = SecurityProfile.preset(SecurityProfileKind.normal);
  bool _loaded;
  bool _readFailed = false;

  /// The active profile of the last successful read (Normal before one).
  SecurityProfile get active => _active;

  bool get loaded => _loaded;

  /// Whether the latest read succeeded.
  bool get current => _loaded && !_readFailed;

  void update(SecurityProfileSet set) {
    _active = set.active;
    _loaded = true;
    _readFailed = false;
  }

  void markReadFailed() {
    _readFailed = true;
  }

  /// The extra level the active profile requires for a protected package.
  AppSecurityLevel? levelFor(String packageName) =>
      SecurityProfilePolicy.overlayLevelFor(_active, packageName);
}
