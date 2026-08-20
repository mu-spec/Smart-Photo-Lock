import 'dart:async';

import '../utilities/result.dart';

/// Which capability changed.
enum CapabilityKind { usageAccess, accessibility, overlay }

/// The current state of one capability.
enum CapabilityState { granted, revoked }

/// A capability state change detected by [CapabilityMonitor].
class CapabilityChange {
  const CapabilityChange({
    required this.kind,
    required this.state,
    required this.at,
  });

  final CapabilityKind kind;
  final CapabilityState state;
  final DateTime at;

  @override
  String toString() =>
      'CapabilityChange(${kind.name} -> ${state.name} at ${at.toIso8601String()})';
}

/// Watches the three required capabilities and emits a [CapabilityChange]
/// the moment a previously-granted capability becomes **revoked**.
///
/// Design (Phase 4F):
///  * a baseline probe on [start] (no change events for the initial
///    state);
///  * periodic re-probes ([interval], default 2 minutes);
///  * a prompt re-probe whenever the app RESUMES — revocations made in
///    the system settings are detected immediately;
///  * a per-kind `granted → revoked` edge fires exactly one change per
///    transition (no duplicate spam while it stays revoked);
///  * probe failures are ignored (fail-quiet — the next successful
///    probe decides; the monitor never fabricates events).
class CapabilityMonitor {
  CapabilityMonitor({
    required this.hasUsageAccess,
    required this.isAccessibilityEnabled,
    required this.canDrawOverlays,
    this.interval = const Duration(minutes: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Future<Result<bool>> Function() hasUsageAccess;
  final Future<Result<bool>> Function() isAccessibilityEnabled;
  final Future<Result<bool>> Function() canDrawOverlays;

  /// Poll period between proactive probes.
  final Duration interval;

  final DateTime Function() _now;

  /// Emits only `granted → revoked` transitions (and, once revoked,
  /// re-grants are not surfaced — the lock engine re-evaluates on its
  /// own schedule).
  final StreamController<CapabilityChange> _controller =
      StreamController<CapabilityChange>.broadcast();

  final Map<CapabilityKind, bool> _lastGranted = <CapabilityKind, bool>{};

  Timer? _timer;
  bool _started = false;

  Stream<CapabilityChange> get changes => _controller.stream;

  /// Starts the monitor: baseline probe + periodic timer.
  void start() {
    if (_started) {
      return;
    }
    _started = true;
    probe();
    _timer = Timer.periodic(interval, (_) => probe());
  }

  /// Probes all three capabilities and emits transitions.
  Future<void> probe() async {
    await _probeOne(
      CapabilityKind.usageAccess,
      hasUsageAccess,
    );
    await _probeOne(
      CapabilityKind.accessibility,
      isAccessibilityEnabled,
    );
    await _probeOne(
      CapabilityKind.overlay,
      canDrawOverlays,
    );
  }

  Future<void> _probeOne(
    CapabilityKind kind,
    Future<Result<bool>> Function() probe,
  ) async {
    final Result<bool> result = await probe();
    if (result.isFailure) {
      return; // fail-quiet: no fabricated transitions
    }
    final bool granted = result.valueOrNull == true;
    final bool? previous = _lastGranted[kind];
    if (previous != null && previous && !granted) {
      _controller.add(
        CapabilityChange(kind: kind, state: CapabilityState.revoked, at: _now()),
      );
    }
    _lastGranted[kind] = granted;
  }

  /// Stops the timer and closes the stream.
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    _started = false;
    await _controller.close();
  }
}
