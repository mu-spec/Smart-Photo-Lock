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
/// This is NOT the legacy Phase 1 scaffold (`lock_profile.dart`,
/// `profile_manager.dart`), which stays unchanged and disconnected from
/// enforcement. Pure Dart, no I/O.
library;

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
  });

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
  }) {
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
        break;
    }
    return SecurityProfile._(
      kind: kind,
      allProtectedLevel: allProtectedLevel,
      appLevels: Map<String, AppSecurityLevel>.unmodifiable(normalized),
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

  final SecurityProfileKind kind;

  /// Profile id (M1: the preset id).
  String get id => kind.id;

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
        allProtectedLevel,
        Object.hashAll(
          appLevels.entries.map((MapEntry<String, AppSecurityLevel> e) =>
              Object.hash(e.key, e.value)),
        ),
      );

  @override
  String toString() => 'SecurityProfile(${kind.id}, '
      'all=${allProtectedLevel?.storageId}, apps=${appLevels.length})';
}

/// All profiles plus the ONE active profile id.
final class SecurityProfileSet {
  const SecurityProfileSet._(this.profiles, this.activeProfileId);

  /// Validates: exactly the five presets, each once (any order in, canonical
  /// order out), and [activeProfileId] naming exactly one of them.
  factory SecurityProfileSet({
    required Iterable<SecurityProfile> profiles,
    required String activeProfileId,
  }) {
    final Map<SecurityProfileKind, SecurityProfile> byKind =
        <SecurityProfileKind, SecurityProfile>{};
    for (final SecurityProfile p in profiles) {
      if (byKind.containsKey(p.kind)) {
        throw SecurityProfileFormatException(
          'profiles',
          'Duplicate profile: ${p.id}.',
        );
      }
      byKind[p.kind] = p;
    }
    for (final SecurityProfileKind k in SecurityProfileKind.values) {
      if (!byKind.containsKey(k)) {
        throw SecurityProfileFormatException(
          'profiles',
          'Missing profile: ${k.id}.',
        );
      }
    }
    final int matches = byKind.values
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
      ]),
      activeProfileId,
    );
  }

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

  @override
  bool operator ==(Object other) {
    if (other is! SecurityProfileSet ||
        other.activeProfileId != activeProfileId) {
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
