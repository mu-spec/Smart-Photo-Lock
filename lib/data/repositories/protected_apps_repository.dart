import '../../utilities/result.dart';
import '../models/app_security_level.dart';
import '../models/protected_app.dart';

/// Source of truth for which apps the user protects.
///
/// Implemented in Phase 1E on top of the local database. The lock phases
/// will consult this list (via the protection layer) — never directly.
abstract interface class ProtectedAppsRepository {
  /// All protected apps, ordered for display (sortOrder, then label).
  Future<Result<List<ProtectedApp>>> getProtectedApps();

  /// Protects an app (upsert by package name). A newly protected app gets
  /// [ProtectedApp.securityLevel] (Standard by default); protecting an app
  /// that is already protected keeps its current level (Phase 8 / M1).
  Future<Result<void>> add(ProtectedApp app);

  /// Phase 8 / M1: sets the security level of a protected app. Fails (and
  /// changes nothing) when the app is not protected or the write fails; it
  /// never protects, unprotects, unlocks or authorizes anything.
  Future<Result<void>> setSecurityLevel(
    String packageName,
    AppSecurityLevel level,
  );

  /// Stops protecting an app. Its security level is removed with the
  /// record; protecting it again starts from Standard.
  Future<Result<void>> remove(String packageName);

  Future<Result<bool>> isProtected(String packageName);

  Future<Result<int>> count();
}
