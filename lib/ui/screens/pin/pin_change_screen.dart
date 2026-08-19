import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../security/credentials/auth_type.dart';
import '../../../security/credentials/credential_manager.dart';
import 'pin_setup_screen.dart';
import 'pin_unlock_screen.dart';

/// Change-PIN flow controller (Phase 2K).
///
/// Reuses the verified screens as steps:
/// ```
/// verify current PIN (PinUnlockScreen) ──► set new PIN (PinSetupScreen)
/// ```
/// Pops `true` when the new PIN was saved, `false` on cancel/back. The
/// current PIN must be entered before anything can change — no bypass.
class PinChangeScreen extends StatefulWidget {
  const PinChangeScreen({super.key, this.credentialManager});

  /// Overrides the manager resolved from [AppScope] (tests/previews).
  final CredentialManager? credentialManager;

  static const String verifyTitle = 'Enter current PIN';
  static const String setupTitle = 'Set new PIN';

  @override
  State<PinChangeScreen> createState() => _PinChangeScreenState();
}

class _PinChangeScreenState extends State<PinChangeScreen> {
  bool _started = false;

  CredentialManager get _manager =>
      widget.credentialManager ?? AppScope.read(context)!.auth;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    if (_started) {
      return;
    }
    _started = true;

    final state = (await _manager.status()).valueOrNull;
    if (!mounted) {
      return;
    }
    // Nothing to change: fall through to initial setup.
    if (state == null || !state.hasEnrolled(AuthType.pin)) {
      final bool? ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => PinSetupScreen(credentialManager: _manager),
        ),
      );
      if (mounted) {
        Navigator.of(context).pop(ok ?? false);
      }
      return;
    }

    final int length = state.pinLength ?? 4;

    // Step 1: verify the current PIN (lockouts/attempts enforced here).
    final bool? verified = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => PinUnlockScreen(
          credentialManager: _manager,
          title: PinChangeScreen.verifyTitle,
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    if (verified != true) {
      Navigator.of(context).pop(false);
      return;
    }

    // Step 2: set the new PIN (keeps the current length; the user can
    // still change it via the length step).
    final bool? changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => PinSetupScreen(
          credentialManager: _manager,
          initialLength: length,
          title: PinChangeScreen.setupTitle,
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(changed ?? false);
  }

  @override
  Widget build(BuildContext context) {
    // The flow takes over immediately; this scaffold is only visible for
    // the instant it takes to push the first step.
    return Scaffold(
      appBar: AppBar(title: const Text('Change PIN')),
      body: const SafeArea(
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      ),
    );
  }
}
