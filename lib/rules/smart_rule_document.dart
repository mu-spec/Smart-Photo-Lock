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
/// document (schema v1):
///
/// ```json
/// {"schema":"smart_rules","version":1,"rules":[
///   {"id":"r1","name":"Work hours","enabled":true,
///    "targets":["com.example.mail"],"days":[1,2,3,4,5],
///    "time":{"type":"window","start":540,"end":1020}}]}
/// ```
///
/// Decoding is all-or-nothing: one unreadable rule makes the whole document
/// [SmartRuleDocumentProblem.corrupt]. There is no partial list and no
/// silent fallback to "no rules". Encoding is deterministic (fixed key
/// order, sorted lists, rules in stored order).
///
/// Migration: a future schema bumps [currentVersion] and adds an explicit
/// vN → vN+1 path here. An older build that meets a newer document reports
/// [SmartRuleDocumentProblem.unsupportedVersion] and refuses to write.
abstract final class SmartRuleDocument {
  static const String schema = 'smart_rules';
  static const int currentVersion = 1;

  static const Set<String> _keys = <String>{'schema', 'version', 'rules'};

  /// Encodes [rules] in order. Throws [ArgumentError] on duplicate ids.
  static String encode(List<SmartRule> rules) {
    final Set<String> ids = <String>{};
    for (final SmartRule r in rules) {
      if (!ids.add(r.id)) {
        throw ArgumentError.value(r.id, 'rules', 'Duplicate rule id');
      }
    }
    return jsonEncode(<String, Object?>{
      'schema': schema,
      'version': currentVersion,
      'rules': <Object?>[for (final SmartRule r in rules) r.toJson()],
    });
  }

  /// Decodes [encode] output. Throws [SmartRuleDocumentException].
  static List<SmartRule> decode(String raw) {
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
    if (version != currentVersion) {
      throw SmartRuleDocumentException(
        SmartRuleDocumentProblem.corrupt,
        'Version $version was never written by any build.',
        version: version,
      );
    }
    if (json.length != _keys.length || !json.keys.every(_keys.contains)) {
      throw const SmartRuleDocumentException(
        SmartRuleDocumentProblem.corrupt,
        'Unexpected fields in the document.',
        version: currentVersion,
      );
    }
    final Object? list = json['rules'];
    if (list is! List) {
      throw const SmartRuleDocumentException(
        SmartRuleDocumentProblem.corrupt,
        '"rules" is not a list.',
        version: currentVersion,
      );
    }
    final List<SmartRule> rules = <SmartRule>[];
    final Set<String> ids = <String>{};
    for (int i = 0; i < list.length; i++) {
      final SmartRule rule;
      try {
        rule = SmartRule.fromJson(list[i]);
      } on SmartRuleFormatException catch (e) {
        throw SmartRuleDocumentException(
          SmartRuleDocumentProblem.corrupt,
          'Rule $i is invalid (${e.field}): ${e.message}',
          version: currentVersion,
        );
      }
      if (!ids.add(rule.id)) {
        throw SmartRuleDocumentException(
          SmartRuleDocumentProblem.corrupt,
          'Duplicate rule id "${rule.id}".',
          version: currentVersion,
        );
      }
      rules.add(rule);
    }
    return List<SmartRule>.unmodifiable(rules);
  }
}
