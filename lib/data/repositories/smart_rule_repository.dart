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
  Future<Result<void>> saveRule(SmartRule rule);

  /// Removes the rule with [id]; `notFound` when there is none.
  Future<Result<void>> deleteRule(String id);

  /// Persists the enabled state of the rule with [id] (the rule is kept;
  /// disabling never deletes). `notFound` when there is none.
  Future<Result<void>> setRuleEnabled(String id, {required bool enabled});
}
