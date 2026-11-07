import '../../../profiles/security_profile.dart';
import '../../../profiles/security_profile_document.dart';
import '../../../utilities/result.dart';
import '../../storage/local_database.dart';
import '../security_profile_repository.dart';

/// [SecurityProfileRepository] over the existing [LocalDatabase] settings
/// table: ONE row, key [storageKey], value = the versioned JSON document of
/// [SecurityProfileDocument]. Same write discipline as the Phase 10 Smart
/// Rules repository:
///  * one single-row write per change (atomic), no cache, every operation
///    reads the stored value first;
///  * refuses to write over a corrupt, unsupported or unreadable value;
///  * each write is confirmed by reading it back; on failure the previous
///    value is restored (or the key removed) as a best effort and
///    `writeFailed` is reported;
///  * operations on one instance run one at a time.
/// Only [storageKey] is touched. The legacy `profiles` table and
/// `pref.profile.last_active_id` are never read or written.
class SecurityProfileRepositoryImpl implements SecurityProfileRepository {
  SecurityProfileRepositoryImpl(this._database);

  /// The settings key holding the profile document.
  static const String storageKey = 'security_profiles';

  final LocalDatabase _database;
  Future<void> _tail = Future<void>.value();

  @override
  Future<Result<SecurityProfileSet>> getProfiles() =>
      _serialized(() async => (await _load()).set);

  @override
  Future<Result<void>> saveProfiles(
    SecurityProfileSet profiles, {
    required SecurityProfileSet expected,
  }) =>
      _serialized(() async {
        final _Stored stored = await _load();
        if (stored.set != expected) {
          throw const SecurityProfileStoreException(
            SecurityProfileStoreErrorKind.conflict,
            'The profiles changed since they were read. Reload and try again.',
          );
        }
        if (stored.set == profiles && stored.raw != null) return;
        await _write(stored, profiles);
      });

  Future<Result<T>> _serialized<T>(Future<T> Function() action) {
    final Future<Result<T>> result = _tail.then((_) async {
      try {
        return Result<T>.success(await action());
      } on SecurityProfileStoreException catch (e) {
        return Result<T>.failure(e);
      } catch (e) {
        return Result<T>.failure(
          SecurityProfileStoreException(
            SecurityProfileStoreErrorKind.storageUnavailable,
            'Security profile storage failed.',
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
      throw SecurityProfileStoreException(
        SecurityProfileStoreErrorKind.storageUnavailable,
        'Saved profiles could not be read.',
        e,
      );
    }
    if (raw == null) return _Stored(null, SecurityProfileSet.defaults());
    try {
      return _Stored(raw, SecurityProfileDocument.decode(raw));
    } on SecurityProfileDocumentException catch (e) {
      throw SecurityProfileStoreException(
        e.problem == SecurityProfileDocumentProblem.unsupportedVersion
            ? SecurityProfileStoreErrorKind.unsupportedVersion
            : SecurityProfileStoreErrorKind.corrupt,
        'Saved profiles cannot be used: ${e.detail}',
        e,
      );
    }
  }

  Future<void> _write(_Stored before, SecurityProfileSet profiles) async {
    final String encoded = SecurityProfileDocument.encode(profiles);
    Object? failure;
    try {
      await _database.setSetting(storageKey, encoded);
      final String? confirmed = await _database.getSetting(storageKey);
      if (confirmed != encoded) {
        failure = StateError('The saved profiles could not be confirmed.');
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
    throw SecurityProfileStoreException(
      SecurityProfileStoreErrorKind.writeFailed,
      'The profile change was not saved.',
      failure,
    );
  }
}

class _Stored {
  const _Stored(this.raw, this.set);

  /// The stored document as read (null = nothing saved).
  final String? raw;
  final SecurityProfileSet set;
}
