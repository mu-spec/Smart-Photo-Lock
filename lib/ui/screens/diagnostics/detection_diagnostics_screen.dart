import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_container.dart';
import '../../../app/app_scope.dart';
import '../../../design_system/design_system.dart';
import '../../../protection/foreground_app_monitor.dart';
import '../../../protection/protected_app_matcher.dart';

/// Phase 5B — developer diagnostics for foreground detection.
///
/// TEMPORARY developer tool: verifies that [ForegroundAppMonitor]
/// detects real foreground transitions. How to use it on a device:
///
///  1. open this screen (Home → Detection diagnostics);
///  2. press Home and open any OTHER app (WhatsApp, Maps, Chrome, ...);
///  3. return to Smart App Lock — the other app's package appears as the
///     current foreground app and as a new transition-log entry;
///  4. repeat with many different apps.
///
/// Detection runs while Smart App Lock itself is open (background
/// detection arrives with the watcher-service phase), so the usage-stats
/// lookback reports the app you just left when you come back here.
///
/// This screen starts the monitor on open and stops it on close — the
/// same start/stop contract the lock engine will own in production.
class DetectionDiagnosticsScreen extends StatefulWidget {
  const DetectionDiagnosticsScreen({super.key});

  /// Maximum entries kept in the on-screen transition log.
  static const int maxLogEntries = 200;

  static const String unknownPackage = 'Unknown — no detection yet';
  static const String howToUse =
      'Open other apps, then come back here. Each detected foreground '
      'switch is logged below with its detection source.';
  static const String runningLabel = 'Detecting';
  static const String stoppedLabel = 'Stopped';
  static const String noContainerMessage =
      'No AppContainer in scope — diagnostics unavailable.';

  @override
  State<DetectionDiagnosticsScreen> createState() =>
      _DetectionDiagnosticsScreenState();
}

class _DetectionDiagnosticsScreenState
    extends State<DetectionDiagnosticsScreen> {
  /// The shared monitor (null without a container in scope).
  ForegroundAppMonitor? _monitor;

  StreamSubscription<ForegroundAppChange>? _subscription;

  /// Transition log, newest first, capped at [maxLogEntries].
  final List<ForegroundAppChange> _log = <ForegroundAppChange>[];

  /// Whether the accessibility fallback service is enabled (read once on
  /// open and on demand).
  bool? _accessibilityEnabled;

  /// Phase 5C: matching decision for the CURRENT foreground package
  /// (null while nothing is known yet).
  ProtectedMatchDecision? _matchDecision;

  int _tick = 0;

  @override
  void initState() {
    super.initState();
    final AppContainer? container = AppScope.read(context);
    _monitor = container?.foregroundMonitor;
    if (_monitor != null) {
      _subscription = _monitor!.changes.listen(_onChange);
      _initDetection();
    }
    _refreshAccessibility();
  }

  /// Starts detection, then matches whatever the baseline probe found.
  Future<void> _initDetection() async {
    await _monitor?.start();
    if (!mounted) {
      return;
    }
    await _refreshMatch();
  }

  @override
  void dispose() {
    // Stop exactly what this screen started — no timer may outlive it.
    _subscription?.cancel();
    _monitor?.stop();
    super.dispose();
  }

  void _onChange(ForegroundAppChange change) {
    if (!mounted) {
      return;
    }
    setState(() {
      _log.insert(0, change);
      if (_log.length > DetectionDiagnosticsScreen.maxLogEntries) {
        _log.removeLast();
      }
    });
    _refreshMatch();
  }

  /// Phase 5C: matches the current foreground package against the
  /// protected-app repository and exposes the decision.
  Future<void> _refreshMatch() async {
    final ForegroundAppMonitor? monitor = _monitor;
    final String? package = monitor?.currentPackage;
    final AppContainer? container = AppScope.read(context);
    if (monitor == null || package == null || container == null) {
      if (mounted) {
        setState(() => _matchDecision = null);
      }
      return;
    }
    final ProtectedMatch match =
        await container.protectedAppMatcher.match(package);
    if (!mounted || match.packageName != _monitor?.currentPackage) {
      return; // stale result — a newer change event refreshes it
    }
    setState(() => _matchDecision = match.decision);
  }

  Future<void> _refreshAccessibility() async {
    final AppContainer? container = AppScope.read(context);
    if (container == null) {
      return;
    }
    final result = await container.accessibility.isServiceEnabled();
    if (!mounted) {
      return;
    }
    setState(() {
      _accessibilityEnabled = result.isSuccess && result.valueOrNull == true;
    });
  }

  void _toggleDetection() {
    final ForegroundAppMonitor? monitor = _monitor;
    if (monitor == null) {
      return;
    }
    setState(() {
      _tick++; // rebuild the status pill
      if (_monitor!.isRunning) {
        _monitor!.stop();
      } else {
        _monitor!.start();
      }
    });
  }

  void _clearLog() {
    setState(_log.clear);
  }

  @override
  Widget build(BuildContext context) {
    final ForegroundAppMonitor? monitor = _monitor;
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Detection diagnostics')),
      body: monitor == null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(DsSpacing.xl),
                child: Text(DetectionDiagnosticsScreen.noContainerMessage),
              ),
            )
          : ListView(
              padding: DsInsets.screen,
              children: <Widget>[
                DsCard(
                  title: 'Current foreground',
                  subtitle: DetectionDiagnosticsScreen.howToUse,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        monitor.currentPackage ??
                            DetectionDiagnosticsScreen.unknownPackage,
                        key: const Key('diag_current'),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: DsSpacing.md),
                      Row(
                        children: <Widget>[
                          DsStatusPill(
                            key: const Key('diag_status'),
                            label: monitor.isRunning
                                ? DetectionDiagnosticsScreen.runningLabel
                                : DetectionDiagnosticsScreen.stoppedLabel,
                            showDot: monitor.isRunning,
                          ),
                          const SizedBox(width: DsSpacing.sm + 2),
                          // Phase 5C: is the CURRENT app in the protected
                          // list? (Hidden until the first match resolves.)
                          if (_matchDecision != null) ...<Widget>[
                            DsStatusPill(
                              key: const Key('diag_match'),
                              label: switch (_matchDecision!) {
                                ProtectedMatchDecision.protected =>
                                  'Protected',
                                ProtectedMatchDecision.notProtected =>
                                  'Not protected',
                                ProtectedMatchDecision.unknown => 'Unknown',
                              },
                              tone: switch (_matchDecision!) {
                                ProtectedMatchDecision.protected =>
                                  DsTone.success,
                                ProtectedMatchDecision.notProtected =>
                                  DsTone.neutral,
                                ProtectedMatchDecision.unknown =>
                                  DsTone.warning,
                              },
                              showDot: false,
                            ),
                            const SizedBox(width: DsSpacing.sm + 2),
                          ],
                          DsButton(
                            key: const Key('diag_toggle'),
                            label: monitor.isRunning ? 'Stop' : 'Start',
                            size: DsButtonSize.small,
                            variant: DsButtonVariant.secondary,
                            onPressed: _toggleDetection,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: DsSpacing.lg),
                DsCard(
                  title: 'Path counters',
                  child: Column(
                    children: <Widget>[
                      _CounterRow(
                        label: 'Usage-stats probes',
                        value: '${monitor.probeCount}',
                      ),
                      _CounterRow(
                        label: 'Null probes (no usage access?)',
                        value: '${monitor.nullProbeCount}',
                      ),
                      _CounterRow(
                        label: 'Accessibility events',
                        value: '${monitor.accessibilityEventCount}',
                      ),
                      _CounterRow(
                        label: 'Failures (fail-quiet)',
                        value: '${monitor.failureCount}',
                      ),
                      _CounterRow(
                        label: 'Accessibility service',
                        value: _accessibilityEnabled == null
                            ? '…'
                            : (_accessibilityEnabled! ? 'Enabled' : 'Off'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: DsSpacing.lg),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: DsSectionTitle(
                        'Transition log (${_log.length})',
                      ),
                    ),
                    DsButton(
                      key: const Key('diag_clear'),
                      label: 'Clear',
                      size: DsButtonSize.small,
                      variant: DsButtonVariant.outline,
                      onPressed: _log.isEmpty ? null : _clearLog,
                    ),
                  ],
                ),
                const SizedBox(height: DsSpacing.md),
                if (_log.isEmpty)
                  const DsCard(
                    child: Padding(
                      padding: EdgeInsets.all(DsSpacing.lg),
                      child: Center(
                        child: Text(
                          'No transitions yet — go open some apps.',
                        ),
                      ),
                    ),
                  )
                else
                  DsCard(
                    key: const Key('diag_log'),
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: <Widget>[
                        for (final ForegroundAppChange entry in _log)
                          _LogEntry(entry: entry),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

/// One transition-log row: time, package, and the detection source.
class _LogEntry extends StatelessWidget {
  const _LogEntry({required this.entry});

  final ForegroundAppChange entry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    final DateTime at = entry.at;
    final String time =
        '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}:'
        '${at.second.toString().padLeft(2, '0')}';
    return Padding(
      padding: DsInsets.row,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 64,
            child: Text(
              time,
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              entry.packageName,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: DsSpacing.sm),
          DsStatusPill(
            label: entry.source == ForegroundDetectionSource.usageStats
                ? 'usage'
                : 'a11y',
            showDot: false,
          ),
        ],
      ),
    );
  }
}

class _CounterRow extends StatelessWidget {
  const _CounterRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    return Padding(
      padding: DsInsets.row,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.textSecondary,
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
