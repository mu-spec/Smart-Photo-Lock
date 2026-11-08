/// Phase 11 / M1 (PRD 11 M1): typed, validated Security Profile model.
///
/// A profile is a RAISE-ONLY overlay (approved decision D1): while it is
/// active, selected protected apps are enforced at least at the profile's
/// level. A profile can never lower a saved level, unprotect an app, grant
/// grace or authorize access. Overlay levels are Sensitive or Critical only;
/// Standard and the reserved Unlocked are rejected.
///
/// Exactly one profile is active, by construction: [SecurityProfileSet]
/// holds ONE [SecurityProfileSet.activeProfileId] that must name one of its
/// profiles (no per-profile "active" flags).
///
/// Phase 11 / M2: CUSTOM profiles join the five presets. A custom profile
/// has [SecurityProfile.kind] == null, a stable generated id
/// (`custom-` + 12 lowercase hex digits), a validated user name and the
/// same raise-only overlay as Home/Work/Kids. Normal and Guest stay
/// immutable; Home, Work and Kids have editable overlays (fixed names).
///
/// This is NOT the legacy Phase 1 scaffold (`lock_profile.dart`,
/// `profile_manager.dart`), which stays unchanged and disconnected from
/// enforcement. Pure Dart, no I/O.
library;

import 'dart:math';

import '../data/models/app_security_level.dart';
import '../rules/smart_rule.dart';

/// Why a profile or profile set was rejected.
class SecurityProfileFormatException implements Exception {
  const SecurityProfileFormatException(this.field, this.message);

  final String field;
  final String message;

  @override
  String toString() => 'SecurityProfileFormatException($field): $message';
}

/// The five M1 presets. The declaration order is the canonical order.
/// Phase 11 / M1 has no custom profiles (M2).
enum SecurityProfileKind {
  /// Everyday protection: no overlay (saved levels and rules only).
  normal('normal', 'Normal'),

  /// User-configurable; may be less strict than other profiles but never
  /// below saved protection (D1).
  home('home', 'Home'),

  /// An in-app profile for work/personal separation (D2). Not Android's
  /// managed Work Profile; no device-policy API is involved.
  work('work', 'Work'),

  /// Strongly protects private apps: every protected app Critical.
  guest('guest', 'Guest'),

  /// User-selected protected apps only (D3). Settings, Play Store and
  /// payment apps may be suggested in a later UI but are never enrolled
  /// automatically.
  kids('kids', 'Kids');

  const SecurityProfileKind(this.id, this.label);

  /// Stable id (the preset's profile id and its storage value).
  final String id;

  /// Display name.
  final String label;

  static SecurityProfileKind? fromId(Object? raw) {
    for (final SecurityProfileKind k in values) {
      if (k.id == raw) return k;
    }
    return null;
  }
}

/// One validated profile. Construct with [SecurityProfile.new] (validates)
/// or [SecurityProfile.preset] (the default for a kind).
final class SecurityProfile {
  const SecurityProfile._({
    required this.kind,
    required this.allProtectedLevel,
    required this.appLevels,
    String? customId,
    String? customName,
  })  : _customId = customId,
        _customName = customName;

  /// Validates and normalizes. Throws [SecurityProfileFormatException].
  ///
  ///  * [allProtectedLevel]: null, Sensitive or Critical. For [guest] it
  ///    must be Critical; for [normal] null.
  ///  * [appLevels]: at most [maxApps] entries; keys are Android package
  ///    names ([SmartRule.isValidPackageName]), never [ownPackage]; values
  ///    Sensitive or Critical. Empty for [normal] and [guest].
  factory SecurityProfile({
    required SecurityProfileKind kind,
    AppSecurityLevel? allProtectedLevel,
    Map<String, AppSecurityLevel> appLevels =
        const <String, AppSecurityLevel>{},
  }) =>
      _build(kind, null, null, allProtectedLevel, appLevels);

  /// Phase 11 / M2: a user-created profile. [id] must match
  /// [customIdPattern]; [name] is trimmed and validated ([validateName]).
  factory SecurityProfile.custom({
    required String id,
    required String name,
    AppSecurityLevel? allProtectedLevel,
    Map<String, AppSecurityLevel> appLevels =
        const <String, AppSecurityLevel>{},
  }) {
    if (!customIdPattern.hasMatch(id)) {
      throw SecurityProfileFormatException('id', 'Invalid custom id: $id.');
    }
    final String? problem = validateName(name);
    if (problem != null) throw SecurityProfileFormatException('name', problem);
    return _build(null, id, name.trim(), allProtectedLevel, appLevels);
  }

  static SecurityProfile _build(
    SecurityProfileKind? kind,
    String? customId,
    String? customName,
    AppSecurityLevel? allProtectedLevel,
    Map<String, AppSecurityLevel> appLevels,
  ) {
    if (allProtectedLevel != null) _checkRaising(allProtectedLevel, 'all');
    if (appLevels.length > maxApps) {
      throw const SecurityProfileFormatException(
        'apps',
        'At most $maxApps apps per profile.',
      );
    }
    final List<String> packages = appLevels.keys.toList()..sort();
    final Map<String, AppSecurityLevel> normalized =
        <String, AppSecurityLevel>{};
    for (final String pkg in packages) {
      if (!SmartRule.isValidPackageName(pkg)) {
        throw SecurityProfileFormatException('apps', 'Invalid package: $pkg.');
      }
      if (pkg == ownPackage) {
        throw const SecurityProfileFormatException(
          'apps',
          'Smart App Lock itself cannot be part of a profile.',
        );
      }
      final AppSecurityLevel level = appLevels[pkg]!;
      _checkRaising(level, 'apps');
      normalized[pkg] = level;
    }
    switch (kind) {
      case SecurityProfileKind.normal:
        if (allProtectedLevel != null || normalized.isNotEmpty) {
          throw const SecurityProfileFormatException(
            'normal',
            'The Normal profile adds no protection.',
          );
        }
      case SecurityProfileKind.guest:
        if (allProtectedLevel != AppSecurityLevel.critical) {
          throw const SecurityProfileFormatException(
            'guest',
            'The Guest profile keeps every protected app Critical.',
          );
        }
        if (normalized.isNotEmpty) {
          throw const SecurityProfileFormatException(
            'guest',
            'The Guest profile has no per-app entries.',
          );
        }
      case SecurityProfileKind.home:
      case SecurityProfileKind.work:
      case SecurityProfileKind.kids:
      case null:
        break;
    }
    return SecurityProfile._(
      kind: kind,
      allProtectedLevel: allProtectedLevel,
      appLevels: Map<String, AppSecurityLevel>.unmodifiable(normalized),
      customId: customId,
      customName: customName,
    );
  }

  /// The default for [kind]: no overlay, except Guest (every protected app
  /// Critical). Nothing is auto-enrolled (D3).
  factory SecurityProfile.preset(SecurityProfileKind kind) => SecurityProfile(
        kind: kind,
        allProtectedLevel: kind == SecurityProfileKind.guest
            ? AppSecurityLevel.critical
            : null,
      );

  /// Upper bound on per-app entries (bounds the native transport).
  static const int maxApps = 512;

  /// Smart App Lock's own package: never part of a profile, so the app (and
  /// with it permission recovery) is never put behind a profile overlay.
  static const String ownPackage = 'com.smartapplock.app';

  /// The preset, or null for a custom profile (Phase 11 / M2).
  final SecurityProfileKind? kind;

  final String? _customId;
  final String? _customName;

  /// Stable id: the preset id, or the generated custom id.
  String get id => kind?.id ?? _customId!;

  /// Display name: the preset label, or the user's name.
  String get name => kind?.label ?? _customName!;

  /// Whether this is a user-created profile.
  bool get isCustom => kind == null;

  /// Whether the overlay may be edited: Home, Work, Kids and custom
  /// profiles. Normal (no overlay) and Guest (all Critical) are fixed;
  /// they are customized by duplicating them into a custom profile.
  bool get isEditable =>
      kind != SecurityProfileKind.normal && kind != SecurityProfileKind.guest;

  /// Whether the user may rename or delete it (custom profiles only).
  bool get isRemovable => isCustom;

  /// Custom profile ids: `custom-` + 12 lowercase hex digits.
  static final RegExp customIdPattern = RegExp(r'^custom-[0-9a-f]{12}$');

  /// Longest custom name, in characters (after trimming).
  static const int maxNameLength = 32;

  /// Why [raw] is not a valid custom profile name, or null when it is.
  static String? validateName(String raw) {
    final String name = raw.trim();
    if (name.isEmpty) return 'Enter a name.';
    if (name.runes.length > maxNameLength) {
      return 'Use at most $maxNameLength characters.';
    }
    if (name.runes.any((int r) => r < 0x20 || (r >= 0x7f && r < 0xa0))) {
      return 'The name contains characters that are not allowed.';
    }
    return null;
  }

  /// A new random custom id that is not in [taken].
  static String newCustomId(Set<String> taken, {Random? random}) {
    final Random rng = random ?? Random.secure();
    for (;;) {
      final String hex = List<String>.generate(
        12,
        (_) => rng.nextInt(16).toRadixString(16),
      ).join();
      final String id = 'custom-$hex';
      if (!taken.contains(id)) return id;
    }
  }

  /// A copy with a new overlay (and, for custom profiles, a new name).
  /// Throws [SecurityProfileFormatException] when the result is invalid
  /// (for example a Normal or Guest overlay change, or a preset rename).
  SecurityProfile copyWith({
    String? name,
    AppSecurityLevel? allProtectedLevel,
    bool clearAll = false,
    Map<String, AppSecurityLevel>? appLevels,
  }) {
    final AppSecurityLevel? all =
        clearAll ? null : (allProtectedLevel ?? this.allProtectedLevel);
    final Map<String, AppSecurityLevel> apps = appLevels ?? this.appLevels;
    final SecurityProfileKind? preset = kind;
    if (preset != null) {
      if (name != null && name.trim() != preset.label) {
        throw const SecurityProfileFormatException(
          'name',
          'Preset profiles cannot be renamed.',
        );
      }
      return SecurityProfile(
        kind: preset,
        allProtectedLevel: all,
        appLevels: apps,
      );
    }
    return SecurityProfile.custom(
      id: id,
      name: name ?? this.name,
      allProtectedLevel: all,
      appLevels: apps,
    );
  }

  /// Level every PROTECTED app is raised to while active, or null.
  final AppSecurityLevel? allProtectedLevel;

  /// Per-app raise levels (sorted by package, unmodifiable).
  final Map<String, AppSecurityLevel> appLevels;

  /// True when this profile adds no protection at all.
  bool get isEmpty => allProtectedLevel == null && appLevels.isEmpty;

  static void _checkRaising(AppSecurityLevel level, String field) {
    if (level != AppSecurityLevel.sensitive &&
        level != AppSecurityLevel.critical) {
      throw SecurityProfileFormatException(
        field,
        'Profiles only raise protection (Sensitive or Critical).',
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is! SecurityProfile ||
        other.kind != kind ||
        other.id != id ||
        other.name != name ||
        other.allProtectedLevel != allProtectedLevel ||
        other.appLevels.length != appLevels.length) {
      return false;
    }
    for (final MapEntry<String, AppSecurityLevel> e in appLevels.entries) {
      if (other.appLevels[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        kind,
        id,
        name,
        allProtectedLevel,
        Object.hashAll(
          appLevels.entries.map((MapEntry<String, AppSecurityLevel> e) =>
              Object.hash(e.key, e.value)),
        ),
      );

  @override
  String toString() => 'SecurityProfile($id, '
      'all=${allProtectedLevel?.storageId}, apps=${appLevels.length})';
}

/// All profiles plus the ONE active profile id.
final class SecurityProfileSet {
  const SecurityProfileSet._(this.profiles, this.activeProfileId);

  /// Validates: exactly the five presets, each once; at most
  /// [maxCustomProfiles] custom profiles with distinct ids; names unique
  /// ignoring case (custom names never equal a preset name); at most
  /// [maxTotalAppEntries] per-app entries in total; and [activeProfileId]
  /// naming exactly one profile. Canonical order out: presets in
  /// declaration order, then custom profiles by id.
  factory SecurityProfileSet({
    required Iterable<SecurityProfile> profiles,
    required String activeProfileId,
  }) {
    final Map<SecurityProfileKind, SecurityProfile> byKind =
        <SecurityProfileKind, SecurityProfile>{};
    final Map<String, SecurityProfile> customs = <String, SecurityProfile>{};
    final Set<String> names = <String>{};
    int entries = 0;
    for (final SecurityProfile p in profiles) {
      final SecurityProfileKind? kind = p.kind;
      if (kind == null ? customs.containsKey(p.id) : byKind.containsKey(kind)) {
        throw SecurityProfileFormatException(
          'profiles',
          'Duplicate profile: ${p.id}.',
        );
      }
      if (!names.add(p.name.toLowerCase())) {
        throw SecurityProfileFormatException(
          'name',
          'Another profile is already called "${p.name}".',
        );
      }
      entries += p.appLevels.length;
      if (kind == null) {
        customs[p.id] = p;
      } else {
        byKind[kind] = p;
      }
    }
    if (customs.length > maxCustomProfiles) {
      throw const SecurityProfileFormatException(
        'profiles',
        'At most $maxCustomProfiles custom profiles.',
      );
    }
    if (entries > maxTotalAppEntries) {
      throw const SecurityProfileFormatException(
        'apps',
        'At most $maxTotalAppEntries app entries across all profiles.',
      );
    }
    for (final SecurityProfileKind k in SecurityProfileKind.values) {
      if (!byKind.containsKey(k)) {
        throw SecurityProfileFormatException(
          'profiles',
          'Missing profile: ${k.id}.',
        );
      }
    }
    final int matches = <SecurityProfile>[...byKind.values, ...customs.values]
        .where((SecurityProfile p) => p.id == activeProfileId)
        .length;
    if (matches != 1) {
      throw SecurityProfileFormatException(
        'activeProfileId',
        'Must name exactly one profile: $activeProfileId.',
      );
    }
    return SecurityProfileSet._(
      List<SecurityProfile>.unmodifiable(<SecurityProfile>[
        for (final SecurityProfileKind k in SecurityProfileKind.values)
          byKind[k]!,
        for (final String id in customs.keys.toList()..sort()) customs[id]!,
      ]),
      activeProfileId,
    );
  }

  /// Phase 11 / M2: most custom profiles a user may keep.
  static const int maxCustomProfiles = 20;

  /// Phase 11 / M2: most per-app entries across every profile (bounds the
  /// stored document; each profile is separately bounded by
  /// [SecurityProfile.maxApps]).
  static const int maxTotalAppEntries = 2048;

  /// What a user has before anything is saved: all presets at their
  /// defaults, Normal active.
  factory SecurityProfileSet.defaults() => SecurityProfileSet(
        profiles: <SecurityProfile>[
          for (final SecurityProfileKind k in SecurityProfileKind.values)
            SecurityProfile.preset(k),
        ],
        activeProfileId: SecurityProfileKind.normal.id,
      );

  /// The profiles in canonical order (unmodifiable).
  final List<SecurityProfile> profiles;

  /// Id of the single active profile.
  final String activeProfileId;

  SecurityProfile get active =>
      profiles.firstWhere((SecurityProfile p) => p.id == activeProfileId);

  SecurityProfile byKind(SecurityProfileKind kind) =>
      profiles.firstWhere((SecurityProfile p) => p.kind == kind);

  /// The profile with [id], or null.
  SecurityProfile? byId(String id) {
    for (final SecurityProfile p in profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// The custom profiles, by id.
  List<SecurityProfile> get customProfiles =>
      profiles.where((SecurityProfile p) => p.isCustom).toList();

  /// Whether another custom profile may be created.
  bool get canAddCustom => customProfiles.length < maxCustomProfiles;

  /// Whether [name] is free (ignoring case), optionally except [exceptId].
  bool isNameAvailable(String name, {String? exceptId}) {
    final String wanted = name.trim().toLowerCase();
    return !profiles.any(
      (SecurityProfile p) => p.id != exceptId && p.name.toLowerCase() == wanted,
    );
  }

  /// Phase 11 / M2: a copy with [id] active. Throws when [id] is unknown.
  SecurityProfileSet withActive(String id) =>
      SecurityProfileSet(profiles: profiles, activeProfileId: id);

  /// A copy with the profile of the same id replaced by [profile].
  SecurityProfileSet withProfile(SecurityProfile profile) {
    if (byId(profile.id) == null) {
      throw SecurityProfileFormatException(
        'profiles',
        'Unknown profile: ${profile.id}.',
      );
    }
    return SecurityProfileSet(
      profiles: <SecurityProfile>[
        for (final SecurityProfile p in profiles)
          p.id == profile.id ? profile : p,
      ],
      activeProfileId: activeProfileId,
    );
  }

  /// A copy with the new custom [profile] added.
  SecurityProfileSet withAdded(SecurityProfile profile) {
    if (!profile.isCustom) {
      throw const SecurityProfileFormatException(
        'profiles',
        'Only custom profiles can be added.',
      );
    }
    return SecurityProfileSet(
      profiles: <SecurityProfile>[...profiles, profile],
      activeProfileId: activeProfileId,
    );
  }

  /// A copy without the custom profile [id]. Deleting the ACTIVE profile
  /// makes Normal active (the caller treats that as a switch).
  SecurityProfileSet without(String id) {
    final SecurityProfile? target = byId(id);
    if (target == null || !target.isRemovable) {
      throw SecurityProfileFormatException(
        'profiles',
        'Only an existing custom profile can be deleted: $id.',
      );
    }
    return SecurityProfileSet(
      profiles: <SecurityProfile>[
        for (final SecurityProfile p in profiles)
          if (p.id != id) p,
      ],
      activeProfileId: activeProfileId == id
          ? SecurityProfileKind.normal.id
          : activeProfileId,
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! SecurityProfileSet ||
        other.activeProfileId != activeProfileId ||
        other.profiles.length != profiles.length) {
      return false;
    }
    for (int i = 0; i < profiles.length; i++) {
      if (other.profiles[i] != profiles[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(activeProfileId, Object.hashAll(profiles));

  @override
  String toString() => 'SecurityProfileSet(active=$activeProfileId)';
}
