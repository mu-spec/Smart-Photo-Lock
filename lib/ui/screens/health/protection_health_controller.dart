import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../protection/health/protection_health_engine.dart';
import '../../../protection/health/protection_health_monitor.dart';

/// Phase 7 / M2 — view state for the Protection Health dashboard.
///
/// A thin view over the ONE shared [ProtectionHealthMonitor] (the app
/// container's `protectionHealth`): no second classification and no cache
/// of its own. Each screen owns one controller; every refresh goes through
/// the monitor, which coalesces concurrent probes and bounds each read.
///
/// Safety rules:
///  * [report] re-applies the M1 staleness rule on every read
///    (`monitor.latest()`), so an old SECURE turns into ATTENTION REQUIRED.
///  * When the report reaches its maximum age, ONE timer notifies listeners
///    so the screen re-renders the stale state. It never probes: there is
///    no polling.
///  * A failed refresh discards the shown report ([failed] = true), so a
///    previous SECURE is never shown after a failure.
///  * After [dispose], completions are ignored.
class ProtectionHealthController extends ChangeNotifier {
  ProtectionHealthController(this._monitor, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final ProtectionHealthMonitor? _monitor;
  final DateTime Function() _now;

  bool _checking = false;
  bool _failed = false;
  bool _disposed = false;
  Timer? _staleTimer;
  int _generation = 0;

  /// True while a refresh is in flight.
  bool get checking => _checking;

  /// True when the most recent refresh failed (no report is shown).
  bool get failed => _failed;

  /// Whether any health source exists (false in pure widget tests).
  bool get available => _monitor != null;

  /// The latest observation re-evaluated now, or null when there is none
  /// or the most recent refresh failed.
  ProtectionHealthReport? get report {
    if (_failed) return null;
    return _monitor?.latest();
  }

  /// Collects fresh signals through the shared monitor. Concurrent calls
  /// (from this or any other screen) share one probe.
  Future<ProtectionHealthReport?> refresh() async {
    final ProtectionHealthMonitor? monitor = _monitor;
    if (monitor == null || _disposed) return null;
    final int generation = ++_generation;
    _checking = true;
    _notify();
    ProtectionHealthReport? fresh;
    bool failed = false;
    try {
      fresh = await monitor.refresh();
    } catch (_) {
      failed = true;
    }
    if (_disposed || generation != _generation) return fresh;
    _checking = false;
    _failed = failed;
    _scheduleStaleRender(failed ? null : fresh, monitor.maxAge);
    _notify();
    return failed ? null : fresh;
  }

  void _scheduleStaleRender(ProtectionHealthReport? fresh, Duration maxAge) {
    _staleTimer?.cancel();
    _staleTimer = null;
    if (fresh == null || fresh.stale) return;
    final Duration age = _now().difference(fresh.observedAt);
    Duration wait = maxAge - age + const Duration(milliseconds: 1);
    if (wait.isNegative) wait = Duration.zero;
    _staleTimer = Timer(wait, _notify);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _staleTimer?.cancel();
    _staleTimer = null;
    super.dispose();
  }
}
