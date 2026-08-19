import '../../utilities/result.dart';
import '../models/protected_app.dart';

/// Source of truth for which apps the user protects.
///
/// Implemented in Phase 1E on top of the local database. The lock phases
/// will consult this list (via the protection layer) — never directly.
abstract interface class ProtectedAppsRepository {
  /// All protected apps, ordered for display (sortOrder, then label).
  Future<Result<List<ProtectedApp>>> getProtectedApps();

  /// Protects an app (upsert by package name).
  Future<Result<void>> add(ProtectedApp app);

  /// Stops protecting an app.
  Future<Result<void>> remove(String packageName);

  Future<Result<bool>> isProtected(String packageName);

  Future<Result<int>> count();
}
