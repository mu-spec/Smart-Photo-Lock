import '../data/models/app_security_level.dart';
import '../data/models/protected_app.dart';
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
    this.securityLevel = AppSecurityLevel.standard,
  });

  final String packageName;
  final ProtectedMatchDecision decision;

  /// When the decision was produced.
  final DateTime at;

  /// Phase 8 / M2: the app's stored level when [decision] is `protected`;
  /// [AppSecurityLevel.strictest] when the state is `unknown` (a failed
  /// read never yields a weaker policy); Standard (unused) otherwise.
  final AppSecurityLevel securityLevel;

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
    // Phase 8 / M2: one read gives both protection and the level.
    final Result<List<ProtectedApp>> result =
        await _repository.getProtectedApps();
    final List<ProtectedApp>? apps = result.valueOrNull;
    if (result.isFailure || apps == null) {
      return ProtectedMatch(
        packageName: trimmed,
        decision: ProtectedMatchDecision.unknown,
        at: at,
        securityLevel: AppSecurityLevel.strictest,
      );
    }
    for (final ProtectedApp app in apps) {
      if (app.packageName == trimmed) {
        return ProtectedMatch(
          packageName: trimmed,
          decision: ProtectedMatchDecision.protected,
          at: at,
          securityLevel: app.securityLevel,
        );
      }
    }
    return ProtectedMatch(
      packageName: trimmed,
      decision: ProtectedMatchDecision.notProtected,
      at: at,
    );
  }

  Future<ProtectedMatch> matchChange(ForegroundAppChange change) =>
      match(change.packageName);
}
