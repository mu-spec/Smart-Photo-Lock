import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../design_system/design_system.dart';
import '../../../security/credentials/auth_type.dart';
import '../../../security/credentials/credential_manager.dart';
import '../pattern/pattern_setup_screen.dart';
import '../pattern/pattern_unlock_screen.dart';

/// Change-pattern flow controller (Phase 2K).
///
/// Reuses the verified screens as steps:
/// ```
/// verify current pattern (PatternUnlockScreen) ──► set new pattern
///                                                  (PatternSetupScreen)
/// ```
/// Pops `true` when the new pattern was saved, `false` on cancel/back.
/// The current pattern must be drawn before anything can change.
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
    if (state == null || !state.hasEnrolled(AuthType.pattern)) {
      final bool? ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => PatternSetupScreen(credentialManager: _manager),
        ),
      );
      if (mounted) {
        Navigator.of(context).pop(ok ?? false);
      }
      return;
    }

    // Step 1: verify the current pattern (direction-independent; lockouts
    // and attempt counting enforced by the unlock screen).
    final bool? verified = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => PatternUnlockScreen(
          credentialManager: _manager,
          title: PatternChangeScreen.verifyTitle,
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

    // Step 2: draw and confirm the new pattern.
    final bool? changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => PatternSetupScreen(
          credentialManager: _manager,
          title: PatternChangeScreen.setupTitle,
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
