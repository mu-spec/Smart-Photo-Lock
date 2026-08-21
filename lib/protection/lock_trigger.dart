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

/// Phase 5D: the basic lock trigger.
///
/// Subscribes to [ForegroundAppMonitor] changes, evaluates each through
/// the [AccessController], and emits [LockRequired] whenever the
/// decision is [AccessDecision.challenge] — i.e. a protected application
/// became active and no unlock session covers it.
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
    await _subscription?.cancel();
    _subscription = null;
    _started = false;
    await _monitor.stop();
  }

  /// Permanently tears the pipeline down.
  Future<void> dispose() async {
    await stop();
    await _lockRequired.close();
  }

  Future<void> _onChange(ForegroundAppChange change) async {
    final AccessDecision decision =
        await _controller.evaluate(change.packageName);
    if (decision != AccessDecision.challenge) {
      return;
    }
    _lockRequired.add(
      LockRequired(packageName: change.packageName, at: _now()),
    );
  }
}
