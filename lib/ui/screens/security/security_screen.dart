import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../app/router.dart';
import '../../../design_system/design_system.dart';
import '../../../security/credentials/auth_type.dart';

/// Security tab — real UI built on the design system's security status
/// components.
///
/// The "Set up PIN" banner opens the Phase 2B setup flow; tapping the
/// "Unlock PIN" row opens the Phase 2E unlock screen (with a hint when no
/// PIN is enrolled yet). The other control rows stay static until their
/// feature phases wire real status.
class SecurityScreen extends StatelessWidget {
  const SecurityScreen({super.key});

  static const String description =
      'Your PIN, intruder protection and advanced security controls.';

  /// Handles the "Unlock PIN" row: routes to setup when nothing is
  /// enrolled, otherwise opens the unlock challenge.
  Future<void> _onUnlockPinTap(BuildContext context) async {
    final auth = AppScope.read(context)?.auth;
    if (auth == null) {
      return; // no container in scope (pure widget tests)
    }
    final state = (await auth.status()).valueOrNull;
    if (!context.mounted) {
      return;
    }
    if (state == null || !state.hasEnrolled(AuthType.pin)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Set up a PIN first.')),
      );
      return;
    }
    final bool? unlocked = await Navigator.of(context)
        .pushNamed<bool>(RouteNames.pinUnlock);
    if (!context.mounted || unlocked != true) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Authenticated ✓')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: DsInsets.screen,
        children: <Widget>[
          const DsSectionTitle('Security status'),
          const SizedBox(height: DsSpacing.md),
          SecurityStatusBanner(
            level: SecurityLevel.atRisk,
            title: 'Protection is not fully set up',
            message: description,
            actionLabel: 'Set up PIN',
            onAction: () =>
                Navigator.of(context).pushNamed(RouteNames.pinSetup),
          ),
          const SizedBox(height: DsSpacing.xl),
          const DsSectionTitle('Protection controls'),
          const SizedBox(height: DsSpacing.md),
          DsCard(
            padding: const EdgeInsets.symmetric(vertical: DsSpacing.xs),
            child: Column(
              children: <Widget>[
                SecurityStatusItem(
                  icon: Icons.lock_outline,
                  title: 'Unlock PIN',
                  subtitle: 'Required to open protected apps',
                  level: SecurityLevel.notSet,
                  onTap: () => _onUnlockPinTap(context),
                ),
                const Divider(),
                const SecurityStatusItem(
                  icon: Icons.photo_camera_outlined,
                  title: 'Intruder selfie',
                  subtitle: 'Photograph anyone who enters a wrong PIN',
                  level: SecurityLevel.notSet,
                ),
                const Divider(),
                const SecurityStatusItem(
                  icon: Icons.notifications_active_outlined,
                  title: 'Break-in alerts',
                  subtitle: 'Get notified about blocked attempts',
                  level: SecurityLevel.notSet,
                ),
                const Divider(),
                const SecurityStatusItem(
                  icon: Icons.visibility_off_outlined,
                  title: 'Stealth mode',
                  subtitle: 'Hide the app lock from the launcher',
                  level: SecurityLevel.notSet,
                ),
                const Divider(),
                const SecurityStatusItem(
                  icon: Icons.block_outlined,
                  title: 'Uninstall protection',
                  subtitle: 'Stop the app being removed while locks are active',
                  level: SecurityLevel.notSet,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
