import 'dart:async';

import '../services/accessibility_lock_service.dart';
import '../services/installed_apps_service.dart';
import '../utilities/result.dart';

/// Which detection path reported a foreground transition.
enum ForegroundDetectionSource {
  /// The UsageStatsManager backend (primary path, requires Usage Access).
  usageStats,

  /// The detection-only accessibility service (fallback path).
  accessibility,
}

/// A foreground-app transition detected by [ForegroundAppMonitor].
class ForegroundAppChange {
  const ForegroundAppChange({
    required this.packageName,
    required this.source,
    required this.at,
  });

  final String packageName;

  /// The detection path that reported this transition.
  final ForegroundDetectionSource source;

  final DateTime at;

  @override
  String toString() =>
      'ForegroundAppChange($packageName via ${source.name} at '
      '${at.toIso8601String()})';
}

/// Phase 5A: detects which app is currently in the foreground by merging
/// the two Play-compliant detection paths:
///
///  * **Usage Access** (primary) — the native UsageStatsManager backend
///    polled on [pollInterval];
///  * **Accessibility** (fallback) — window-state events relayed by the
///    detection-only accessibility service.
///
/// Emits a [ForegroundAppChange] only when the foreground package
/// CHANGES (deduplicated across sources: the same package reported by
/// the other source is not a new transition).
///
/// Detection is fail-closed:
///  * probe failures are ignored (fail-quiet);
///  * a null probe result (Usage Access missing or backend failure) is
///    ignored — no transition is ever fabricated;
///  * accessibility event errors are ignored.
///
/// Lifecycle: [start] begins polling + the accessibility subscription,
/// [stop] cancels both without closing the change stream, and [dispose]
/// tears the monitor down permanently. One monitor instance is shared
/// app-wide via [AppContainer]; the lock engine consumes it in a later
/// phase (5A delivers detection only — no lock screen).
class ForegroundAppMonitor {
  ForegroundAppMonitor({
    required InstalledAppsService installedApps,
    required AccessibilityLockService accessibility,
    this.pollInterval = const Duration(seconds: 1),
    DateTime Function()? now,
  })  : _installedApps = installedApps,
        _accessibility = accessibility,
        _now = now ?? DateTime.now;

  final InstalledAppsService _installedApps;
  final AccessibilityLockService _accessibility;

  /// Poll cadence for the usage-stats backend.
  final Duration pollInterval;

  final DateTime Function() _now;

  final StreamController<ForegroundAppChange> _controller =
      StreamController<ForegroundAppChange>.broadcast();

  StreamSubscription<Result<String>>? _accessibilitySub;
  Timer? _timer;
  String? _current;
  bool _started = false;
  bool _disposed = false;

  /// Foreground transitions (deduplicated per package across sources).
  Stream<ForegroundAppChange> get changes => _controller.stream;

  /// True while detection is running (polling + fallback subscribed).
  bool get isRunning => _started;

  /// The last known foreground package, or null while unknown.
  String? get currentPackage => _current;

  /// Phase 5B diagnostic counters — exposed for the diagnostics screen
  /// and tests. Read-only for consumers.
  /// How many usage-stats probes have executed.
  int probeCount = 0;

  /// How many probes returned null (Usage Access missing or the backend
  /// reported nothing) — i.e. the primary path currently detects nothing.
  int nullProbeCount = 0;

  /// How many accessibility window-state events were received.
  int accessibilityEventCount = 0;

  /// How many probes or events failed (fail-quiet — never fabricated).
  int failureCount = 0;

  /// Starts detection: an immediate probe, periodic usage-stats polls,
  /// and the accessibility fallback subscription.
  ///
  /// Idempotent — a second call does nothing. Starting a DISPOSED
  /// monitor is a programming error and fails loudly instead of
  /// silently pretending to monitor.
  Future<void> start() async {
    if (_disposed) {
      throw StateError('ForegroundAppMonitor.start() after dispose().');
    }
    if (_started) {
      return;
    }
    _started = true;
    await probe();
    _timer = Timer.periodic(pollInterval, (_) => probe());
    _accessibilitySub =
        _accessibility.foregroundPackages.listen(_onAccessibilityEvent);
  }

  /// One immediate usage-stats pass (also used on app resume).
  Future<void> probe() async {
    probeCount++;
    final Result<String?> result =
        await _installedApps.getForegroundPackage();
    if (result.isFailure) {
      failureCount++;
      return; // fail-quiet
    }
    final String? package = result.valueOrNull;
    if (package == null || package.isEmpty) {
      nullProbeCount++;
      return; // no usage access / backend unknown — no detection
    }
    _report(package, ForegroundDetectionSource.usageStats);
  }

  void _onAccessibilityEvent(Result<String> event) {
    accessibilityEventCount++;
    if (event.isFailure) {
      failureCount++;
      return; // fail-quiet
    }
    final String? package = event.valueOrNull;
    if (package == null || package.isEmpty) {
      return;
    }
    _report(package, ForegroundDetectionSource.accessibility);
  }

  void _report(String package, ForegroundDetectionSource source) {
    if (package == _current) {
      return; // same package from either source is not a transition
    }
    _current = package;
    _controller.add(
      ForegroundAppChange(packageName: package, source: source, at: _now()),
    );
  }

  /// Stops polling and the accessibility subscription. The change stream
  /// stays open ([start] may be called again to resume detection).
  Future<void> stop() async {
    // Audit fix: clear the started flag SYNCHRONOUSLY — a start() that
    // lands while the subscription cancel is in flight must see the
    // stopped state and re-arm detection, not silently no-op.
    _started = false;
    _timer?.cancel();
    _timer = null;
    await _accessibilitySub?.cancel();
    _accessibilitySub = null;
  }

  /// Permanently tears the monitor down: stops detection and closes the
  /// change stream. Not recoverable. Idempotent — a second dispose is a
  /// safe no-op (the periodic timer is cancelled exactly once, and the
  /// stream is closed exactly once).
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    // Cancel the timer FIRST, synchronously — no await may pass before
    // the periodic timer is dead, so a dispose() racing an in-flight
    // stop() can never leave the timer alive.
    _timer?.cancel();
    _timer = null;
    _started = false;
    await _accessibilitySub?.cancel();
    _accessibilitySub = null;
    await _controller.close();
  }
}
