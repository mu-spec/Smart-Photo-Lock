import 'dart:async';

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

/// Phase 5D/5E: the basic lock trigger.
///
/// Subscribes to [ForegroundAppMonitor] changes, evaluates each through
/// the [AccessController], and emits [LockRequired] whenever the
/// decision is [AccessDecision.challenge] or [AccessDecision.deny] —
/// i.e. a protected application became active and must be blocked
/// behind the PIN challenge (deny = authentication is in an active
/// lockout; the challenge surface shows the cooldown).
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
    DateTime Function()? now,
  })  : _monitor = monitor,
        _controller = controller,
        _now = now ?? DateTime.now;

  final ForegroundAppMonitor _monitor;
  final AccessController _controller;
  final DateTime Function() _now;

  final StreamController<LockRequired> _lockRequired =
      StreamController<LockRequired>.broadcast();

  StreamSubscription<ForegroundAppChange>? _subscription;
  bool _started = false;

  /// Lock requirements (one per protected-app activation).
  Stream<LockRequired> get lockRequired => _lockRequired.stream;

  /// Starts the pipeline: the foreground monitor begins detecting and
  /// every transition is evaluated. Idempotent.
  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    await _monitor.start();
    _subscription = _monitor.changes.listen(_onChange);
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
    await _monitor.stop();
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

  Future<void> _onChange(ForegroundAppChange change) async {
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
