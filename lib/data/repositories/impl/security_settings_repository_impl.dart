import 'dart:convert';

import '../../../utilities/result.dart';
import '../../models/security_settings.dart';
import '../../storage/local_database.dart';
import '../security_settings_repository.dart';

/// [SecuritySettingsRepository] over the [LocalDatabase].
///
/// Settings are stored as one JSON document under the key
/// `security_settings`.
class SecuritySettingsRepositoryImpl implements SecuritySettingsRepository {
  SecuritySettingsRepositoryImpl(this._database);

  static const String _storageKey = 'security_settings';

  final LocalDatabase _database;

  @override
  Future<Result<SecuritySettings>> getSettings() async {
    try {
      final String? raw = await _database.getSetting(_storageKey);
      if (raw == null) {
        return Result.success(SecuritySettings.defaults);
      }
      final Map<String, dynamic> json =
          jsonDecode(raw) as Map<String, dynamic>;
      return Result.success(
        SecuritySettings.fromJson(json.cast<String, dynamic>()),
      );
    } catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<void>> saveSettings(SecuritySettings settings) async {
    try {
      await _database.setSetting(_storageKey, jsonEncode(settings.toJson()));
      return Result.success(null);
    } catch (e) {
      return Result.failure(e);
    }
  }

  @override
  Future<Result<bool>> hasPin() async {
    final Result<SecuritySettings> settings = await getSettings();
    return settings.fold(
      (SecuritySettings s) => Result.success(s.hasPin),
      Result.failure,
    );
  }
}
