import '../../utilities/result.dart';
import '../models/security_settings.dart';

/// Source of truth for the security configuration (PIN credential, intruder
/// selfie, stealth mode, lockout policy, ...).
///
/// Stored as a single JSON document in the local database's key-value table.
/// No protection logic here — enforcement phases *read* these settings and
/// act on them elsewhere.
abstract interface class SecuritySettingsRepository {
  /// Current settings, or [SecuritySettings.defaults] when nothing was saved.
  Future<Result<SecuritySettings>> getSettings();

  Future<Result<void>> saveSettings(SecuritySettings settings);

  /// Convenience: true once a PIN credential is stored.
  Future<Result<bool>> hasPin();
}
