import '../data/models/app_security_level.dart';
import '../utilities/result.dart';
import 'pending_lock_challenge.dart';

enum ProtectionEngineState { inactive, healthy, recovering, unavailable }

class ProtectionEngineHealth {
  const ProtectionEngineHealth({
    required this.protectionConfigured,
    required this.serviceRunning,
    required this.engineState,
    required this.notificationPermissionGranted,
    this.lastError,
    this.accessibilityServiceConnected,
    this.shieldArmed,
    this.challengePending,
    this.backgroundRestricted,
    this.powerSaveMode,
    this.ignoringBatteryOptimizations,
    this.sdkInt,
  });

  const ProtectionEngineHealth.inactive()
      : protectionConfigured = false,
        serviceRunning = false,
        engineState = ProtectionEngineState.inactive,
        notificationPermissionGranted = true,
        lastError = null,
        accessibilityServiceConnected = null,
        shieldArmed = null,
        challengePending = null,
        backgroundRestricted = null,
        powerSaveMode = null,
        ignoringBatteryOptimizations = null,
        sdkInt = null;

  factory ProtectionEngineHealth.fromMap(Map<dynamic, dynamic> map) {
    final String rawState = map['engineState'] as String? ?? 'unavailable';
    return ProtectionEngineHealth(
      protectionConfigured: map['protectionConfigured'] as bool? ?? false,
      serviceRunning: map['serviceRunning'] as bool? ?? false,
      engineState: ProtectionEngineState.values.firstWhere(
        (ProtectionEngineState state) => state.name == rawState,
        orElse: () => ProtectionEngineState.unavailable,
      ),
      notificationPermissionGranted:
          map['notificationPermissionGranted'] as bool? ?? true,
      lastError: map['lastError'] as String?,
      accessibilityServiceConnected: _optionalBool(
        map['accessibilityServiceConnected'],
      ),
      shieldArmed: _optionalBool(map['shieldArmed']),
      challengePending: _optionalBool(map['challengePending']),
      backgroundRestricted: _optionalBool(map['backgroundRestricted']),
      powerSaveMode: _optionalBool(map['powerSaveMode']),
      ignoringBatteryOptimizations: _optionalBool(
        map['ignoringBatteryOptimizations'],
      ),
      sdkInt: map['sdkInt'] is int ? map['sdkInt'] as int : null,
    );
  }

  /// Phase 7 / M1: an absent or malformed signal is UNKNOWN (null), never
  /// a fabricated healthy value.
  static bool? _optionalBool(Object? value) => value is bool ? value : null;

  final bool protectionConfigured;
  final bool serviceRunning;
  final ProtectionEngineState engineState;
  final bool notificationPermissionGranted;
  final String? lastError;

  // Phase 7 / M1 — additive, observational health signals (null = UNKNOWN:
  // unsupported API level, a failed platform read, or an older native build).

  /// Android currently has the detection Accessibility service BOUND
  /// (distinct from "enabled in Settings").
  final bool? accessibilityServiceConnected;

  /// The pre-armed native shield window is attached.
  final bool? shieldArmed;

  /// A native pending challenge ticket exists (enforcement in progress).
  final bool? challengePending;

  /// `ActivityManager.isBackgroundRestricted()` (API 28+). OEM power
  /// managers are not reflected by this API.
  final bool? backgroundRestricted;

  /// `PowerManager.isPowerSaveMode()` (Battery Saver).
  final bool? powerSaveMode;

  /// `PowerManager.isIgnoringBatteryOptimizations()` for this app.
  final bool? ignoringBatteryOptimizations;

  /// `Build.VERSION.SDK_INT` reported by native code.
  final int? sdkInt;
}

/// Phase 7 / M2: the only Android Settings screens the health dashboard
/// may open directly (native allowlist `ProtectionSettingsTargets`).
/// Overlay, Accessibility and Usage Access use their existing setup screens.
enum ProtectionSettingsTarget {
  /// This app's notification settings (App info below API 26).
  notifications('notifications'),

  /// This app's App info screen (battery / background controls live here).
  appDetails('app_details'),

  /// The system Battery Saver screen.
  batterySaver('battery_saver');

  const ProtectionSettingsTarget(this.id);

  /// Wire identifier sent to native code.
  final String id;
}

/// Bridge to the native lifecycle and recovery watcher.
///
/// Native code owns the earliest detector-to-shield transition even while
/// Dart is healthy. Dart owns credential decisions and grants only the
/// short-lived package authorization produced by successful authentication.
/// Phase 8 / M2: the per-app level part of one protection snapshot, sent
/// with the protected set in the same `configureProtection` call (one
/// atomic native write). [levels] keys are exactly the protected packages.
class ProtectionPolicySnapshot {
  const ProtectionPolicySnapshot({
    required this.levels,
    required this.session,
    required this.revision,
    this.authorizedDowngrades = const <String>{},
    this.smartRules,
    this.authorizedRuleRelaxation = false,
  });

  /// Transport schema version understood by native (`policyVersion`).
  static const int currentVersion = 1;

  final Map<String, AppSecurityLevel> levels;

  /// Identifies one Dart isolate; with [revision] lets native reject a
  /// stale or out-of-order snapshot.
  final String session;
  final int revision;

  /// Packages whose LOWER level was confirmed through the CR-2 credential
  /// gate just before this snapshot. Native applies a downgrade only for
  /// these; any other lower level is held at the stricter one.
  final Set<String> authorizedDowngrades;

  /// Phase 10 / M2: the raise-only rule specs native enforces
  /// (`SmartRulePolicy.nativeTransport`). Null = not sent: native keeps the
  /// rules it last persisted (the Dart rule document could not be read, so
  /// nothing may be relaxed by omission). An empty list = no raising rules.
  final List<Map<String, Object?>>? smartRules;

  /// Phase 10 / M2: true only for the one snapshot sent right after a rule
  /// change that REDUCES rule strictness was confirmed through the CR-2
  /// credential gate. Without it native holds the stricter union of its
  /// previous and the new rules.
  final bool authorizedRuleRelaxation;

  Map<String, Object?> toChannelArguments() => <String, Object?>{
        'policyVersion': currentVersion,
        'securityLevels': <String, String>{
          for (final MapEntry<String, AppSecurityLevel> e in levels.entries)
            e.key: e.value.storageId,
        },
        'snapshotSession': session,
        'snapshotRevision': revision,
        'authorizedDowngrades': authorizedDowngrades.toList(growable: false),
        if (smartRules != null) ...<String, Object?>{
          'smartRulesVersion': 1,
          'smartRules': smartRules,
          'authorizedRuleRelaxation': authorizedRuleRelaxation,
        },
      };
}

/// Phase 10 / M2: how native treated the Smart Rules part of a snapshot.
enum SmartRuleSyncStatus {
  /// The sent rules are the ones native enforces.
  applied,

  /// The sent rules REDUCE strictness without a CR-2 confirmation: native
  /// enforces the stricter union of its previous and the new rules.
  held,

  /// No rules were sent: native kept the rules it had persisted.
  kept,

  /// The rule data was malformed: native kept its previous rules.
  invalid,

  /// Native did not report (older reply format or no reply).
  unknown,
}

/// Phase 10 / M3 (PRD 10K): read-only record of the LATEST native exchange
/// about Smart Rules in this process, used only by diagnostics to tell a
/// calculated level from a native confirmation.
///
/// [sentRules] is the exact rule transport of that exchange (null = no
/// rules were sent because the rule read failed). [failed] = the
/// `configureProtection` call itself failed (bridge error or a
/// `persisted=false` reply), so native's state is not known from it.
/// Nothing reads this record to make an access decision.
final class SmartRuleNativeRecord {
  const SmartRuleNativeRecord({
    required this.status,
    required this.sentRules,
    this.failed = false,
    this.sentProfileOverlay,
    this.sentActivationOverlay,
  });

  /// Native's treatment of the rules ([SmartRuleSyncStatus.unknown] for a
  /// failed call).
  final SmartRuleSyncStatus status;

  /// The Smart Rules part of the transport sent
  /// (`SmartRulePolicy.nativeTransport` of the saved rules), or null.
  final List<Map<String, Object?>>? sentRules;

  final bool failed;

  /// Phase 11 / M1: the active-profile overlay part sent in the SAME
  /// transport (`SecurityProfilePolicy.overlayRules`, canonical form); empty
  /// for Normal, null when no transport was sent. Diagnostics only.
  final List<Map<String, Object?>>? sentProfileOverlay;

  /// Phase 11 / M3: the overlays of "Apply profile" rules sent in the SAME
  /// transport (`SecurityProfilePolicy.activationRules`, canonical form,
  /// with each rule's days and time); empty when there are none, null when
  /// no transport was sent. Diagnostics only.
  final List<Map<String, Object?>>? sentActivationOverlay;

  @override
  String toString() => 'SmartRuleNativeRecord(${status.name}, '
      'sent=${sentRules == null ? 'none' : sentRules!.length}, '
      'profile=${sentProfileOverlay == null ? 'none' : sentProfileOverlay!.length}, '
      'failed=$failed)';
}

/// How native treated the level part of a snapshot.
enum ProtectionPolicyStatus {
  /// Valid snapshot applied (possibly with held downgrades).
  applied,

  /// No level data was sent (legacy transport): known levels kept.
  legacy,

  /// Level data present but malformed: every app enforced as Critical.
  invalid,

  /// Older than one already applied: nothing changed.
  stale,

  /// Native did not report (e.g. an older reply format).
  unknown,
}

/// Phase 8 / M2: native's reply to `configureProtection`, used to show the
/// truth when persisted and enforced levels differ.
class ProtectionPolicyAck {
  const ProtectionPolicyAck({
    required this.status,
    this.effectiveLevels = const <String, AppSecurityLevel>{},
    this.heldDowngrades = const <String>{},
    this.ruleStatus = SmartRuleSyncStatus.unknown,
  });

  static const ProtectionPolicyAck unknown =
      ProtectionPolicyAck(status: ProtectionPolicyStatus.unknown);

  final ProtectionPolicyStatus status;

  /// The level native enforces per protected package (empty = unknown).
  final Map<String, AppSecurityLevel> effectiveLevels;

  /// Packages whose requested lower level native did NOT apply.
  final Set<String> heldDowngrades;

  /// Phase 10 / M2: native's treatment of the Smart Rules part.
  final SmartRuleSyncStatus ruleStatus;

  bool get applied =>
      status != ProtectionPolicyStatus.stale &&
      status != ProtectionPolicyStatus.unknown;

  /// Parses the native reply. Anything unreadable is [unknown]; an
  /// unreadable level id reads as Critical (never weaker).
  static ProtectionPolicyAck fromChannel(Object? raw) {
    if (raw is! Map) return unknown;
    final Object? statusRaw = raw['policyStatus'];
    final ProtectionPolicyStatus status = ProtectionPolicyStatus.values
            .where((ProtectionPolicyStatus s) =>
                s != ProtectionPolicyStatus.unknown && s.name == statusRaw)
            .firstOrNull ??
        ProtectionPolicyStatus.unknown;
    final Object? levelsRaw = raw['effectiveLevels'];
    final Map<String, AppSecurityLevel> levels = <String, AppSecurityLevel>{
      if (levelsRaw is Map)
        for (final MapEntry<Object?, Object?> e in levelsRaw.entries)
          if (e.key is String)
            e.key! as String: AppSecurityLevel.fromStorage(e.value),
    };
    final Object? heldRaw = raw['heldDowngrades'];
    final Object? ruleRaw = raw['ruleStatus'];
    return ProtectionPolicyAck(
      ruleStatus: SmartRuleSyncStatus.values
              .where((SmartRuleSyncStatus s) =>
                  s != SmartRuleSyncStatus.unknown && s.name == ruleRaw)
              .firstOrNull ??
          SmartRuleSyncStatus.unknown,
      status: status,
      effectiveLevels: levels,
      heldDowngrades: <String>{
        if (heldRaw is List)
          for (final Object? p in heldRaw)
            if (p is String) p,
      },
    );
  }
}

abstract interface class WatcherService {
  /// Starts the watcher foreground service. Notification permission is
  /// optional on API 33+: denial affects visibility, not service startup.
  Future<Result<bool>> start();

  /// Stops the watcher foreground service.
  Future<Result<bool>> stop();

  /// The native watcher's running state.
  Future<Result<bool>> isRunning();

  /// Persists the minimum non-secret bootstrap state needed by the native
  /// recovery engine. Package names are already persisted by the protected
  /// apps repository; no credential material crosses this bridge.
  ///
  /// Phase 8 / M2: [policy] carries the per-app levels of the same
  /// snapshot (null = legacy call: native keeps the levels it knows). The
  /// reply reports what native enforces.
  Future<Result<ProtectionPolicyAck>> configureProtection({
    required bool enabled,
    required Set<String> protectedPackages,
    ProtectionPolicySnapshot? policy,
  });

  /// Liveness signal from the Dart enforcement pipeline. The native watcher
  /// falls back to recovery detection when heartbeats stop.
  Future<Result<void>> heartbeat();

  /// Synchronizes the immediate/grace re-lock policy used by native early
  /// enforcement. No credential material crosses this boundary.
  Future<Result<void>> setGracePeriod(Duration period);

  /// Mirrors a temporary package authorization after explicit successful
  /// authentication. Native state is process-local and disappears on reboot
  /// or process death, preserving fail-closed recovery.
  ///
  /// Phase 8 / M2 gate: [securityLevel] is the level Dart enforced for this
  /// grant. Native keeps it as a floor for the authorization's lifetime
  /// (stricter of it and the native store level), so a native store that has
  /// not yet received the first level sync (M1 → M2 upgrade, failed sync)
  /// cannot give a Critical/Sensitive grant Standard grace. It can only
  /// tighten; it never authorizes.
  Future<Result<void>> authorizePackage(
    PendingLockChallenge challenge, {
    Duration sessionWindow = const Duration(minutes: 2),
    AppSecurityLevel? securityLevel,
  });

  /// Immediately invalidates every native authorization (screen-off path).
  Future<Result<void>> revokeAllAuthorizations();

  /// Marks an orderly Flutter-engine teardown. This never disables desired
  /// protection; it hands enforcement back to the native recovery watcher.
  Future<Result<void>> markEngineUnavailable();

  /// Reads a package queued by native recovery after process death/reboot.
  /// The native shield latch remains set until the rendered challenge handoff.
  Future<Result<PendingLockChallenge?>> takePendingChallenge();

  /// Current native enforcement health for truthful baseline UI.
  Future<Result<ProtectionEngineHealth>> getHealth();

  /// Phase 7 / M2: opens one allowlisted Android Settings screen after an
  /// explicit user tap. Resolves `true` when Android started the screen.
  /// Grants nothing and changes no protection state; only fresh health
  /// signals can show whether the user changed the setting.
  Future<Result<bool>> openProtectionSettings(ProtectionSettingsTarget target);
}
