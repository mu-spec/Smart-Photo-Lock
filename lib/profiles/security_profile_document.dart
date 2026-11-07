/// Phase 11 / M1: the versioned JSON document holding [SecurityProfileSet].
///
/// ```json
/// {
///   "version": 1,
///   "activeProfileId": "normal",
///   "profiles": [
///     {"id": "normal", "all": null, "apps": {}},
///     {"id": "guest", "all": "critical", "apps": {}},
///     {"id": "kids", "all": null, "apps": {"com.example.notes": "critical"}},
///     ...
///   ]
/// }
/// ```
///
/// Strict decode: exact keys, exact types, every profile and set validated
/// by the model. Anything else is [SecurityProfileDocumentProblem.corrupt];
/// a newer version is [SecurityProfileDocumentProblem.unsupportedVersion].
/// A rejected document is never "repaired" or replaced by defaults here.
library;

import 'dart:convert';

import '../data/models/app_security_level.dart';
import 'security_profile.dart';

enum SecurityProfileDocumentProblem { corrupt, unsupportedVersion }

class SecurityProfileDocumentException implements Exception {
  const SecurityProfileDocumentException(this.problem, this.detail);

  final SecurityProfileDocumentProblem problem;
  final String detail;

  @override
  String toString() =>
      'SecurityProfileDocumentException(${problem.name}): $detail';
}

abstract final class SecurityProfileDocument {
  static const int version = 1;

  static String encode(SecurityProfileSet set) => jsonEncode(<String, Object?>{
        'version': version,
        'activeProfileId': set.activeProfileId,
        'profiles': <Object?>[
          for (final SecurityProfile p in set.profiles)
            <String, Object?>{
              'id': p.id,
              'all': p.allProtectedLevel?.storageId,
              'apps': <String, Object?>{
                for (final MapEntry<String, AppSecurityLevel> e
                    in p.appLevels.entries)
                  e.key: e.value.storageId,
              },
            },
        ],
      });

  static SecurityProfileSet decode(String raw) {
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException catch (e) {
      throw _corrupt('Not JSON: ${e.message}');
    }
    if (json is! Map<String, Object?>) throw _corrupt('Not an object.');
    final Object? v = json['version'];
    if (v is! int) throw _corrupt('Missing or non-integer version.');
    if (v > version) {
      throw SecurityProfileDocumentException(
        SecurityProfileDocumentProblem.unsupportedVersion,
        'Version $v is newer than $version.',
      );
    }
    if (v != version) throw _corrupt('Unknown version $v.');
    _exactKeys(json, const <String>{'version', 'activeProfileId', 'profiles'});
    final Object? active = json['activeProfileId'];
    final Object? list = json['profiles'];
    if (active is! String) throw _corrupt('activeProfileId is not a string.');
    if (list is! List<Object?>) throw _corrupt('profiles is not a list.');
    try {
      return SecurityProfileSet(
        profiles: <SecurityProfile>[for (final Object? p in list) _one(p)],
        activeProfileId: active,
      );
    } on SecurityProfileFormatException catch (e) {
      throw _corrupt(e.toString());
    }
  }

  static SecurityProfile _one(Object? raw) {
    if (raw is! Map<String, Object?>) throw _corrupt('Profile not an object.');
    _exactKeys(raw, const <String>{'id', 'all', 'apps'});
    final SecurityProfileKind? kind = SecurityProfileKind.fromId(raw['id']);
    if (kind == null) throw _corrupt('Unknown profile id: ${raw['id']}.');
    final Object? all = raw['all'];
    final Object? apps = raw['apps'];
    if (apps is! Map<String, Object?>) throw _corrupt('apps not an object.');
    return SecurityProfile(
      kind: kind,
      allProtectedLevel: all == null ? null : _level(all),
      appLevels: <String, AppSecurityLevel>{
        for (final MapEntry<String, Object?> e in apps.entries)
          e.key: _level(e.value),
      },
    );
  }

  static AppSecurityLevel _level(Object? raw) => switch (raw) {
        'sensitive' => AppSecurityLevel.sensitive,
        'critical' => AppSecurityLevel.critical,
        _ => throw _corrupt('Not a raising level: $raw.'),
      };

  static void _exactKeys(Map<String, Object?> map, Set<String> keys) {
    if (map.length != keys.length || !keys.every(map.containsKey)) {
      throw _corrupt('Expected exactly the keys $keys.');
    }
  }

  static SecurityProfileDocumentException _corrupt(String detail) =>
      SecurityProfileDocumentException(
        SecurityProfileDocumentProblem.corrupt,
        detail,
      );
}
