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
///
/// Phase 11 / M3: an "Apply profile" Smart Rule activates a profile as a
/// TEMPORARY ADDITIONAL overlay while its schedule matches; the manually
/// selected profile is never changed. [activationRules] compiles it into the
/// same synthetic raising rules, carrying the rule's days and time instead
/// of all-day / every day. [combinedRules] is the ONE policy:
///
///   effective(app, t) = strictest(saved baseline, manual overlay,
///                                 matching direct rules at t,
///                                 matching activated overlays at t)
///
/// Because the compiled snapshot is the same at every instant, a window
/// starting or ending is never a snapshot change: native evaluates the time
/// at each foreground decision, so expiry needs no relaxation flag and is
/// never held. Only an edit, disable or delete changes the snapshot (and a
/// weaker one needs the CR-2 proof + bound protocol).
library;

import '../data/models/app_security_level.dart';
import '../rules/smart_rule.dart';
import '../rules/smart_rule_evaluator.dart';
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

  /// Phase 11 / M3: id prefix of synthetic activation rules (never stored).
  static const String activationRulePrefix = 'act-';

  /// Phase 11 / M3: the enabled "Apply profile" rules of [rules] compiled
  /// into raise-only synthetic rules with each rule's own days and time.
  /// A rule whose profile is not in [profiles] (inconsistent storage) fails
  /// CLOSED: every protected app is Critical during its window.
  /// Disabled rules and level rules compile to nothing.
  static List<SmartRule> activationRules(
    Iterable<SmartRule> rules,
    SecurityProfileSet profiles,
    Set<String> protectedPackages,
  ) {
    final List<SmartRule> out = <SmartRule>[];
    int index = 0;
    for (final SmartRule rule in rules) {
      if (!rule.enabled || !rule.isProfileRule) continue;
      out.addAll(activationRulesFor(
        rule,
        profiles,
        protectedPackages,
        index: index++,
      ));
    }
    return out;
  }

  /// The synthetic rules of ONE profile rule (empty unless it is an
  /// enabled "Apply profile" rule). [index] only keeps synthetic ids
  /// unique; ids never reach native.
  static List<SmartRule> activationRulesFor(
    SmartRule rule,
    SecurityProfileSet profiles,
    Set<String> protectedPackages, {
    int index = 0,
  }) {
    if (!rule.enabled || !rule.isProfileRule) return const <SmartRule>[];
    final SecurityProfile? profile = profiles.byId(rule.profileId!);
    final List<SmartRule> overlay = profile == null
        ? <SmartRule>[
            if (protectedPackages.isNotEmpty)
              _rule(
                null,
                'missing',
                protectedPackages,
                AppSecurityLevel.critical,
              ),
          ]
        : overlayRules(profile, protectedPackages);
    return <SmartRule>[
      for (final SmartRule o in overlay)
        SmartRule(
          id: '$activationRulePrefix$index-${o.id.split('-').last}',
          name: rule.name,
          targetPackages: o.targetPackages,
          days: rule.days,
          time: rule.time,
          action: o.action,
        ),
    ];
  }

  /// Whether [rule] references a profile that [profiles] does not contain.
  static bool referencesMissingProfile(
    SmartRule rule,
    SecurityProfileSet profiles,
  ) =>
      rule.isProfileRule && profiles.byId(rule.profileId!) == null;

  /// Phase 11 / M3: the ONE combined policy as raising rules: the saved
  /// rules (level rules evaluate directly; profile rules never match an app
  /// themselves) + the manual profile's overlay + the activated overlays.
  static List<SmartRule> combinedRules(
    Iterable<SmartRule> rules,
    SecurityProfileSet profiles,
    Set<String> protectedPackages,
  ) =>
      <SmartRule>[
        ...rules,
        ...overlayRules(profiles.active, protectedPackages),
        ...activationRules(rules, profiles, protectedPackages),
      ];

  /// Phase 11 / M3: the ONE native transport of [combinedRules]. Without
  /// profile rules it equals [nativeTransport] for the active profile.
  static List<Map<String, Object?>> combinedTransport(
    Iterable<SmartRule> rules,
    SecurityProfileSet profiles,
    Set<String> protectedPackages,
  ) =>
      SmartRulePolicy.nativeTransport(
        combinedRules(rules, profiles, protectedPackages),
      );

  /// Phase 11 / M3: packages whose combined strictness is LOWER after a
  /// change from ([rulesBefore], [profilesBefore]) to ([rulesAfter],
  /// [profilesAfter]) at some weekday and minute. Non-empty → CR-2 proof.
  static Set<String> combinedRelaxedPackages({
    required List<SmartRule> rulesBefore,
    required List<SmartRule> rulesAfter,
    required SecurityProfileSet profilesBefore,
    required SecurityProfileSet profilesAfter,
    required Set<String> protectedPackages,
  }) =>
      SmartRulePolicy.relaxedPackages(
        combinedRules(rulesBefore, profilesBefore, protectedPackages),
        combinedRules(rulesAfter, profilesAfter, protectedPackages),
      );

  /// Phase 11 / M3: packages whose combined level rises at [localDateTime]
  /// (their open sessions are revoked).
  static Set<String> combinedRaisedAt({
    required List<SmartRule> rulesBefore,
    required List<SmartRule> rulesAfter,
    required SecurityProfileSet profilesBefore,
    required SecurityProfileSet profilesAfter,
    required Set<String> protectedPackages,
    required DateTime localDateTime,
  }) =>
      SmartRulePolicy.raisedAt(
        combinedRules(rulesBefore, profilesBefore, protectedPackages),
        combinedRules(rulesAfter, profilesAfter, protectedPackages),
        localDateTime,
      );

  /// Phase 11 / M3: the strictest level the matching activated overlays
  /// require for [packageName] at [localDateTime] (null = none).
  static AppSecurityLevel? activationLevelFor(
    Iterable<SmartRule> rules,
    SecurityProfileSet profiles,
    String packageName,
    DateTime localDateTime,
    Set<String> protectedPackages,
  ) =>
      SmartRulePolicy.ruleLevelFor(
        activationRules(rules, profiles, protectedPackages),
        packageName,
        localDateTime,
      );

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
    SecurityProfile? profile,
    String part,
    Iterable<String> targets,
    AppSecurityLevel level,
  ) =>
      SmartRule(
        id: '$overlayRulePrefix${profile?.id ?? 'missing'}-$part',
        name: '${profile?.name ?? 'Missing'} profile',
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
  SecurityProfileSet _set = SecurityProfileSet.defaults();
  bool _loaded;
  bool _readFailed = false;

  /// The active profile of the last successful read (Normal before one).
  SecurityProfile get active => _active;

  /// Phase 11 / M3: the whole profile set of the last successful read
  /// (defaults before one); "Apply profile" rules resolve against it.
  SecurityProfileSet get set => _set;

  bool get loaded => _loaded;

  /// Whether the latest read succeeded.
  bool get current => _loaded && !_readFailed;

  void update(SecurityProfileSet set) {
    _active = set.active;
    _set = set;
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

/// Phase 11 / M3: which layer decides an app's effective level (attribution
/// only; the level is always the strictest layer). Tie-break among equal
/// levels, in this order: saved level, manual profile, direct rule,
/// scheduled profile.
enum ProtectionLayer { savedLevel, manualProfile, directRule, scheduledProfile }

/// Phase 11 / M3: the per-layer explanation of one protected app's level at
/// one instant. CALCULATED from the saved documents; never a native
/// confirmation.
final class ProtectionLayerDiagnosis {
  const ProtectionLayerDiagnosis({
    required this.packageName,
    required this.savedLevel,
    required this.manualProfileId,
    required this.manualLevel,
    required this.directLevel,
    required this.directRuleId,
    required this.scheduledLevel,
    required this.scheduledRuleId,
    required this.scheduledProfileId,
    required this.effectiveLevel,
    required this.decidedBy,
  });

  final String packageName;

  /// Null = the app is not protected (no layer applies).
  final AppSecurityLevel? savedLevel;
  final String manualProfileId;
  final AppSecurityLevel? manualLevel;
  final AppSecurityLevel? directLevel;

  /// The deciding direct rule (first sorted id among the strongest).
  final String? directRuleId;
  final AppSecurityLevel? scheduledLevel;

  /// The deciding "Apply profile" rule (first sorted id among the
  /// strongest) and its profile (which may be missing from the set).
  final String? scheduledRuleId;
  final String? scheduledProfileId;
  final AppSecurityLevel? effectiveLevel;
  final ProtectionLayer? decidedBy;

  @override
  String toString() => 'ProtectionLayerDiagnosis($packageName, '
      'saved=${savedLevel?.storageId}, manual=${manualLevel?.storageId}, '
      'direct=${directLevel?.storageId}($directRuleId), '
      'scheduled=${scheduledLevel?.storageId}($scheduledRuleId/'
      '$scheduledProfileId), effective=${effectiveLevel?.storageId}, '
      '${decidedBy?.name})';
}

/// Phase 11 / M3: builds [ProtectionLayerDiagnosis] (pure, deterministic).
abstract final class ProtectionLayerDiagnostics {
  static ProtectionLayerDiagnosis diagnose({
    required List<SmartRule> rules,
    required SecurityProfileSet profiles,
    required String packageName,
    required AppSecurityLevel? savedLevel,
    required Set<String> protectedPackages,
    required DateTime at,
  }) {
    final SecurityProfile manual = profiles.active;
    if (savedLevel == null) {
      return ProtectionLayerDiagnosis(
        packageName: packageName,
        savedLevel: null,
        manualProfileId: manual.id,
        manualLevel: null,
        directLevel: null,
        directRuleId: null,
        scheduledLevel: null,
        scheduledRuleId: null,
        scheduledProfileId: null,
        effectiveLevel: null,
        decidedBy: null,
      );
    }
    final AppSecurityLevel? manualLevel =
        SecurityProfilePolicy.transportLevelFor(
            manual, packageName, protectedPackages);
    final directResolution =
        SmartRulePolicy.resolutionFor(rules, packageName, at);
    final AppSecurityLevel? directLevel = directResolution.ruleLevel;
    AppSecurityLevel? scheduledLevel;
    String? scheduledRuleId;
    final List<SmartRule> sorted = <SmartRule>[
      for (final SmartRule r in rules)
        if (r.enabled && r.isProfileRule) r,
    ]..sort((SmartRule a, SmartRule b) => a.id.compareTo(b.id));
    for (final SmartRule r in sorted) {
      final AppSecurityLevel? level = SmartRulePolicy.ruleLevelFor(
        SecurityProfilePolicy.activationRulesFor(
          r,
          profiles,
          protectedPackages,
        ),
        packageName,
        at,
      );
      if (level == null) continue;
      if (scheduledLevel == null || level.isStricterThan(scheduledLevel)) {
        scheduledLevel = level;
        scheduledRuleId = r.id;
      }
    }
    final String? scheduledProfileId = scheduledRuleId == null
        ? null
        : sorted.firstWhere((SmartRule r) => r.id == scheduledRuleId).profileId;
    AppSecurityLevel effective = savedLevel;
    ProtectionLayer decidedBy = ProtectionLayer.savedLevel;
    void consider(AppSecurityLevel? level, ProtectionLayer layer) {
      if (level != null && level.isStricterThan(effective)) {
        effective = level;
        decidedBy = layer;
      }
    }

    consider(manualLevel, ProtectionLayer.manualProfile);
    consider(directLevel, ProtectionLayer.directRule);
    consider(scheduledLevel, ProtectionLayer.scheduledProfile);
    return ProtectionLayerDiagnosis(
      packageName: packageName,
      savedLevel: savedLevel,
      manualProfileId: manual.id,
      manualLevel: manualLevel,
      directLevel: directLevel,
      directRuleId: directResolution.decidingRuleId,
      scheduledLevel: scheduledLevel,
      scheduledRuleId: scheduledRuleId,
      scheduledProfileId: scheduledProfileId,
      effectiveLevel: effective,
      decidedBy: decidedBy,
    );
  }
}

/// Phase 11 / M3: whether the enabled "Apply profile" [rule] matches at
/// [localDateTime] (its days and time only; apps come from the profile).
bool profileRuleMatchesAt(SmartRule rule, DateTime localDateTime) {
  if (!rule.enabled || !rule.isProfileRule || localDateTime.isUtc) {
    return false;
  }
  final SmartRule probe = SmartRule(
    id: rule.id,
    name: rule.name,
    targetPackages: const <String>['probe.time.only'],
    days: rule.days,
    time: rule.time,
  );
  return SmartRuleEvaluator.matchesAt(
    probe,
    'probe.time.only',
    localDateTime.weekday,
    localDateTime.hour * 60 + localDateTime.minute,
  );
}
