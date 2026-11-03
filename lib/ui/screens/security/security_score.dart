import '../../../data/models/app_security_level.dart';
import '../../../data/models/protected_app.dart';
import '../../../protection/health/protection_health_engine.dart';
import '../../../protection/security_level_policy.dart';

/// Phase 9 / M2 (PRD 9E) — the Security Score model.
///
/// ONE pure, deterministic and read-only calculator. It turns inputs that
/// production already observes into "setup points" (0–100), or into an
/// explicit non-score status. The weights are Smart App Lock's own
/// product-defined assessment weights. They are NOT measured or validated
/// risk probabilities, and the number is not the chance of resisting a
/// bypass. It is shown as "N / 100 points", never as a percentage.
///
/// Formula (see `docs/architecture.md`, "Security Score"):
///
///  * **F1 Protection health, 60 points:** fresh SECURE = 60;
///    ATTENTION REQUIRED = 0 and the score is [SecurityScoreStatus.provisional].
///    OFFLINE, stale or unknown health produce no score at all.
///  * **F2 Re-lock after leaving, 40 points:** `floor(10 × Σcredit / n)` over
///    the `n` protected apps. `credit` (0–4) comes from each app's effective
///    re-lock grace ([RelockTier]): `SecurityLevelPolicy.graceFor` applied to
///    the configured grace and to the app's CREDITED level. The credited
///    level is the less strict of the saved and native-confirmed levels, or
///    Standard when native has not confirmed one.
///
/// Not scored: app count, PIN vs pattern, biometrics, phone model, the
/// number of permissions, battery saver. Capability readiness counts only
/// through Protection Health, so one problem never costs points twice.
///
/// Boundary: nothing here authorizes, unlocks, creates grace, writes a
/// level or setting, resets lockout or touches a challenge.
abstract final class SecurityScore {
  /// Upper bound of the scale.
  static const int maxPoints = 100;

  /// F1: a fresh SECURE health check.
  static const int healthPoints = 60;

  /// F2: re-lock after leaving.
  static const int relockPoints = 40;

  /// Credit units per app in F2 (quarters).
  static const int maxCredit = 4;

  /// The level an app is credited with. A saved level that native has not
  /// confirmed earns no extra credit: native unknown → Standard; otherwise
  /// the LESS strict of [saved] and [native] (a pending downgrade counts at
  /// the lower saved level; an unconfirmed upgrade counts at native's).
  static AppSecurityLevel creditedLevel(
    AppSecurityLevel saved,
    AppSecurityLevel? native,
  ) {
    if (native == null) return AppSecurityLevel.standard;
    return saved.isStricterThan(native) ? native : saved;
  }

  /// F2 points for the given per-app credits (each 0–[maxCredit]).
  /// `floor(relockPoints × Σcredit / (maxCredit × n))`; 0 apps → 0.
  static int relockScoreOf(Iterable<int> credits) {
    int n = 0;
    int sum = 0;
    for (final int c in credits) {
      n++;
      sum += c.clamp(0, maxCredit);
    }
    if (n == 0) return 0;
    return (relockPoints * sum) ~/ (maxCredit * n);
  }

  /// Assesses [inputs]. The first matching rule wins (spec §4).
  static SecurityScoreAssessment assess(SecurityScoreInputs inputs) {
    // 1–2. The saved app list.
    if (inputs.appsState == ScoreSourceState.failed) {
      return const SecurityScoreAssessment._unavailable(
        ScoreUnavailableReason.appsUnreadable,
      );
    }
    if (inputs.appsState == ScoreSourceState.loading) {
      return const SecurityScoreAssessment._assessing();
    }

    final _Apps apps = _Apps.of(inputs.apps, inputs.nativeLevelFor);
    final ProtectionHealthReport? report = inputs.health;
    final bool? credential = report?.signals.credentialConfigured;

    // 3–4. Setup is not finished (never worded as a failure).
    if (apps.packages.isEmpty ||
        (report?.hasIssue(HealthIssueCode.protectionNotConfigured) ?? false)) {
      return SecurityScoreAssessment._setup(
        needsApps: apps.packages.isEmpty,
        needsCredential: credential == null ? null : !credential,
      );
    }

    // 5–6. The re-lock setting.
    if (inputs.graceState == ScoreSourceState.failed ||
        (inputs.graceState == ScoreSourceState.loaded &&
            inputs.grace == null)) {
      return const SecurityScoreAssessment._unavailable(
        ScoreUnavailableReason.settingsUnreadable,
      );
    }
    if (inputs.graceState == ScoreSourceState.loading) {
      return const SecurityScoreAssessment._assessing();
    }

    // 7–8. Protection Health must be known and fresh.
    if (report == null) {
      if (inputs.healthChecking) {
        return const SecurityScoreAssessment._assessing();
      }
      return SecurityScoreAssessment._unavailable(
        inputs.healthFailed
            ? ScoreUnavailableReason.healthFailed
            : ScoreUnavailableReason.healthNotChecked,
      );
    }
    if (report.stale) {
      return const SecurityScoreAssessment._unavailable(
        ScoreUnavailableReason.healthStale,
      );
    }

    // 9. No normal score while protection is offline.
    if (report.state == ProtectionHealthState.protectionOffline) {
      return const SecurityScoreAssessment._withheld();
    }

    // 10–11. A number: provisional (ATTENTION) or available (SECURE).
    final Duration grace = inputs.grace!.isNegative
        ? Duration.zero
        : inputs.grace!; // checked above
    final Map<RelockTier, int> tiers = <RelockTier, int>{
      for (final RelockTier t in RelockTier.values) t: 0,
    };
    final List<int> credits = <int>[];
    for (final _App app in apps.packages) {
      final RelockTier tier = RelockTier.of(
        SecurityLevelPolicy.graceFor(app.credited, grace),
      );
      tiers[tier] = tiers[tier]! + 1;
      credits.add(tier.credit);
    }
    final bool secure = report.state == ProtectionHealthState.secure;
    final int f1 = secure ? healthPoints : 0;
    final int f2 = relockScoreOf(credits);
    HealthIssue? topProblem;
    for (final HealthIssue issue in report.issues) {
      if (issue.severity != HealthIssueSeverity.advisory) {
        topProblem = issue;
        break;
      }
    }
    return SecurityScoreAssessment._scored(
      status: secure
          ? SecurityScoreStatus.available
          : SecurityScoreStatus.provisional,
      points: f1 + f2,
      healthEarned: f1,
      relockEarned: f2,
      appCount: apps.packages.length,
      tierCounts: Map<RelockTier, int>.unmodifiable(tiers),
      unconfirmedLevels: apps.unconfirmed,
      heldStricter: apps.heldStricter,
      topProblem: topProblem,
    );
  }
}

/// Load state of one score input.
enum ScoreSourceState { loading, loaded, failed }

/// What the Security Score section shows.
enum SecurityScoreStatus {
  /// An input is still loading or the first health check is running.
  assessing,

  /// An input could not be read, or health is unknown or out of date.
  unavailable,

  /// No protected apps or no credential yet (not a failure).
  setupNeeded,

  /// PROTECTION OFFLINE: no score is shown.
  withheldOffline,

  /// ATTENTION REQUIRED: a number with the health points at 0 and the
  /// remaining problems listed.
  provisional,

  /// Fresh SECURE health: a number.
  available;

  /// Whether a number is shown.
  bool get hasPoints =>
      this == SecurityScoreStatus.provisional ||
      this == SecurityScoreStatus.available;
}

/// Why no score is shown ([SecurityScoreStatus.unavailable]).
enum ScoreUnavailableReason {
  appsUnreadable,
  settingsUnreadable,
  healthFailed,
  healthNotChecked,
  healthStale,
}

/// F2 tiers by an app's effective re-lock grace after leaving it.
enum RelockTier {
  noDelay(4, Duration.zero),
  upTo15Seconds(3, Duration(seconds: 15)),
  upTo1Minute(2, Duration(minutes: 1)),
  upTo5Minutes(1, Duration(minutes: 5)),
  longer(0, null);

  const RelockTier(this.credit, this.limit);

  /// F2 credit units (of [SecurityScore.maxCredit]).
  final int credit;

  /// Inclusive upper bound of the effective grace (null: unbounded).
  final Duration? limit;

  static RelockTier of(Duration effectiveGrace) {
    for (final RelockTier t in values) {
      final Duration? limit = t.limit;
      if (limit == null || effectiveGrace <= limit) return t;
    }
    return RelockTier.longer;
  }
}

/// Everything the calculator reads. Built by the Security Center from the
/// same reads it already performs (no extra probes).
class SecurityScoreInputs {
  const SecurityScoreInputs({
    required this.appsState,
    this.apps = const <ProtectedApp>[],
    this.nativeLevelFor,
    required this.graceState,
    this.grace,
    this.health,
    this.healthChecking = false,
    this.healthFailed = false,
  });

  final ScoreSourceState appsState;

  /// Saved protected-app records (`ProtectedAppsRepository`), used only
  /// when [appsState] is loaded.
  final List<ProtectedApp> apps;

  /// Native-confirmed level per package (null = unknown).
  final AppSecurityLevel? Function(String packageName)? nativeLevelFor;

  final ScoreSourceState graceState;

  /// The configured re-lock grace, used only when [graceState] is loaded.
  final Duration? grace;

  /// The Phase 7 report with staleness already re-applied (the M1
  /// controller does this on every read). Null = no usable report.
  final ProtectionHealthReport? health;
  final bool healthChecking;
  final bool healthFailed;
}

/// The result. [points] and the factor values are non-null only when
/// [status] has points.
class SecurityScoreAssessment {
  const SecurityScoreAssessment._({
    required this.status,
    this.reason,
    this.points,
    this.healthEarned,
    this.relockEarned,
    this.appCount = 0,
    this.tierCounts = const <RelockTier, int>{},
    this.unconfirmedLevels = 0,
    this.heldStricter = 0,
    this.topProblem,
    this.needsApps = false,
    this.needsCredential,
  });

  const SecurityScoreAssessment._assessing()
      : this._(status: SecurityScoreStatus.assessing);

  const SecurityScoreAssessment._unavailable(ScoreUnavailableReason reason)
      : this._(status: SecurityScoreStatus.unavailable, reason: reason);

  const SecurityScoreAssessment._withheld()
      : this._(status: SecurityScoreStatus.withheldOffline);

  const SecurityScoreAssessment._setup({
    required bool needsApps,
    required bool? needsCredential,
  }) : this._(
          status: SecurityScoreStatus.setupNeeded,
          needsApps: needsApps,
          needsCredential: needsCredential,
        );

  const SecurityScoreAssessment._scored({
    required SecurityScoreStatus status,
    required int points,
    required int healthEarned,
    required int relockEarned,
    required int appCount,
    required Map<RelockTier, int> tierCounts,
    required int unconfirmedLevels,
    required int heldStricter,
    required HealthIssue? topProblem,
  }) : this._(
          status: status,
          points: points,
          healthEarned: healthEarned,
          relockEarned: relockEarned,
          appCount: appCount,
          tierCounts: tierCounts,
          unconfirmedLevels: unconfirmedLevels,
          heldStricter: heldStricter,
          topProblem: topProblem,
        );

  final SecurityScoreStatus status;
  final ScoreUnavailableReason? reason;

  /// F1 + F2 (0–100) when [status] has points.
  final int? points;

  /// F1 earned (of [SecurityScore.healthPoints]).
  final int? healthEarned;

  /// F2 earned (of [SecurityScore.relockPoints]).
  final int? relockEarned;

  /// Protected apps assessed (deduplicated).
  final int appCount;

  /// Apps per re-lock tier (scored statuses only).
  final Map<RelockTier, int> tierCounts;

  /// Apps whose saved level is stricter than native has confirmed; they
  /// are credited at the confirmed level (or Standard when unknown).
  final int unconfirmedLevels;

  /// Apps native still enforces at a stricter level than saved (a
  /// downgrade not confirmed yet); credited at the lower saved level.
  final int heldStricter;

  /// The first non-advisory health issue (ATTENTION REQUIRED). The UI
  /// names problems once, in the Protection Health card; this is the
  /// model-level record of what blocks the health points.
  final HealthIssue? topProblem;

  /// Setup: no protected apps yet.
  final bool needsApps;

  /// Setup: no credential yet (null = not known).
  final bool? needsCredential;

  /// Points below the maximum (scored statuses only).
  int? get pointsLost =>
      points == null ? null : SecurityScore.maxPoints - points!;
}

class _App {
  const _App(this.credited);
  final AppSecurityLevel credited;
}

/// Deduplicated apps (the M1 summary's rules: first record per package
/// wins; blank package names are ignored) with credited levels.
class _Apps {
  const _Apps(this.packages, this.unconfirmed, this.heldStricter);

  factory _Apps.of(
    List<ProtectedApp> records,
    AppSecurityLevel? Function(String packageName)? nativeLevelFor,
  ) {
    final Set<String> seen = <String>{};
    final List<_App> apps = <_App>[];
    int unconfirmed = 0;
    int held = 0;
    for (final ProtectedApp app in records) {
      final String pkg = app.packageName.trim();
      if (pkg.isEmpty || !seen.add(pkg)) continue;
      final AppSecurityLevel saved = app.securityLevel;
      final AppSecurityLevel? native = nativeLevelFor?.call(pkg);
      final AppSecurityLevel credited =
          SecurityScore.creditedLevel(saved, native);
      if (saved.isStricterThan(credited)) unconfirmed++;
      if (native != null && native.isStricterThan(saved)) held++;
      apps.add(_App(credited));
    }
    return _Apps(apps, unconfirmed, held);
  }

  final List<_App> packages;
  final int unconfirmed;
  final int heldStricter;
}
