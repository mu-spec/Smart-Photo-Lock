import '../pending_lock_challenge.dart';
import 'static_overlay_lock_service.dart';
import 'static_watcher_service.dart';

/// Why the native side refused a `markChallengeReady` acknowledgement.
///
/// The names follow the three operands of the Kotlin
/// `ChallengeReadyPolicy.canHandOff(activityResumed, keyguardLocked,
/// pendingMatches)` and the argument checks in
/// `OverlayStatusChannel` → `"markChallengeReady"`.
enum NativeReadyRejection {
  /// No persisted ticket, or its package/generation differs from the one
  /// Flutter echoed back. Blank packages and negative generations count
  /// here as well, because native reads them as "no exact match".
  ticketMismatch,

  /// `ProtectionRuntime.activityResumed` is false: `MainActivity.onPause`
  /// or `onDestroy` has run and `onResume` has not run since.
  activityNotResumed,

  /// `KeyguardManager.isKeyguardLocked` is true at the moment of the call.
  keyguardLocked,
}

/// Which native event asked for a recovery attempt. Mirrors the Kotlin
/// `WakeRecoverySignal` enum.
enum NativeRecoverySignal { screenOn, userPresent, foreground, retry }

/// A test-only, deterministic model of the native challenge-handoff
/// contract (Phase 5 / Milestone 3 — Fix #1, H-4).
///
/// [StaticOverlayLockService] and [StaticWatcherService] only follow
/// these rules when they are bound together through [bind]. Unbound,
/// they keep their older lenient behaviour, so existing tests are
/// unchanged. Lock-engine regression tests that make claims about the
/// native handoff must bind this contract.
///
/// Each rule below comes from the Kotlin sources at baseline `e20d525`.
/// Nothing here is invented:
///
/// * **Ticket**: `ProtectionStateStore.ensurePendingChallenge` /
///   `replacePendingChallenge` / `clearPendingChallenge`. The same package
///   keeps its generation; a replacement always gets a fresh generation
///   and invalidates the ready handoff.
/// * **markChallengeReady**: `OverlayStatusChannel` uses an exact ticket
///   match, `ProtectionRuntime.activityResumed` and
///   `!KeyguardManager.isKeyguardLocked`. On acceptance it records the
///   ready ticket and hides the shield; a failed hide replaces the ticket
///   (`WatcherService.onChallengeHandoffFailed`). A rejection returns
///   false and changes no state.
/// * **authorizePackage**: `WatcherService.authorizePackage` needs the
///   package to be protected, an exact pending ticket, AND a ready
///   handoff for that exact ticket (`consumeChallengeHandoff`).
///   Authentication alone can never authorize.
/// * **hideLockChallenge**: succeeds only when no ticket is pending.
/// * **showLockChallenge**: ensures the ticket and shows the shield, then
///   launches the activity unless it is already resumed.
/// * **SCREEN_OFF**: invalidates the handoff, revokes every authorization,
///   replaces the wake package's ticket with a new generation and shows
///   the shield.
/// * **SCREEN_ON / USER_PRESENT / retry timer**: native recovery only
///   shows the shield and promotes the existing task. **None of them
///   calls into Dart.** Promoting a task whose activity is already resumed
///   produces no new Flutter lifecycle event, so the model never delivers
///   one to Flutter by itself; tests drive the Flutter lifecycle
///   explicitly.
///
/// Out of scope for this model, and recorded as such in the Fix #1 report:
/// grace windows and session expiry (H-2), the safe-exit gate, the
/// usage-events-versus-accessibility authority window, and the rate
/// limiting inside `WakeRecoveryGate`. The shield is idempotent, so rate
/// limiting does not change any handoff outcome.
class StaticNativeChallengeContract {
  StaticNativeChallengeContract();

  /// Binds [overlay] and [watcher] to one shared native model. Any
  /// protection configuration the watcher already holds is copied in.
  static StaticNativeChallengeContract bind({
    required StaticOverlayLockService overlay,
    required StaticWatcherService watcher,
  }) {
    final StaticNativeChallengeContract contract =
        StaticNativeChallengeContract();
    overlay.nativeContract = contract;
    watcher.nativeContract = contract;
    contract.configure(
      enabled: watcher.protectionConfigured,
      packages: Set<String>.of(watcher.protectedPackages),
    );
    return contract;
  }

  // -- ProtectionStateStore (persisted, non-secret) -------------------------

  bool enabled = false;
  Set<String> protectedPackages = <String>{};
  PendingLockChallenge? pending;
  int _lastGeneration = 0;
  String? wakeReauthPackage;

  // -- ProtectionRuntime (process-local) ------------------------------------

  /// `MainActivity.onResume` sets this; `onPause` and `onDestroy` clear it.
  /// It starts true because the widget-test app starts resumed.
  bool activityResumed = true;

  PendingLockChallenge? readyChallenge;

  // -- Platform state -------------------------------------------------------

  /// `KeyguardManager.isKeyguardLocked`.
  bool keyguardLocked = false;

  /// `PowerManager.isInteractive`.
  bool screenInteractive = true;

  /// Whether the overlay shield can be shown (overlay permission granted).
  bool overlayAvailable = true;

  /// Whether `ProtectionOverlayController.hide()` succeeds.
  bool shieldHideSucceeds = true;

  /// Whether `MainActivity.foregroundForRecovery` can promote or start the
  /// activity.
  bool activityLaunchSucceeds = true;

  // -- ProtectionOverlayController ------------------------------------------

  /// The opaque "Preparing secure unlock…" shield is on screen.
  bool shieldVisible = false;

  // -- ProtectionAccessState (subset: no grace or session expiry) -----------

  final Set<String> authorizedPackages = <String>{};
  String? currentForegroundPackage;

  // -- Observability for tests ----------------------------------------------

  int readyAcknowledgements = 0;
  int readyAccepted = 0;
  final List<Set<NativeReadyRejection>> readyRejections =
      <Set<NativeReadyRejection>>[];
  final List<NativeRecoverySignal> recoveryAttempts = <NativeRecoverySignal>[];
  int activityPromotions = 0;
  int authorizeRejections = 0;

  bool isProtected(String packageName) =>
      enabled && protectedPackages.contains(packageName);

  /// The exact `ChallengeReadyPolicy.canHandOff` predicate for [challenge],
  /// evaluated without side effects.
  Set<NativeReadyRejection> readyBlockers(PendingLockChallenge challenge) {
    final Set<NativeReadyRejection> blockers = <NativeReadyRejection>{};
    final PendingLockChallenge? current = pending;
    final bool exact = challenge.packageName.isNotEmpty &&
        challenge.generation >= 0 &&
        current != null &&
        current.packageName == challenge.packageName &&
        current.generation == challenge.generation;
    if (!exact) blockers.add(NativeReadyRejection.ticketMismatch);
    if (!activityResumed) blockers.add(NativeReadyRejection.activityNotResumed);
    if (keyguardLocked) blockers.add(NativeReadyRejection.keyguardLocked);
    return blockers;
  }

  // -- Ticket store ---------------------------------------------------------

  PendingLockChallenge ensurePendingChallenge(String packageName) {
    final PendingLockChallenge? current = pending;
    if (current != null && current.packageName == packageName) return current;
    return replacePendingChallenge(packageName);
  }

  PendingLockChallenge replacePendingChallenge(String packageName) {
    final PendingLockChallenge next = PendingLockChallenge(
      packageName: packageName,
      generation: ++_lastGeneration,
    );
    pending = next;
    readyChallenge = null; // ProtectionRuntime.invalidateChallengeHandoff()
    return next;
  }

  bool clearPendingChallenge({String? packageName, int? generation}) {
    final PendingLockChallenge? current = pending;
    if (packageName != null && current?.packageName != packageName) {
      return false;
    }
    if (generation != null && current?.generation != generation) {
      return false;
    }
    pending = null;
    return true;
  }

  /// `ProtectionStateStore.configure` plus the `WatcherChannel`
  /// `configureProtection` side effects.
  void configure({required bool enabled, required Set<String> packages}) {
    final Set<String> normalized =
        packages.where((String p) => p.isNotEmpty).toSet();
    this.enabled = enabled && normalized.isNotEmpty;
    protectedPackages = normalized;
    final PendingLockChallenge? current = pending;
    if (!enabled ||
        (current != null && !normalized.contains(current.packageName))) {
      pending = null;
      readyChallenge = null;
    }
    final String? wake = wakeReauthPackage;
    if (!enabled || (wake != null && !normalized.contains(wake))) {
      wakeReauthPackage = null;
    }
    authorizedPackages.retainAll(normalized);
    if (!enabled) {
      pending = null;
      shieldVisible = false; // disarm
    }
  }

  // -- Overlay channel ------------------------------------------------------

  /// `OverlayStatusChannel` → `"showLockChallenge"`. Returns the ticket, or
  /// null when native would return null.
  PendingLockChallenge? showLockChallenge(String packageName) {
    if (packageName.isEmpty) return null;
    final PendingLockChallenge ticket = ensurePendingChallenge(packageName);
    final bool shielded = _showShield();
    final bool launched =
        shielded && (activityResumed || _foregroundForRecovery(ticket));
    return shielded && launched ? ticket : null;
  }

  /// `OverlayStatusChannel` → `"markChallengeReady"`.
  bool markChallengeReady(PendingLockChallenge challenge) {
    readyAcknowledgements++;
    final Set<NativeReadyRejection> blockers = readyBlockers(challenge);
    if (blockers.isNotEmpty) {
      // "SCREEN_ON can resume behind keyguard. Preserve the pending ticket
      // and shield for USER_PRESENT/retry." Nothing else changes.
      readyRejections.add(blockers);
      return false;
    }
    final PendingLockChallenge exact = pending!;
    readyChallenge = exact;
    final bool hidden = _hideShield();
    if (hidden) {
      readyAccepted++;
      // WatcherService.onChallengeHandoffComplete() only resets retry
      // bookkeeping.
    } else {
      // WatcherService.onChallengeHandoffFailed().
      readyChallenge = null;
      replacePendingChallenge(exact.packageName);
      _recover(exact.packageName, NativeRecoverySignal.foreground);
    }
    return hidden;
  }

  /// `OverlayStatusChannel` → `"hideLockChallenge"`.
  bool hideLockChallenge() => pending == null && _hideShield();

  // -- Watcher channel ------------------------------------------------------

  /// `WatcherService.authorizePackage`.
  bool authorizePackage(PendingLockChallenge challenge) {
    final String packageName = challenge.packageName;
    final PendingLockChallenge? current = pending;
    final bool ok = isProtected(packageName) &&
        current != null &&
        current.packageName == packageName &&
        current.generation == challenge.generation &&
        _consumeChallengeHandoff(challenge);
    if (!ok) {
      authorizeRejections++;
      return false;
    }
    authorizedPackages.add(packageName);
    currentForegroundPackage = packageName;
    wakeReauthPackage = packageName;
    clearPendingChallenge(
      packageName: packageName,
      generation: challenge.generation,
    );
    return true;
  }

  void revokeAllAuthorizations() => authorizedPackages.clear();

  PendingLockChallenge? takePendingChallenge() => pending;

  // -- Device / platform events (driven explicitly by tests) ----------------

  /// `MainActivity.onResume` and its recovery-intent handling. This is
  /// native only; the test must also deliver the Flutter `resumed`
  /// lifecycle itself.
  void onActivityResumed() {
    activityResumed = true;
    _onChallengeActivityAvailable();
  }

  /// `MainActivity.onPause`.
  void onActivityPaused() {
    activityResumed = false;
  }

  /// `WatcherService` ACTION_SCREEN_OFF receiver.
  void screenOff() {
    screenInteractive = false;
    readyChallenge = null; // invalidateChallengeHandoff()
    authorizedPackages.clear(); // ProtectionAccessState.revokeAll()
    final String? observed = currentForegroundPackage;
    String? wake;
    if (observed != null && observed.isNotEmpty && isProtected(observed)) {
      wake = observed;
    } else {
      final String? remembered = wakeReauthPackage;
      if (remembered != null && isProtected(remembered)) wake = remembered;
    }
    if (wake != null) {
      wakeReauthPackage = wake;
      replacePendingChallenge(wake);
      _showShield();
    }
  }

  /// The keyguard engages. On most devices this happens at screen-off.
  void lockKeyguard() {
    keyguardLocked = true;
  }

  /// `WatcherService` ACTION_SCREEN_ON receiver. This usually arrives
  /// while the keyguard is still locked.
  void screenOn() {
    screenInteractive = true;
    final PendingLockChallenge? ticket = _restoreWakeReauthChallenge();
    if (ticket != null && isProtected(ticket.packageName)) {
      _recover(ticket.packageName, NativeRecoverySignal.screenOn);
    }
  }

  /// The user dismisses the keyguard, then ACTION_USER_PRESENT fires.
  void dismissKeyguard() {
    keyguardLocked = false;
    final PendingLockChallenge? ticket = _restoreWakeReauthChallenge();
    if (ticket != null && isProtected(ticket.packageName)) {
      _recover(ticket.packageName, NativeRecoverySignal.userPresent);
    }
  }

  /// One firing of the `WatcherService.recoveryRetry` runnable, which
  /// runs every 3 seconds while a ticket is pending.
  void recoveryRetryTick() {
    final PendingLockChallenge? ticket = pending;
    if (ticket == null || !isProtected(ticket.packageName)) return;
    _recover(ticket.packageName, NativeRecoverySignal.retry);
  }

  /// `WatcherService.reportForeground` from an Accessibility event.
  /// Production calls this natively before Flutter's event sink receives
  /// the same package.
  void reportForeground(String packageName) {
    if (!enabled) return;
    final bool protected = isProtected(packageName);
    if (!protected &&
        !screenInteractive &&
        (pending != null || (wakeReauthPackage?.isNotEmpty ?? false))) {
      // ScreenOffForegroundPolicy.shouldPreservePending
      if (pending != null && wakeReauthPackage == null) {
        wakeReauthPackage = pending!.packageName;
      }
      readyChallenge = null;
      authorizedPackages.clear();
      return;
    }
    if (protected) {
      wakeReauthPackage = packageName;
    } else {
      wakeReauthPackage = null;
      final PendingLockChallenge? ready = readyChallenge;
      if (ready != null &&
          clearPendingChallenge(
            packageName: ready.packageName,
            generation: ready.generation,
          )) {
        readyChallenge = null;
      }
    }
    // ProtectionAccessState.observeForeground with a zero grace period.
    final String? previous = currentForegroundPackage;
    if (previous != packageName) {
      currentForegroundPackage = packageName;
      if (previous != null) authorizedPackages.remove(previous);
    }
    final bool allow = !protected || authorizedPackages.contains(packageName);
    if (allow) {
      if (pending == null) _hideShield();
    } else {
      _recover(packageName, NativeRecoverySignal.foreground);
    }
  }

  // -- Internals ------------------------------------------------------------

  PendingLockChallenge? _restoreWakeReauthChallenge() {
    final PendingLockChallenge? current = pending;
    if (current != null) return current;
    final String? wake = wakeReauthPackage;
    if (wake == null || wake.isEmpty || !isProtected(wake)) return null;
    return replacePendingChallenge(wake);
  }

  /// `WatcherService.recoverProtected`. Note: this never calls into Dart.
  void _recover(String packageName, NativeRecoverySignal signal) {
    recoveryAttempts.add(signal);
    final PendingLockChallenge ticket = ensurePendingChallenge(packageName);
    if (activityResumed && readyChallenge == ticket) return;
    final bool shielded = _showShield();
    if (shielded) _foregroundForRecovery(ticket);
  }

  /// `MainActivity.foregroundForRecovery`. It promotes the existing task
  /// (`moveTaskToFront`). An already-resumed activity gets no new
  /// lifecycle callback, and no Dart method is ever invoked.
  bool _foregroundForRecovery(PendingLockChallenge ticket) {
    if (!activityLaunchSucceeds) return false;
    activityPromotions++;
    // acceptRecoveryIntent("existingTask") → onChallengeActivityAvailable.
    _onChallengeActivityAvailable();
    return true;
  }

  void _onChallengeActivityAvailable() {
    final PendingLockChallenge? ticket = pending;
    if (ticket == null || !isProtected(ticket.packageName)) return;
    _showShield();
  }

  bool _consumeChallengeHandoff(PendingLockChallenge challenge) {
    final PendingLockChallenge? ready = readyChallenge;
    if (ready == null ||
        ready.packageName != challenge.packageName ||
        ready.generation != challenge.generation) {
      return false;
    }
    readyChallenge = null;
    return true;
  }

  bool _showShield() {
    if (!overlayAvailable) return false;
    shieldVisible = true;
    return true;
  }

  bool _hideShield() {
    if (!shieldHideSucceeds) return false;
    shieldVisible = false;
    return true;
  }
}
