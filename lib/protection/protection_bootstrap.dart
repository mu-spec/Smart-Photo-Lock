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
import 'bound_relaxation.dart';

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
  ///
  /// Phase 11 / M3: plus the overlays activated by matching "Apply profile"
  /// rules at [now] (compiled against the cached profile set and the same
  /// protected set, exactly as last sent).
  AppSecurityLevel? extraLevelFor(String packageName, DateTime now) {
    final AppSecurityLevel? rule = ruleCache.levelFor(packageName, now);
    final AppSecurityLevel? profile = SecurityProfilePolicy.transportLevelFor(
      profileCache.active,
      packageName,
      _overlayPackages,
    );
    final AppSecurityLevel? scheduled =
        SecurityProfilePolicy.activationLevelFor(
      ruleCache.rules,
      profileCache.set,
      packageName,
      now,
      _overlayPackages,
    );
    AppSecurityLevel? best;
    for (final AppSecurityLevel? level in <AppSecurityLevel?>[
      rule,
      profile,
      scheduled,
    ]) {
      if (level != null && (best == null || level.isStricterThan(best))) {
        best = level;
      }
    }
    return best;
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
  /// Phase 11 / M2: this NEVER sets the native rule relaxation flag. A
  /// reduction of rule or profile protection goes through
  /// [applyBoundRelaxation] only (the broad Phase 10 parameter was removed
  /// so no caller can send the flag for whatever happens to be stored).
  Future<Result<ProtectionBootstrapResult>> synchronize({
    Set<String> authorizedDowngrades = const <String>{},
  }) =>
      _serialized(() => _synchronize(authorizedDowngrades));

  Future<T> _serialized<T>(Future<T> Function() action) {
    final Future<void> previous = _tail;
    final Completer<void> done = Completer<void>();
    _tail = done.future;
    return previous.then((_) => action()).whenComplete(done.complete);
  }

  /// Phase 11 / M2: the ONLY way to send the native rule relaxation flag.
  /// See `bound_relaxation.dart` for the protocol. Runs entirely inside the
  /// serialized queue, so no other snapshot can interleave.
  ///
  /// The operation's captured state: [rulesBefore]/[rulesAfter] and
  /// [profilesBefore]/[profilesAfter]. A null pair means "unchanged by this
  /// operation"; the stored value read inside the section is used for both
  /// sides. Storage must equal the BEFORE side ([storageHoldsAfter] false:
  /// [commit] persists the change only after native applied it) or the
  /// AFTER side ([storageHoldsAfter] true: the Phase 10 write-first rule
  /// path and [BoundRelaxationIntent.confirmSaved]).
  ///
  /// [authorize] must consume the operation's proof for exactly the packages
  /// it is given (the relaxed set computed here) and return whether it did.
  /// It is called at most once, before any snapshot is sent.
  Future<BoundRelaxationResult> applyBoundRelaxation({
    required BoundRelaxationIntent intent,
    required bool Function(Set<String> packages) authorize,
    List<SmartRule>? rulesBefore,
    List<SmartRule>? rulesAfter,
    SecurityProfileSet? profilesBefore,
    SecurityProfileSet? profilesAfter,
    bool storageHoldsAfter = false,
    Future<Result<void>> Function()? commit,
  }) {
    assert((rulesBefore == null) == (rulesAfter == null));
    assert((profilesBefore == null) == (profilesAfter == null));
    assert(commit == null || !storageHoldsAfter);
    return _serialized(
      () => _applyBound(
        intent: intent,
        authorize: authorize,
        rulesBefore: rulesBefore,
        rulesAfter: rulesAfter,
        profilesBefore: profilesBefore,
        profilesAfter: profilesAfter,
        storageHoldsAfter: storageHoldsAfter,
        commit: commit,
      ),
    );
  }

  Future<BoundRelaxationResult> _applyBound({
    required BoundRelaxationIntent intent,
    required bool Function(Set<String> packages) authorize,
    required List<SmartRule>? rulesBefore,
    required List<SmartRule>? rulesAfter,
    required SecurityProfileSet? profilesBefore,
    required SecurityProfileSet? profilesAfter,
    required bool storageHoldsAfter,
    required Future<Result<void>> Function()? commit,
  }) async {
    // 1. Re-read everything. Any unreadable part: nothing is sent.
    final credentialResult = await _credentials.status();
    final appsResult = await _protectedApps.getProtectedApps();
    if (credentialResult.isFailure || appsResult.isFailure) {
      return BoundRelaxationResult(
        BoundRelaxationStatus.unavailable,
        error: credentialResult.errorOrNull ?? appsResult.errorOrNull,
      );
    }
    final List<ProtectedApp> apps = appsResult.valueOrNull!;
    final List<SmartRule>? storedRules = await _readRules();
    final SecurityProfileSet? storedProfiles = await _readProfileSet();
    if (storedRules == null || storedProfiles == null) {
      return BoundRelaxationResult(
        BoundRelaxationStatus.unavailable,
        error: _lastRuleReadError ?? _lastProfileReadError,
      );
    }
    final List<SmartRule>? expectedRules =
        storageHoldsAfter ? rulesAfter : rulesBefore;
    final SecurityProfileSet? expectedProfiles =
        storageHoldsAfter ? profilesAfter : profilesBefore;
    if ((expectedRules != null && !_sameRules(storedRules, expectedRules)) ||
        (expectedProfiles != null && storedProfiles != expectedProfiles)) {
      return const BoundRelaxationResult(BoundRelaxationStatus.conflict);
    }
    final _BoundState before = _BoundState(
      rulesBefore ?? storedRules,
      profilesBefore ?? storedProfiles,
    );
    final _BoundState after = _BoundState(
      rulesAfter ?? storedRules,
      profilesAfter ?? storedProfiles,
    );
    final Set<String> packages =
        apps.map((ProtectedApp app) => app.packageName).toSet();
    final bool configured =
        credentialResult.valueOrNull!.hasAnyCredential && packages.isNotEmpty;

    // 2. The relaxed packages, over the full weekly schedule.
    final Set<String> relaxed = intent == BoundRelaxationIntent.confirmSaved
        ? packages
        : SmartRulePolicy.relaxedPackages(
            before.combined(packages),
            after.combined(packages),
          );
    if (relaxed.isEmpty) {
      // Nothing to relax: no proof is consumed and no flag is sent.
      if (commit != null) {
        final Result<void> committed = await commit();
        if (committed.isFailure) {
          return BoundRelaxationResult(
            BoundRelaxationStatus.conflict,
            error: committed.errorOrNull,
          );
        }
        await _readProfileSet();
      }
      final Result<ProtectionPolicyAck> sent =
          await _sendBound(apps, configured, after, flag: false);
      return BoundRelaxationResult(
        switch (sent.valueOrNull?.ruleStatus) {
          SmartRuleSyncStatus.applied => BoundRelaxationStatus.applied,
          SmartRuleSyncStatus.held => BoundRelaxationStatus.held,
          _ => BoundRelaxationStatus.unconfirmed,
        },
        error: sent.errorOrNull,
      );
    }

    // 3. The proof, for exactly these packages, once.
    if (!authorize(Set<String>.unmodifiable(relaxed))) {
      return const BoundRelaxationResult(BoundRelaxationStatus.denied);
    }

    // 4. Probe: native must hold exactly expected-before. confirmSaved is
    // by definition used while native holds something else (held), and is
    // bound to the displayed saved state instead.
    if (intent != BoundRelaxationIntent.confirmSaved) {
      final Result<ProtectionPolicyAck> probe =
          await _sendBound(apps, configured, before, flag: false);
      if (probe.isFailure) {
        return BoundRelaxationResult(
          BoundRelaxationStatus.unknown,
          error: probe.errorOrNull,
        );
      }
      if (probe.valueOrNull!.ruleStatus != SmartRuleSyncStatus.applied) {
        return const BoundRelaxationResult(BoundRelaxationStatus.blocked);
      }
    }

    // 5. The flag, for the requested state only.
    final Result<ProtectionPolicyAck> flagged =
        await _sendBound(apps, configured, after, flag: true);
    Object? failure = flagged.errorOrNull;
    if (flagged.isSuccess &&
        flagged.valueOrNull!.ruleStatus != SmartRuleSyncStatus.applied) {
      failure = StateError('Native did not apply the relaxation.');
    }

    // 6. Commit (profiles), then success; any failure raises back.
    if (failure == null && commit != null) {
      final Result<void> committed = await commit();
      if (committed.isFailure) failure = committed.errorOrNull;
      await _readProfileSet();
    }
    if (failure == null) {
      return const BoundRelaxationResult(BoundRelaxationStatus.applied);
    }
    if (storageHoldsAfter && intent == BoundRelaxationIntent.confirmSaved) {
      // Nothing stricter to restore (the saved state IS the target); the
      // caller re-sends the saved state without the flag.
      return BoundRelaxationResult(
        BoundRelaxationStatus.unknown,
        error: failure,
      );
    }
    final Result<ProtectionPolicyAck> restore =
        await _sendBound(apps, configured, before, flag: false);
    final SmartRuleSyncStatus? restored = restore.valueOrNull?.ruleStatus;
    return BoundRelaxationResult(
      restored == SmartRuleSyncStatus.applied ||
              restored == SmartRuleSyncStatus.held
          ? BoundRelaxationStatus.notApplied
          : BoundRelaxationStatus.unknown,
      error: failure,
    );
  }

  /// Sends [state] as ONE combined transport (rules + profile overlay) with
  /// the stored levels; records exactly what was sent with the ack.
  Future<Result<ProtectionPolicyAck>> _sendBound(
    List<ProtectedApp> apps,
    bool configured,
    _BoundState state, {
    required bool flag,
  }) async {
    final Set<String> packages =
        apps.map((ProtectedApp app) => app.packageName).toSet();
    _overlayPackages = Set<String>.unmodifiable(packages);
    final List<Map<String, Object?>> rulePart =
        SmartRulePolicy.nativeTransport(state.rules);
    final List<Map<String, Object?>> profilePart =
        SmartRulePolicy.nativeTransport(
      SecurityProfilePolicy.overlayRules(state.profiles.active, packages),
    );
    final List<Map<String, Object?>> activationPart =
        SmartRulePolicy.nativeTransport(
      SecurityProfilePolicy.activationRules(
        state.rules,
        state.profiles,
        packages,
      ),
    );
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
        smartRules: SecurityProfilePolicy.combinedTransport(
          state.rules,
          state.profiles,
          packages,
        ),
        authorizedRuleRelaxation: flag,
      ),
    );
    if (configuredResult.isFailure) {
      _lastRuleExchange = SmartRuleNativeRecord(
        status: SmartRuleSyncStatus.unknown,
        sentRules: rulePart,
        failed: true,
        sentProfileOverlay: profilePart,
        sentActivationOverlay: activationPart,
      );
      return Result.failure(configuredResult.errorOrNull!);
    }
    final ProtectionPolicyAck ack = configuredResult.valueOrNull!;
    _lastRuleExchange = SmartRuleNativeRecord(
      status: ack.ruleStatus,
      sentRules: rulePart,
      sentProfileOverlay: profilePart,
      sentActivationOverlay: activationPart,
    );
    if (ack.status != ProtectionPolicyStatus.unknown) _lastAck = ack;
    return Result.success(ack);
  }

  Future<SecurityProfileSet?> _readProfileSet() async {
    final SecurityProfileRepository? repository = _profiles;
    if (repository == null) return SecurityProfileSet.defaults();
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
    return set;
  }

  static bool _sameRules(List<SmartRule> a, List<SmartRule> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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

  Future<Result<ProtectionBootstrapResult>> _synchronize(
    Set<String> authorizedDowngrades,
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
    final SecurityProfileSet? profiles = await _readProfileSet();
    // Phase 11 / M1: one transport (rules + profile overlay), or nothing at
    // all when either part is unknown. Phase 11 / M3: plus the overlays of
    // "Apply profile" rules (which need both documents).
    final bool send = savedRules != null && profiles != null;
    if (send) _overlayPackages = Set<String>.unmodifiable(packages);
    final List<Map<String, Object?>>? rules = send
        ? SecurityProfilePolicy.combinedTransport(
            savedRules,
            profiles,
            packages,
          )
        : null;
    final List<Map<String, Object?>>? rulePart =
        send ? SmartRulePolicy.nativeTransport(savedRules) : null;
    final List<Map<String, Object?>>? profilePart = send
        ? SmartRulePolicy.nativeTransport(
            SecurityProfilePolicy.overlayRules(profiles.active, packages),
          )
        : null;
    final List<Map<String, Object?>>? activationPart = send
        ? SmartRulePolicy.nativeTransport(
            SecurityProfilePolicy.activationRules(
              savedRules,
              profiles,
              packages,
            ),
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
      ),
    );
    if (configuredResult.isFailure) {
      _lastRuleExchange = SmartRuleNativeRecord(
        status: SmartRuleSyncStatus.unknown,
        sentRules: rulePart,
        failed: true,
        sentProfileOverlay: profilePart,
        sentActivationOverlay: activationPart,
      );
      return Result.failure(configuredResult.errorOrNull!);
    }
    final ProtectionPolicyAck ack = configuredResult.valueOrNull!;
    _lastRuleExchange = SmartRuleNativeRecord(
      status: ack.ruleStatus,
      sentRules: rulePart,
      sentProfileOverlay: profilePart,
      sentActivationOverlay: activationPart,
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

/// One side (before or after) of a bound relaxation. Phase 11 / M3: the
/// whole profile set (manual profile + profiles referenced by "Apply
/// profile" rules), compiled into the ONE combined policy.
final class _BoundState {
  const _BoundState(this.rules, this.profiles);

  final List<SmartRule> rules;
  final SecurityProfileSet profiles;

  List<SmartRule> combined(Set<String> protectedPackages) =>
      SecurityProfilePolicy.combinedRules(rules, profiles, protectedPackages);
}
