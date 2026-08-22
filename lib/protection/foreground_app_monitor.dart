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

  /// Phase 5O hardening: true while the last-known foreground package
  /// is STALE — Smart App Lock left the foreground, so the
  /// intermediate foreground (Recents UI, launcher) may never be
  /// observed by either detection path. The next report is then
  /// treated as a fresh transition even when it carries the same
  /// package (see [invalidateCurrentPackage]).
  bool _currentStale = false;

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

  /// Phase 5O hardening: marks the last-known foreground package
  /// STALE, so the next report — even of the identical package — is
  /// emitted as a fresh transition.
  ///
  /// Called when Smart App Lock itself leaves the foreground (Recents
  /// or another task covers it). Detection continuity is broken: a
  /// sub-second pass through the task switcher can slip past the
  /// 1-second usage-stats poll AND emit no accessibility window event,
  /// so a protected app returning through its Recents task would be
  /// reported as the SAME package and swallowed by the dedupe — the
  /// protected app would be exposed with no challenge.
  ///
  /// Fail-closed: the invalidation only re-runs evaluation for the
  /// next observation (the access controller still honors live
  /// sessions and grace periods), so it can never fabricate a false
  /// challenge. Null probes are not observations and never consume it.
  void invalidateCurrentPackage() {
    _currentStale = true;
  }

  void _report(String package, ForegroundDetectionSource source) {
    // A stale last-known package is consumed by the FIRST observation,
    // whatever it carries: a same-package report is a real return
    // (Recents covered Smart App Lock without detection seeing the
    // task switcher), and a different package is a normal transition
    // that re-establishes fresh ground truth — dedupe resumes after it.
    final bool stale = _currentStale;
    _currentStale = false;
    if (!stale && package == _current) {
      return; // same package from either source is not a transition
    }
    _current = package;
    // Mobile-QA diagnostics (asserts are stripped in release builds):
    // trace the real-device pipeline in logcat.
    assert(() {
      // ignore: avoid_print
      print('🔍 ForegroundAppMonitor: ${source.name} -> $package');
      return true;
    }());
    _controller.add(
      ForegroundAppChange(packageName: package, source: source, at: _now()),
    );
  }

  /// Stops polling and the accessibility subscription. The change stream
  /// stays open ([start] may be called again to resume detection).
  ///
  /// The periodic timer is cancelled SYNCHRONOUSLY (before any yield):
  /// nothing here can block — the subscription cancel completes
  /// asynchronously and is not awaited, so stop() can never hang a
  /// caller, in any zone.
  Future<void> stop() async {
    // Audit fix: clear the started flag SYNCHRONOUSLY — a start() that
    // lands while the subscription cancel is in flight must see the
    // stopped state and re-arm detection, not silently no-op.
    _started = false;
    _timer?.cancel();
    _timer = null;
    final StreamSubscription<Result<String>>? sub = _accessibilitySub;
    _accessibilitySub = null;
    if (sub != null) {
      unawaited(sub.cancel());
    }
  }

  /// Permanently tears the monitor down: stops detection and closes the
  /// change stream. Not recoverable. Idempotent — a second dispose is a
  /// safe no-op (the periodic timer is cancelled exactly once, and the
  /// stream is closed exactly once).
  ///
  /// The timer dies SYNCHRONOUSLY first — no await may pass before the
  /// periodic timer is cancelled, so a dispose racing an in-flight
  /// stop can never leave the timer alive, and nothing here can hang.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _started = false;
    final StreamSubscription<Result<String>>? sub = _accessibilitySub;
    _accessibilitySub = null;
    if (sub != null) {
      unawaited(sub.cancel());
    }
    unawaited(_controller.close());
  }
}
