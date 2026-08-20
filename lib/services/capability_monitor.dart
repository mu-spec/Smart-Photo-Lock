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

  /// Per-capability previous granted state — the baseline used to detect
  /// `granted → revoked` edges. Each capability tracks its OWN state and
  /// is updated on EVERY successful probe (grants included), so a
  /// re-grant stores `true` and arms the next revocation as a new edge.
  final Map<CapabilityKind, bool> _previousGranted = <CapabilityKind, bool>{};

  Timer? _timer;
  bool _started = false;

  Stream<CapabilityChange> get changes => _controller.stream;

  /// Starts periodic monitoring: baseline probe + periodic timer.
  ///
  /// Idempotent — calling [start] while already running does nothing
  /// (never creates a second timer).
  void start() {
    if (_started) {
      return;
    }
    _started = true;
    probe();
    _timer = Timer.periodic(interval, (_) => probe());
  }

  /// Stops periodic monitoring: cancels the timer so no further timed
  /// probes fire.
  ///
  /// This is the widget-lifecycle hook (the watch guard owns it): the
  /// change stream stays open, manual [probe] calls still work, and
  /// [start] may be called again to resume monitoring. The shared
  /// monitor instance is NOT torn down here — that is [dispose].
  void stop() {
    _timer?.cancel();
    _timer = null;
    _started = false;
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
    final bool current = result.valueOrNull == true;
    final bool? previous = _previousGranted[kind];

    if (previous == null) {
      // First observation: store the baseline, never fabricate an event
      // for the startup state.
      _previousGranted[kind] = current;
      return;
    }
    if (previous && !current) {
      // granted -> revoked EDGE: emit exactly one change. Storing
      // `false` means staying revoked emits nothing.
      _controller.add(
        CapabilityChange(kind: kind, state: CapabilityState.revoked, at: _now()),
      );
      _previousGranted[kind] = false;
      return;
    }
    // Stayed granted, stayed revoked, or RE-GRANTED: update the baseline
    // and emit nothing. The re-grant case stores `true`, so a LATER
    // revocation fires again as a NEW edge.
    _previousGranted[kind] = current;
  }

  /// Permanently tears the monitor down: stops the timer and closes the
  /// change stream. Not recoverable — used when the owning container
  /// goes away for good.
  Future<void> dispose() async {
    stop();
    await _controller.close();
  }
}
