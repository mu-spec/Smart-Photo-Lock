import 'package:flutter/widgets.dart';

/// Phase 7 / M3 — turns app lifecycle transitions into health refresh
/// requests for a screen that shows Protection Health (Home, details).
///
/// Event driven only: no timer, no polling. The owning screen decides
/// whether it is visible and asks the shared monitor for one coalesced
/// refresh.
///
///  * `paused` / `hidden` / `detached` is a real leave (Android Settings,
///    Home press, screen off). The next `resumed` reports
///    `returned: true`, meaning state may have changed while away (the
///    caller requests an after-change refresh).
///  * `inactive` → `resumed` without a leave (notification shade, a
///    dialog, the native shield releasing focus) reports `returned: false`
///    (a plain refresh that joins any running check).
///  * A repeated `resumed` without an intermediate state is ignored.
///
/// Observational: it never starts protection, authorizes, or touches a
/// ticket or challenge; it only calls [onResumed].
class HealthResumeTrigger with WidgetsBindingObserver {
  HealthResumeTrigger({required this.onResumed});

  /// Called once per transition into `resumed`.
  final void Function({required bool returned}) onResumed;

  AppLifecycleState? _last;
  bool _leftSinceResume = false;
  bool _attached = false;

  /// Starts listening to the app lifecycle (idempotent).
  void attach() {
    if (_attached) return;
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
  }

  /// Stops listening (idempotent). Call from the owner's `dispose`.
  void detach() {
    if (!_attached) return;
    _attached = false;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final AppLifecycleState? previous = _last;
    _last = state;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _leftSinceResume = true;
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.resumed:
        if (previous == AppLifecycleState.resumed) return;
        final bool returned = _leftSinceResume;
        _leftSinceResume = false;
        onResumed(returned: returned);
    }
  }
}
