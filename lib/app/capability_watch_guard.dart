import 'dart:async';

import 'package:flutter/material.dart';

import '../services/capability_monitor.dart';
import 'app_scope.dart';

/// Starts the shared [CapabilityMonitor] for the app and connects it to
/// the app lifecycle (Phase 4F).
///
/// The monitor probes on a timer; additionally, whenever the app
/// RESUMES (the user may have revoked a grant in the system settings),
/// a prompt probe fires. Revocation changes are surfaced on the Home
/// tab via a callback.
///
/// Lifecycle ownership: the guard STARTS periodic monitoring when the
/// app root mounts and STOPS it (timer cancelled, subscription dropped)
/// when the root unmounts. The [CapabilityMonitor] itself is shared via
/// [AppContainer] and stays usable — only its periodic timer is
/// stopped, never the shared stream.
class CapabilityWatchGuard extends StatefulWidget {
  const CapabilityWatchGuard({
    super.key,
    required this.child,
    this.onRevocation,
  });

  final Widget child;

  /// Called with the revoked capability (used to badge the Home tab).
  final ValueChanged<CapabilityKind>? onRevocation;

  @override
  State<CapabilityWatchGuard> createState() => _CapabilityWatchGuardState();
}

class _CapabilityWatchGuardState extends State<CapabilityWatchGuard>
    with WidgetsBindingObserver {
  /// The shared monitor this guard started (null without a container).
  CapabilityMonitor? _monitor;

  /// Our own subscription to revocation changes (dropped on dispose).
  StreamSubscription<CapabilityChange>? _subscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _monitor = AppScope.read(context)?.capabilityMonitor;
    _monitor?.start();
    _subscription = _monitor?.changes.listen((CapabilityChange change) {
      if (change.state == CapabilityState.revoked) {
        widget.onRevocation?.call(change.kind);
      }
    });
  }

  @override
  void dispose() {
    // Stop exactly what we started: the periodic timer (no pending
    // timer leak) and our subscription. The shared monitor keeps its
    // stream open so a remounted app root can start() it again.
    _subscription?.cancel();
    _monitor?.stop();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Prompt re-probe when the app returns from the background/system
  /// settings.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _monitor?.probe();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
