import '../../../rules/smart_rule.dart';
import '../../../rules/smart_rule_document.dart';
import '../../../utilities/result.dart';
import '../../storage/local_database.dart';
import '../smart_rule_repository.dart';

/// [SmartRuleRepository] over the existing [LocalDatabase] settings table.
///
/// Storage: ONE row, key [storageKey], value = the versioned JSON document
/// of [SmartRuleDocument]. Every change rewrites the whole document in one
/// single-row write (SQLite `INSERT OR REPLACE`, atomic), so a rule set is
/// never half-written. No schema migration and no new dependency.
///
/// No cache: every operation reads the stored document first, so no
/// unsaved state can be held in memory. Writes:
///  * refuse to run while the stored document is corrupt, unsupported or
///    unreadable (nothing replaces it implicitly);
///  * are confirmed by reading the value back;
///  * on failure restore the previous value (or remove the key when there
///    was none) as a best effort, then report `writeFailed` with the
///    original error. This is the same rollback as the Phase 9 / M3
///    dismissal fix: a store may keep a failed value in memory.
/// Operations on one instance run one at a time (no lost updates).
///
/// Only [storageKey] is ever touched. No protection, level, grace,
/// authorization or native call is reachable from here.
class SmartRuleRepositoryImpl implements SmartRuleRepository {
  SmartRuleRepositoryImpl(this._database);

  /// The `security_settings` key holding the rule document.
  static const String storageKey = 'smart_rules';

  final LocalDatabase _database;
  Future<void> _tail = Future<void>.value();

  @override
  Future<Result<List<SmartRule>>> getRules() =>
      _serialized(() async => (await _load()).rules);

  @override
  Future<Result<void>> saveRule(
    SmartRule rule, {
    SmartRule? expected,
    bool mustBeNew = false,
  }) =>
      _serialized(() async {
        final _Stored stored = await _load();
        final List<SmartRule> rules = List<SmartRule>.of(stored.rules);
        final int index = rules.indexWhere((SmartRule r) => r.id == rule.id);
        if (mustBeNew && index >= 0) {
          throw _conflict('A rule with id "${rule.id}" already exists.');
        }
        if (expected != null) _checkExpected(rules, index, expected);
        if (index >= 0) {
          if (rules[index] == rule) return;
          rules[index] = rule;
        } else {
          rules.add(rule);
        }
        await _write(stored, rules);
      });

  @override
  Future<Result<void>> deleteRule(String id, {SmartRule? expected}) =>
      _serialized(() async {
        final _Stored stored = await _load();
        final List<SmartRule> rules = List<SmartRule>.of(stored.rules);
        final int index = rules.indexWhere((SmartRule r) => r.id == id);
        if (index < 0) throw _notFound(id);
        if (expected != null) _checkExpected(rules, index, expected);
        rules.removeAt(index);
        await _write(stored, rules);
      });

  @override
  Future<Result<void>> setRuleEnabled(
    String id, {
    required bool enabled,
    SmartRule? expected,
  }) =>
      _serialized(() async {
        final _Stored stored = await _load();
        final List<SmartRule> rules = List<SmartRule>.of(stored.rules);
        final int index = rules.indexWhere((SmartRule r) => r.id == id);
        if (index < 0) throw _notFound(id);
        if (expected != null) _checkExpected(rules, index, expected);
        if (rules[index].enabled == enabled) return;
        rules[index] = rules[index].copyWith(enabled: enabled);
        await _write(stored, rules);
      });

  @override
  Future<Result<void>> replaceRules(
    List<SmartRule> rules, {
    required List<SmartRule> expected,
  }) =>
      _serialized(() async {
        final _Stored stored = await _load();
        if (!_sameList(stored.rules, expected)) {
          throw _conflict(
            'The rules changed since they were read. Reload and try again.',
          );
        }
        if (_sameList(stored.rules, rules)) return;
        await _write(stored, List<SmartRule>.of(rules));
      });

  // -- internals -------------------------------------------------------------

  static bool _sameList(List<SmartRule> a, List<SmartRule> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<Result<T>> _serialized<T>(Future<T> Function() action) {
    final Future<Result<T>> result = _tail.then((_) async {
      try {
        return Result<T>.success(await action());
      } on SmartRuleStoreException catch (e) {
        return Result<T>.failure(e);
      } catch (e) {
        return Result<T>.failure(
          SmartRuleStoreException(
            SmartRuleStoreErrorKind.storageUnavailable,
            'Smart Rules storage failed.',
            e,
          ),
        );
      }
    });
    _tail = result.then<void>((_) {});
    return result;
  }

  Future<_Stored> _load() async {
    final String? raw;
    try {
      raw = await _database.getSetting(storageKey);
    } catch (e) {
      throw SmartRuleStoreException(
        SmartRuleStoreErrorKind.storageUnavailable,
        'Saved rules could not be read.',
        e,
      );
    }
    if (raw == null) return const _Stored(null, <SmartRule>[]);
    try {
      return _Stored(raw, SmartRuleDocument.decode(raw));
    } on SmartRuleDocumentException catch (e) {
      throw SmartRuleStoreException(
        e.problem == SmartRuleDocumentProblem.unsupportedVersion
            ? SmartRuleStoreErrorKind.unsupportedVersion
            : SmartRuleStoreErrorKind.corrupt,
        'Saved rules cannot be used: ${e.detail}',
        e,
      );
    }
  }

  Future<void> _write(_Stored before, List<SmartRule> rules) async {
    final String encoded = SmartRuleDocument.encode(rules);
    Object? failure;
    try {
      await _database.setSetting(storageKey, encoded);
      final String? confirmed = await _database.getSetting(storageKey);
      if (confirmed != encoded) {
        failure = StateError('The saved rules could not be confirmed.');
      }
    } catch (e) {
      failure = e;
    }
    if (failure == null) return;
    try {
      final String? previous = before.raw;
      if (previous == null) {
        await _database.removeSetting(storageKey);
      } else {
        await _database.setSetting(storageKey, previous);
      }
    } catch (_) {
      // Best effort; the original failure is what the caller must see.
    }
    throw SmartRuleStoreException(
      SmartRuleStoreErrorKind.writeFailed,
      'The rule change was not saved.',
      failure,
    );
  }

  /// Phase 10 / M2: compare-and-swap check against the stored rule.
  static void _checkExpected(
    List<SmartRule> rules,
    int index,
    SmartRule expected,
  ) {
    if (index < 0 || rules[index] != expected) {
      throw _conflict(
        'The rule changed since it was opened. Reload and try again.',
      );
    }
  }

  static SmartRuleStoreException _conflict(String message) =>
      SmartRuleStoreException(SmartRuleStoreErrorKind.conflict, message);

  static SmartRuleStoreException _notFound(String id) =>
      SmartRuleStoreException(
        SmartRuleStoreErrorKind.notFound,
        'No rule with id "$id".',
      );
}

class _Stored {
  const _Stored(this.raw, this.rules);

  /// The stored document as read (null = nothing saved).
  final String? raw;
  final List<SmartRule> rules;
}
