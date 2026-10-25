import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../security/credentials/auth_type.dart';
import '../../../security/credentials/credential_manager.dart';
import '../security/credential_change_flow.dart';
import '../pattern/pattern_setup_screen.dart';

/// Change-pattern flow controller (Phase 2K).
///
/// Reuses the verified screens as steps:
/// ```
/// verify current pattern (PatternUnlockScreen) ──► set new pattern
///                                                  (PatternSetupScreen)
/// ```
/// Pops `true` when the new pattern was saved, `false` on cancel/back.
/// The current pattern must be drawn before anything can change.
///
/// CR-3: this is also the "add a pattern" flow. When no pattern exists but
/// a PIN does, the existing PIN is verified first. Only initial enrollment
/// (no app credential at all) skips verification. The write itself is
/// gated in the credential manager by the verified grant.
class PatternChangeScreen extends StatefulWidget {
  const PatternChangeScreen({super.key, this.credentialManager});

  /// Overrides the manager resolved from [AppScope] (tests/previews).
  final CredentialManager? credentialManager;

  static const String verifyTitle = 'Enter current pattern';
  static const String setupTitle = 'Set new pattern';

  @override
  State<PatternChangeScreen> createState() => _PatternChangeScreenState();
}

class _PatternChangeScreenState extends State<PatternChangeScreen> {
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
    // (the current pattern, or the PIN when no pattern is enrolled yet).
    // This replaces the old fall-through that let "add a pattern" skip
    // verification when only a PIN existed. Lockouts and attempt counting
    // are enforced by the manager and biometric is not accepted.
    final CredentialChangeGateResult gate =
        await verifyExistingCredentialForChange(
      navigator,
      manager,
      preferred: AuthType.pattern,
      patternTitle: PatternChangeScreen.verifyTitle,
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

    final bool replacingPattern = state.hasEnrolled(AuthType.pattern) &&
        gate.outcome == CredentialChangeGateOutcome.verified;
    final CredentialChangeSession? session = gate.authorization == null
        ? null
        : CredentialChangeSession(manager, gate.authorization!);
    _session = session;

    // Step 2: draw and confirm the new pattern.
    final MaterialPageRoute<bool> setupRoute = MaterialPageRoute<bool>(
      builder: (_) => replacingPattern
          ? PatternSetupScreen(
              credentialManager: session?.setupManager ?? manager,
              title: PatternChangeScreen.setupTitle,
            )
          : PatternSetupScreen(
              credentialManager: session?.setupManager ?? manager,
            ),
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
      appBar: AppBar(title: const Text('Change pattern')),
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
