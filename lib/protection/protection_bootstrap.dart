import 'dart:async';
import 'dart:math';

import '../data/models/app_security_level.dart';
import '../data/models/protected_app.dart';
import '../data/repositories/protected_apps_repository.dart';
import '../data/repositories/security_profile_repository.dart';
import '../data/repositories/smart_rule_repository.dart';
import '../profiles/security_profile.dart';
import '../profiles/security_profile_policy.dart';
import '../rules/smart_rule.dart';
import '../rules/smart_rule_policy.dart';
import '../security/credentials/credential_manager.dart';
import '../services/watcher_service.dart';
import '../utilities/result.dart';

class ProtectionBootstrapResult {
  const ProtectionBootstrapResult({
    required this.configured,
    required this.health,
    this.policyAck = ProtectionPolicyAck.unknown,
  });

  final bool configured;
  final ProtectionEngineHealth health;

  /// Phase 10 / M2: native's acknowledgement of THIS call's snapshot
  /// ([ProtectionPolicyAck.unknown] when native did not report). Callers
  /// use it, never an earlier ack, before claiming a change is enforced.
  final ProtectionPolicyAck policyAck;
}

/// Synchronizes authoritative Dart persistence into the minimal native
/// bootstrap store used after process death and reboot.
///
/// A repository/decryption failure never overwrites a previously enabled
/// native configuration. That preserves fail-closed recovery instead of
/// converting an unreadable security state into "protection disabled".
///
/// Phase 8 / M2: each call sends ONE snapshot (packages + per-app levels,
/// atomically written natively) tagged with this isolate's [session] and an
/// increasing revision, so native ignores a stale/out-of-order one. Calls
/// are serialized. The last native acknowledgement is kept so the app can
/// tell when native enforces a different (stricter) level than persisted.
///
/// Phase 10 / M2: the same snapshot carries the raise-only Smart Rules
/// (`SmartRulePolicy.nativeTransport`), read from [SmartRuleRepository]
/// inside the serialized call. A failed, corrupt or unsupported rule read
/// sends NO rules, so native keeps the rules it last persisted (nothing is
/// relaxed by an unreadable document) and the in-memory
/// [SmartRuleEnforcementCache] keeps its last good copy.
///
/// Phase 11 / M1: the active Security Profile's raise-only overlay travels
/// in the SAME `smartRules` transport ([SecurityProfilePolicy.nativeTransport]
/// = saved rules + overlay as all-day raising entries). If EITHER the rules
/// or the profile document cannot be read, NO rules are sent (native keeps
/// its persisted combined set) and the failed cache reports not current, so
/// the access controller applies the R-A Critical floor. With Normal active
/// (every user in M1) the transport equals the rules-only transport.
class ProtectionBootstrap {
  ProtectionBootstrap({
    required ProtectedAppsRepository protectedApps,
    required CredentialManager credentials,
    required WatcherService watcher,
    String? session,
    SmartRuleRepository? smartRules,
    SmartRuleEnforcementCache? ruleCache,
    SecurityProfileRepository? profiles,
  })  : _protectedApps = protectedApps,
        _credentials = credentials,
        _watcher = watcher,
        _smartRules = smartRules,
        _profiles = profiles,
        ruleCache = ruleCache ?? SmartRuleEnforcementCache(),
        profileCache = profiles == null
            ? SecurityProfileEnforcementCache.normalOnly()
            : SecurityProfileEnforcementCache(),
        session = session ?? _newSession();

  final ProtectedAppsRepository _protectedApps;
  final CredentialManager _credentials;
  final WatcherService _watcher;
  final SmartRuleRepository? _smartRules;
  final SecurityProfileRepository? _profiles;

  /// Phase 10 / M2: last successfully read rules (Dart-side enforcement).
  final SmartRuleEnforcementCache ruleCache;

  /// Phase 11 / M1: last successfully read active profile (Dart-side
  /// enforcement). Normal and current when no profile repository is wired.
  final SecurityProfileEnforcementCache profileCache;

  /// Phase 11 / M1: the error of the last profile read, or null.
  Object? get lastProfileReadError => _lastProfileReadError;
  Object? _lastProfileReadError;

  /// Phase 11 / M1: the extra (rules + active profile) level the Dart floor
  /// requires for [packageName] at [now]; never lowers anything. The profile
  /// part mirrors the compiled overlay last sent to native: "all protected
  /// apps" covers only the protected set of that snapshot.
  AppSecurityLevel? extraLevelFor(String packageName, DateTime now) {
    final AppSecurityLevel? rule = ruleCache.levelFor(packageName, now);
    final AppSecurityLevel? profile = SecurityProfilePolicy.transportLevelFor(
      profileCache.active,
      packageName,
      _overlayPackages,
    );
    if (rule == null) return profile;
    if (profile == null) return rule;
    return profile.isStricterThan(rule) ? profile : rule;
  }

  /// The protected set the last sent overlay was compiled for.
  Set<String> _overlayPackages = const <String>{};

  /// R-A (extended in Phase 11 / M1): true only while BOTH the latest rule
  /// read and the latest profile read succeeded.
  bool get extraLevelsCurrent => ruleCache.current && profileCache.current;

  /// Phase 10 / M2: the error of the last rule read, or null when it
  /// succeeded (or no rule repository is wired).
  Object? get lastRuleReadError => _lastRuleReadError;
  Object? _lastRuleReadError;

  /// Random per-instance id of the snapshot stream (not a secret).
  final String session;
  int _revision = 0;
  Future<void> _tail = Future<void>.value();
  ProtectionPolicyAck? _lastAck;

  static String _newSession() {
    final Random random = Random.secure();
    return List<String>.generate(
      4,
      (_) => random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0'),
    ).join();
  }

  /// The last applied native acknowledgement (null until one succeeds).
  ProtectionPolicyAck? get lastPolicyAck => _lastAck;

  /// Phase 10 / M3 (10K): the latest native exchange about Smart Rules in
  /// this process (null before the first `configureProtection` call).
  /// Diagnostics only; never used for an access decision.
  SmartRuleNativeRecord? get lastRuleExchange => _lastRuleExchange;
  SmartRuleNativeRecord? _lastRuleExchange;

  /// Phase 8 / M2: the level native last confirmed it enforces for
  /// [packageName], or null when unknown. Used as a floor: the effective
  /// Dart level is never weaker than this.
  AppSecurityLevel? nativeLevelFor(String packageName) =>
      _lastAck?.effectiveLevels[packageName];

  /// Sends the current persisted state to native. [authorizedDowngrades]
  /// lists packages whose lower level was JUST confirmed through the CR-2
  /// credential gate; native holds any other lower level.
  ///
  /// Phase 10 / M2: [authorizedRuleRelaxation] is true only right after a
  /// rule change that reduces rule strictness was confirmed through the
  /// CR-2 gate; it applies to this one snapshot only.
  Future<Result<ProtectionBootstrapResult>> synchronize({
    Set<String> authorizedDowngrades = const <String>{},
    bool authorizedRuleRelaxation = false,
  }) {
    final Future<void> previous = _tail;
    final Completer<void> done = Completer<void>();
    _tail = done.future;
    return previous
        .then(
          (_) => _synchronize(authorizedDowngrades, authorizedRuleRelaxation),
        )
        .whenComplete(done.complete);
  }

  /// Phase 10 / M2: the saved rules for this snapshot, or null (= send
  /// nothing; native keeps its persisted rules) when no repository is wired
  /// or the read failed.
  Future<List<SmartRule>?> _readRules() async {
    final SmartRuleRepository? repository = _smartRules;
    if (repository == null) return null;
    final Result<List<SmartRule>> read = await repository.getRules();
    final List<SmartRule>? rules = read.valueOrNull;
    if (read.isFailure || rules == null) {
      _lastRuleReadError = read.errorOrNull ?? StateError('No rules read.');
      ruleCache.markReadFailed();
      return null;
    }
    _lastRuleReadError = null;
    ruleCache.update(rules);
    return rules;
  }

  /// Phase 11 / M1: the active profile for this snapshot; Normal when no
  /// repository is wired; null when the read failed (send nothing).
  Future<SecurityProfile?> _readActiveProfile() async {
    final SecurityProfileRepository? repository = _profiles;
    if (repository == null) {
      return SecurityProfile.preset(SecurityProfileKind.normal);
    }
    final Result<SecurityProfileSet> read = await repository.getProfiles();
    final SecurityProfileSet? set = read.valueOrNull;
    if (read.isFailure || set == null) {
      _lastProfileReadError =
          read.errorOrNull ?? StateError('No profiles read.');
      profileCache.markReadFailed();
      return null;
    }
    _lastProfileReadError = null;
    profileCache.update(set);
    return set.active;
  }

  Future<Result<ProtectionBootstrapResult>> _synchronize(
    Set<String> authorizedDowngrades,
    bool authorizedRuleRelaxation,
  ) async {
    final credentialResult = await _credentials.status();
    if (credentialResult.isFailure) {
      return Result.failure(credentialResult.errorOrNull!);
    }
    final appsResult = await _protectedApps.getProtectedApps();
    if (appsResult.isFailure) {
      return Result.failure(appsResult.errorOrNull!);
    }
    final List<ProtectedApp> apps = appsResult.valueOrNull!;
    final packages = apps.map((app) => app.packageName).toSet();
    final bool configured =
        credentialResult.valueOrNull!.hasAnyCredential && packages.isNotEmpty;
    final List<SmartRule>? savedRules = await _readRules();
    final SecurityProfile? profile = await _readActiveProfile();
    // Phase 11 / M1: one transport (rules + profile overlay), or nothing at
    // all when either part is unknown.
    final bool send = savedRules != null && profile != null;
    if (send) _overlayPackages = Set<String>.unmodifiable(packages);
    final List<Map<String, Object?>>? rules = send
        ? SecurityProfilePolicy.nativeTransport(savedRules, profile, packages)
        : null;
    final List<Map<String, Object?>>? rulePart =
        send ? SmartRulePolicy.nativeTransport(savedRules) : null;
    final List<Map<String, Object?>>? profilePart = send
        ? SmartRulePolicy.nativeTransport(
            SecurityProfilePolicy.overlayRules(profile, packages),
          )
        : null;
    final configuredResult = await _watcher.configureProtection(
      enabled: configured,
      protectedPackages: packages,
      policy: ProtectionPolicySnapshot(
        levels: <String, AppSecurityLevel>{
          for (final ProtectedApp app in apps)
            app.packageName: app.securityLevel,
        },
        session: session,
        revision: ++_revision,
        authorizedDowngrades: authorizedDowngrades.intersection(packages),
        smartRules: rules,
        authorizedRuleRelaxation: rules != null && authorizedRuleRelaxation,
      ),
    );
    if (configuredResult.isFailure) {
      _lastRuleExchange = SmartRuleNativeRecord(
        status: SmartRuleSyncStatus.unknown,
        sentRules: rulePart,
        failed: true,
        sentProfileOverlay: profilePart,
      );
      return Result.failure(configuredResult.errorOrNull!);
    }
    final ProtectionPolicyAck ack = configuredResult.valueOrNull!;
    _lastRuleExchange = SmartRuleNativeRecord(
      status: ack.ruleStatus,
      sentRules: rulePart,
      sentProfileOverlay: profilePart,
    );
    if (ack.status != ProtectionPolicyStatus.unknown) _lastAck = ack;
    final running = await _watcher.isRunning();
    if (running.isFailure) {
      return Result.failure(running.errorOrNull!);
    }
    Result<bool>? lifecycle;
    if (configured && running.valueOrNull != true) {
      lifecycle = await _watcher.start();
    } else if (!configured && running.valueOrNull == true) {
      lifecycle = await _watcher.stop();
    }
    if (lifecycle != null &&
        (lifecycle.isFailure || lifecycle.valueOrNull != true)) {
      return Result.failure(
        lifecycle.errorOrNull ?? StateError('Watcher lifecycle failed.'),
      );
    }
    if (configured) {
      final heartbeat = await _watcher.heartbeat();
      if (heartbeat.isFailure) {
        return Result.failure(heartbeat.errorOrNull!);
      }
    }
    final health = await _watcher.getHealth();
    if (health.isFailure) {
      return Result.failure(health.errorOrNull!);
    }
    return Result.success(
      ProtectionBootstrapResult(
        configured: configured,
        health: health.valueOrNull!,
        policyAck: ack,
      ),
    );
  }
}
