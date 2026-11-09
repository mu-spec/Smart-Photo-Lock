import 'dart:convert';

import 'smart_rule.dart';

/// Why a stored rule document could not be used.
enum SmartRuleDocumentProblem {
  /// Not valid JSON, wrong shape, an invalid rule, a duplicate id, or a
  /// version number that no build ever wrote (below 1).
  corrupt,

  /// Written by a newer build ([SmartRuleDocumentException.version] >
  /// [SmartRuleDocument.currentVersion]). Kept as-is; never overwritten.
  unsupportedVersion,
}

class SmartRuleDocumentException implements Exception {
  const SmartRuleDocumentException(this.problem, this.detail, {this.version});

  final SmartRuleDocumentProblem problem;
  final String detail;

  /// The stored version, when one could be read.
  final int? version;

  @override
  String toString() => 'SmartRuleDocumentException(${problem.name}): $detail';
}

/// Phase 10 / M1: the persisted form of the whole rule set, one JSON
/// document. Phase 10 / M2 writes schema v2, which adds a required
/// per-rule `action`:
///
/// ```json
/// {"schema":"smart_rules","version":2,"rules":[
///   {"id":"r1","name":"Work hours","enabled":true,
///    "targets":["com.example.mail"],"days":[1,2,3,4,5],
///    "time":{"type":"window","start":540,"end":1020},
///    "action":"critical"}]}
/// ```
///
/// Migration v1 → v2 (explicit, on read, [decodeDocument]): a v1 document
/// (M1, no `action`) is accepted and every rule keeps its id, name, enabled
/// state, targets, days and time, and receives
/// [SmartRuleAction.migratedFromV1] (Standard: no enforcement effect, so a
/// migrated rule never activates by surprise). The stored v1 text is NOT
/// rewritten on read; the next confirmed write stores v2. Nothing is ever
/// dropped: an invalid v1 rule makes the whole document corrupt.
///
/// Decoding is all-or-nothing: one unreadable rule makes the whole document
/// [SmartRuleDocumentProblem.corrupt]. There is no partial list and no
/// silent fallback to "no rules". Encoding is deterministic (fixed key
/// order, sorted lists, rules in stored order).
///
/// Phase 11 / M3 writes schema v3: level rules keep the exact v2 layout;
/// a new "Apply profile" rule is
/// `{"id","name","enabled","days","time","action":"profile","profile":<id>}`
/// (no `targets`). Migration v2 → v3 is lossless and needs no rewrite: every
/// v2 rule is read unchanged (ids, names, enabled state, targets, days, time
/// and action); no profile action is ever invented. A `"profile"` action in
/// a v1/v2 document is corrupt. As before, the stored text is rewritten only
/// by the next confirmed write, so no partially migrated state exists.
///
/// Limits (all-or-nothing, on read and write): at most [maxRules] rules, of
/// which at most [maxProfileRules] activate a profile, and at most
/// [maxDocumentLength] characters.
///
/// A future schema bumps [currentVersion] and adds an explicit vN → vN+1
/// path here. An older build that meets a newer document reports
/// [SmartRuleDocumentProblem.unsupportedVersion] and refuses to write.
abstract final class SmartRuleDocument {
  static const String schema = 'smart_rules';
  static const int currentVersion = 3;

  /// Phase 11 / M3: limits of one rule document.
  static const int maxRules = 200;
  static const int maxProfileRules = 32;
  static const int maxDocumentLength = 256 * 1024;

  /// The oldest schema this build can still read (and migrate).
  static const int oldestReadableVersion = 1;

  static const Set<String> _keys = <String>{'schema', 'version', 'rules'};

  /// Encodes [rules] in order. Throws [ArgumentError] on duplicate ids or
  /// when a limit is exceeded (nothing is written then).
  static String encode(List<SmartRule> rules) {
    final Set<String> ids = <String>{};
    for (final SmartRule r in rules) {
      if (!ids.add(r.id)) {
        throw ArgumentError.value(r.id, 'rules', 'Duplicate rule id');
      }
    }
    final String? overLimit = limitProblem(rules);
    if (overLimit != null) throw ArgumentError(overLimit);
    final String encoded = jsonEncode(<String, Object?>{
      'schema': schema,
      'version': currentVersion,
      'rules': <Object?>[for (final SmartRule r in rules) r.toJson()],
    });
    if (encoded.length > maxDocumentLength) {
      throw ArgumentError('The rule document exceeds $maxDocumentLength '
          'characters.');
    }
    return encoded;
  }

  /// Phase 11 / M3: why [rules] exceed a count limit, or null.
  static String? limitProblem(List<SmartRule> rules) {
    if (rules.length > maxRules) return 'At most $maxRules rules.';
    if (rules.where((SmartRule r) => r.isProfileRule).length >
        maxProfileRules) {
      return 'At most $maxProfileRules profile rules.';
    }
    return null;
  }

  /// Decodes a stored document (v1, v2 or v3). Throws
  /// [SmartRuleDocumentException].
  static List<SmartRule> decode(String raw) => decodeDocument(raw).rules;

  /// Like [decode], also reporting the stored schema version.
  static SmartRuleDocumentRead decodeDocument(String raw) {
    if (raw.length > maxDocumentLength) {
      throw const SmartRuleDocumentException(
        SmartRuleDocumentProblem.corrupt,
        'The document exceeds the size limit.',
      );
    }
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException catch (e) {
      throw SmartRuleDocumentException(
        SmartRuleDocumentProblem.corrupt,
        'Not valid JSON: ${e.message}',
      );
    }
    if (json is! Map) {
      throw const SmartRuleDocumentException(
        SmartRuleDocumentProblem.corrupt,
        'Not a JSON object.',
      );
    }
    if (json['schema'] != schema) {
      throw const SmartRuleDocumentException(
        SmartRuleDocumentProblem.corrupt,
        'Missing or wrong schema name.',
      );
    }
    final Object? version = json['version'];
    if (version is! int) {
      throw const SmartRuleDocumentException(
        SmartRuleDocumentProblem.corrupt,
        'Missing or non-integer version.',
      );
    }
    if (version > currentVersion) {
      throw SmartRuleDocumentException(
        SmartRuleDocumentProblem.unsupportedVersion,
        'Version $version is newer than this build supports '
        '($currentVersion).',
        version: version,
      );
    }
    if (version < oldestReadableVersion) {
      throw SmartRuleDocumentException(
        SmartRuleDocumentProblem.corrupt,
        'Version $version was never written by any build.',
        version: version,
      );
    }
    if (json.length != _keys.length || !json.keys.every(_keys.contains)) {
      throw SmartRuleDocumentException(
        SmartRuleDocumentProblem.corrupt,
        'Unexpected fields in the document.',
        version: version,
      );
    }
    final Object? list = json['rules'];
    if (list is! List) {
      throw SmartRuleDocumentException(
        SmartRuleDocumentProblem.corrupt,
        '"rules" is not a list.',
        version: version,
      );
    }
    final List<SmartRule> rules = <SmartRule>[];
    final Set<String> ids = <String>{};
    for (int i = 0; i < list.length; i++) {
      final SmartRule rule;
      try {
        rule = SmartRule.fromJson(list[i], version: version);
      } on SmartRuleFormatException catch (e) {
        throw SmartRuleDocumentException(
          SmartRuleDocumentProblem.corrupt,
          'Rule $i is invalid (${e.field}): ${e.message}',
          version: version,
        );
      }
      if (!ids.add(rule.id)) {
        throw SmartRuleDocumentException(
          SmartRuleDocumentProblem.corrupt,
          'Duplicate rule id "${rule.id}".',
          version: version,
        );
      }
      rules.add(rule);
    }
    final String? overLimit = limitProblem(rules);
    if (overLimit != null) {
      throw SmartRuleDocumentException(
        SmartRuleDocumentProblem.corrupt,
        overLimit,
        version: version,
      );
    }
    return SmartRuleDocumentRead(
      rules: List<SmartRule>.unmodifiable(rules),
      storedVersion: version,
    );
  }
}

/// Result of [SmartRuleDocument.decodeDocument].
final class SmartRuleDocumentRead {
  const SmartRuleDocumentRead({
    required this.rules,
    required this.storedVersion,
  });

  final List<SmartRule> rules;

  /// Schema version of the stored text (1 = migrated M1 document).
  final int storedVersion;

  /// True when [rules] were migrated from an older schema on this read.
  bool get migrated => storedVersion < SmartRuleDocument.currentVersion;
}
