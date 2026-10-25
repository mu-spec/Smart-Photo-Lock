import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../security/credentials/auth_type.dart';
import '../../../security/credentials/credential_manager.dart';
import '../security/credential_change_flow.dart';
import 'pin_setup_screen.dart';

/// Change-PIN flow controller (Phase 2K).
///
/// Reuses the verified screens as steps:
/// ```
/// verify current PIN (PinUnlockScreen) ──► set new PIN (PinSetupScreen)
/// ```
/// Pops `true` when the new PIN was saved, `false` on cancel/back. The
/// current PIN must be entered before anything can change — no bypass.
///
/// CR-3: this is also the "add a PIN" flow. When no PIN exists but a
/// pattern does, the existing pattern is verified first. Only initial
/// enrollment (no app credential at all) skips verification. The write
/// itself is gated in the credential manager by the verified grant.
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

  /// CR-3: owns the verified grant while the setup step is open.
  CredentialChangeSession? _session;

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

    final CredentialManager manager = _manager;
    final NavigatorState navigator = Navigator.of(context);
    final state = (await manager.status()).valueOrNull;
    if (!mounted) {
      return;
    }
    if (state == null) {
      // Fail closed: the credential status could not be read.
      navigator.pop(false);
      return;
    }

    // CR-3 step 1: when ANY app credential exists, verify an existing one
    // (the current PIN, or the pattern when no PIN is enrolled yet). This
    // replaces the old fall-through that let "add a PIN" skip verification
    // when only a pattern existed. Biometric is not accepted. The
    // manager-issued grant is the only thing the write gate trusts.
    final CredentialChangeGateResult gate =
        await verifyExistingCredentialForChange(
      navigator,
      manager,
      preferred: AuthType.pin,
      pinTitle: PinChangeScreen.verifyTitle,
    );
    if (!mounted) {
      final authorization = gate.authorization;
      if (authorization != null) {
        manager.revokeCredentialChangeAuthorization(authorization);
      }
      return;
    }
    if (gate.outcome == CredentialChangeGateOutcome.denied) {
      navigator.pop(false);
      return;
    }

    final bool replacingPin = state.hasEnrolled(AuthType.pin) &&
        gate.outcome == CredentialChangeGateOutcome.verified;
    final CredentialChangeSession? session = gate.authorization == null
        ? null
        : CredentialChangeSession(manager, gate.authorization!);
    _session = session;

    // Step 2: set the new PIN. A replacement keeps the current length (the
    // user can still change it via the length step).
    final MaterialPageRoute<bool> setupRoute = MaterialPageRoute<bool>(
      builder: (_) => replacingPin
          ? PinSetupScreen(
              credentialManager: session?.setupManager ?? manager,
              initialLength: state.pinLength ?? 4,
              title: PinChangeScreen.setupTitle,
            )
          : PinSetupScreen(credentialManager: session?.setupManager ?? manager),
    );
    session?.attach(navigator, setupRoute);
    final bool? changed = await navigator.push<bool>(setupRoute);
    session?.end();
    _session = null;
    if (!mounted) {
      return;
    }
    navigator.pop(changed ?? false);
  }

  @override
  void dispose() {
    _session?.end();
    super.dispose();
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
