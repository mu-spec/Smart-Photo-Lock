import 'dart:async';

import '../services/screen_state_service.dart';
import '../utilities/result.dart';
import 'access_controller.dart';
import 'foreground_app_monitor.dart';

/// A protected app became active and must be challenged.
class LockRequired {
  const LockRequired({required this.packageName, required this.at});

  final String packageName;
  final DateTime at;

  @override
  String toString() =>
      'LockRequired($packageName at ${at.toIso8601String()})';
}

/// Phase 5D/5E/5J: the lock trigger.
///
/// Subscribes to [ForegroundAppMonitor] changes, evaluates each through
/// the [AccessController], and emits [LockRequired] whenever the
/// decision is [AccessDecision.challenge] or [AccessDecision.deny] —
/// i.e. a protected application became active and must be blocked
/// behind the PIN challenge (deny = authentication is in an active
/// lockout; the challenge surface shows the cooldown).
///
/// Phase 5J adds IMMEDIATE RE-LOCK: every transition AWAY from a
/// package revokes that package's unlock session first, so leaving a
/// protected app re-locks it instantly — returning always requires
/// authentication again.
///
/// The trigger is a pure decision pipeline: it never presents UI and
/// never touches the platform. The app layer listens to [lockRequired]
/// and presents the unlock challenge (see `LockChallengeHost`).
///
/// Fail-closed: an [AccessController] that answers `challenge` for
/// unknown protection state (repository failure) means the trigger
/// emits a lock requirement rather than letting an unknown app through.
class LockTrigger {
  LockTrigger({
    required ForegroundAppMonitor monitor,
    required AccessController controller,
    required ScreenStateService screenState,
    DateTime Function()? now,
  })  : _monitor = monitor,
        _controller = controller,
        _screenState = screenState,
        _now = now ?? DateTime.now;

  final ForegroundAppMonitor _monitor;
  final AccessController _controller;
  final ScreenStateService _screenState;
  final DateTime Function() _now;

  final StreamController<LockRequired> _lockRequired =
      StreamController<LockRequired>.broadcast();

  StreamSubscription<ForegroundAppChange>? _subscription;
  StreamSubscription<Result<ScreenStateEvent>>? _screenSub;
  bool _started = false;

  /// Phase 5K: true once a screen-off was observed since the last
  /// resume — the re-lock enforcement marker consumed by the app layer.
  bool _screenOffPending = false;

  /// The last foreground package the trigger evaluated (Phase 5J): a
  /// transition AWAY from it revokes that package's unlock session
  /// immediately — leaving a protected app re-locks it.
  String? _previousPackage;

  /// Lock requirements (one per protected-app activation).
  Stream<LockRequired> get lockRequired => _lockRequired.stream;

  /// Starts the pipeline: the foreground monitor begins detecting and
  /// every transition is evaluated. Idempotent.
  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    // Phase 5J: seed the previous-package tracking from the monitor's
    // last known foreground, so a restart while inside a protected app
    // still revokes its session the moment the user leaves.
    _previousPackage ??= _monitor.currentPackage;
    await _monitor.start();
    _subscription = _monitor.changes.listen(_onChange);
    // Phase 5K: watch the device screen state — a screen-off revokes
    // every unlock session immediately.
    _screenSub = _screenState.events.listen(_onScreenEvent);
  }

  /// Stops the pipeline: unsubscribes and stops the monitor. The lock
  /// stream stays open ([start] may be called again).
  Future<void> stop() async {
    // Audit fix: clear the started flag SYNCHRONOUSLY — a start() that
    // lands while the subscription cancel is in flight must see the
    // stopped state and re-arm the pipeline, not silently no-op.
    _started = false;
    await _subscription?.cancel();
    _subscription = null;
    await _screenSub?.cancel();
    _screenSub = null;
    // Phase 5Q: drain the processing queue so no transition evaluates
    // (or emits) after stop() resolves.
    await _processing;
    await _monitor.stop();
  }

  /// Phase 5K: consumes and clears the screen-off marker — the app
  /// layer calls this on resume to decide whether re-lock enforcement
  /// must re-evaluate the current foreground.
  bool takeScreenOffPending() {
    final bool pending = _screenOffPending;
    _screenOffPending = false;
    return pending;
  }

  Future<void> _onScreenEvent(Result<ScreenStateEvent> event) async {
    if (event.isFailure) {
      return; // fail-quiet
    }
    if (event.valueOrNull != ScreenStateEvent.screenOff) {
      return; // screen-on: nothing to re-lock
    }
    // Phase 5K: the screen turned off — every unlock session ends NOW.
    // The marker tells the app layer to re-evaluate the foreground on
    // resume, so returning to a protected app challenges immediately.
    _screenOffPending = true;
    await _controller.revokeAllAccess();
  }

  /// True while the pipeline is running (audit: lets other components —
  /// e.g. the diagnostics screen — know whether detection is owned by
  /// the production lock flow).
  bool get isRunning => _started;

  /// Permanently tears the pipeline down.
  Future<void> dispose() async {
    await stop();
    await _lockRequired.close();
  }

  /// Phase 5Q: serializes transition processing. Rapid switches
  /// (protected → unprotected → protected) must evaluate strictly in
  /// order — an interleaved departure/evaluation could otherwise arm a
  /// stale grace deadline AFTER a re-entry already happened.
  Future<void> _processing = Future<void>.value();

  void _onChange(ForegroundAppChange change) {
    _processing = _processing.then((_) => _processChange(change));
  }

  Future<void> _processChange(ForegroundAppChange change) async {
    // Phase 5J/5L: leaving the previous package applies the grace
    // policy (the controller's revokeAccess arms the deadline when a
    // grace is configured, or revokes instantly).
    final String? previous = _previousPackage;
    _previousPackage = change.packageName;
    if (previous != null && previous != change.packageName) {
      await _controller.revokeAccess(previous);
    }

    final AccessDecision decision =
        await _controller.evaluate(change.packageName);
    // Phase 5E: `challenge` requires the PIN; `deny` (authentication in
    // an active lockout) ALSO emits a requirement — the protected app
    // stays blocked behind the challenge surface, whose unlock screen
    // shows the cooldown countdown. Only `allow` passes silently.
    if (decision != AccessDecision.challenge &&
        decision != AccessDecision.deny) {
      return;
    }
    _lockRequired.add(
      LockRequired(packageName: change.packageName, at: _now()),
    );
  }
}
