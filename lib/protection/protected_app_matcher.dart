import '../data/repositories/protected_apps_repository.dart';
import '../utilities/result.dart';
import 'foreground_app_monitor.dart';

/// Outcome of matching a foreground package against the protected-app
/// repository (Phase 5C).
enum ProtectedMatchDecision {
  /// The package IS in the protected list — the lock engine must act.
  protected,

  /// The package is known NOT to be protected.
  notProtected,

  /// The repository could not be read — the decision is unknown. The
  /// matcher never guesses; the lock engine decides how to treat it.
  unknown,
}

/// A single matching decision for one foreground package.
class ProtectedMatch {
  const ProtectedMatch({
    required this.packageName,
    required this.decision,
    required this.at,
  });

  final String packageName;
  final ProtectedMatchDecision decision;

  /// When the decision was produced.
  final DateTime at;

  /// Convenience: true only for [ProtectedMatchDecision.protected].
  bool get isProtected => decision == ProtectedMatchDecision.protected;

  @override
  String toString() =>
      'ProtectedMatch($packageName -> ${decision.name} at '
      '${at.toIso8601String()})';
}

/// Phase 5C: decides whether a foreground package exists in the
/// protected-app repository.
///
/// This is the bridge between detection (5A) and enforcement (5D+):
/// the matcher consumes a foreground package name and answers with a
/// [ProtectedMatch]. Fail-closed semantics:
///
///  * an empty/blank package name can never be protected;
///  * a repository failure yields [ProtectedMatchDecision.unknown] —
///    never a fabricated answer.
///
/// Pure Dart — the same matcher is used by the diagnostics screen and,
/// later, the lock engine. One shared instance lives on [AppContainer]
/// (wired to the same repository the Apps tab writes).
class ProtectedAppMatcher {
  ProtectedAppMatcher({
    required ProtectedAppsRepository repository,
    DateTime Function()? now,
  })  : _repository = repository,
        _now = now ?? DateTime.now;

  final ProtectedAppsRepository _repository;
  final DateTime Function() _now;

  /// Matches [packageName] against the protected list.
  Future<ProtectedMatch> match(String packageName) async {
    final String trimmed = packageName.trim();
    final DateTime at = _now();
    if (trimmed.isEmpty) {
      return ProtectedMatch(
        packageName: trimmed,
        decision: ProtectedMatchDecision.notProtected,
        at: at,
      );
    }
    final Result<bool> result = await _repository.isProtected(trimmed);
    if (result.isFailure) {
      return ProtectedMatch(
        packageName: trimmed,
        decision: ProtectedMatchDecision.unknown,
        at: at,
      );
    }
    return ProtectedMatch(
      packageName: trimmed,
      decision: result.valueOrNull == true
          ? ProtectedMatchDecision.protected
          : ProtectedMatchDecision.notProtected,
      at: at,
    );
  }

  /// Matches the package carried by a [ForegroundAppChange] — the direct
  /// wiring the lock engine will consume (5D+).
  Future<ProtectedMatch> matchChange(ForegroundAppChange change) =>
      match(change.packageName);
}
