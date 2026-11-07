import '../../rules/smart_rule.dart';
import '../../utilities/result.dart';

/// Why a Smart Rule storage operation failed.
enum SmartRuleStoreErrorKind {
  /// The saved rules could not be read (storage threw).
  storageUnavailable,

  /// The saved rules exist but cannot be decoded. They are kept as-is; no
  /// write replaces them (no silent "empty list").
  corrupt,

  /// The saved rules were written by a newer build. Kept as-is; no write.
  unsupportedVersion,

  /// A write failed or could not be confirmed. The previous saved rules were
  /// restored (best effort); the change was NOT saved.
  writeFailed,

  /// No rule with that id exists. Nothing was written.
  notFound,

  /// Phase 10 / M2: the stored rule is not the version the caller edited
  /// (changed or deleted meanwhile), or a new rule's id already exists.
  /// Nothing was written; reload and retry.
  conflict,
}

class SmartRuleStoreException implements Exception {
  const SmartRuleStoreException(this.kind, this.message, [this.cause]);

  final SmartRuleStoreErrorKind kind;
  final String message;
  final Object? cause;

  @override
  String toString() => 'SmartRuleStoreException(${kind.name}): $message';
}

/// Phase 10 / M1: configuration storage for Smart Rules.
///
/// Stores and returns validated [SmartRule]s only. These are configuration
/// writes, not rule actions: no operation here changes protection, a level,
/// the protected set, grace, authorization, a challenge or anything native.
/// Every failure is a [Result.failure] carrying a [SmartRuleStoreException];
/// a failed write is never reported as saved.
abstract interface class SmartRuleRepository {
  /// All rules in stored order (an empty list only when nothing is saved).
  Future<Result<List<SmartRule>>> getRules();

  /// Inserts a new rule (appended) or replaces the rule with the same id
  /// (position kept). Saving an identical rule writes nothing.
  ///
  /// Phase 10 / M2 stale-edit protection (optional, compare-and-swap):
  /// [mustBeNew] fails with `conflict` when the id already exists;
  /// [expected] fails with `conflict` unless the stored rule with that id
  /// equals it exactly (so an old form never overwrites a newer change).
  Future<Result<void>> saveRule(
    SmartRule rule, {
    SmartRule? expected,
    bool mustBeNew = false,
  });

  /// Removes the rule with [id]; `notFound` when there is none. With
  /// [expected], `conflict` unless the stored rule equals it.
  Future<Result<void>> deleteRule(String id, {SmartRule? expected});

  /// Persists the enabled state of the rule with [id] (the rule is kept;
  /// disabling never deletes). `notFound` when there is none. With
  /// [expected], `conflict` unless the stored rule equals it.
  Future<Result<void>> setRuleEnabled(
    String id, {
    required bool enabled,
    SmartRule? expected,
  });

  /// Phase 10 / M2: replaces the whole stored list by [rules] (order kept),
  /// only when the stored list still equals [expected] exactly (otherwise
  /// `conflict`, nothing written). Used to restore the previous rules after
  /// a PIN-confirmed reduction that native did not durably acknowledge.
  Future<Result<void>> replaceRules(
    List<SmartRule> rules, {
    required List<SmartRule> expected,
  });
}
