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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final monitor = AppScope.read(context)?.capabilityMonitor;
    monitor?.start();
    monitor?.changes.listen((CapabilityChange change) {
      if (change.state == CapabilityState.revoked) {
        widget.onRevocation?.call(change.kind);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Prompt re-probe when the app returns from the background/system
  /// settings.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      AppScope.read(context)?.capabilityMonitor.probe();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
