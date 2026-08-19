import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';

/// Security tab — real UI built on the design system's security status
/// components.
///
/// States are static placeholders for now (nothing is configured yet);
/// the PIN and enforcement phases will feed real [SecurityLevel]s and wire
/// the "Set up PIN" action.
class SecurityScreen extends StatelessWidget {
  const SecurityScreen({super.key});

  static const String description =
      'Your PIN, intruder protection and advanced security controls.';

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
            onAction: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('PIN setup arrives in the next phase.'),
                ),
              );
            },
          ),
          const SizedBox(height: DsSpacing.xl),
          const DsSectionTitle('Protection controls'),
          const SizedBox(height: DsSpacing.md),
          const DsCard(
            padding: EdgeInsets.symmetric(vertical: DsSpacing.xs),
            child: Column(
              children: <Widget>[
                SecurityStatusItem(
                  icon: Icons.lock_outline,
                  title: 'Unlock PIN',
                  subtitle: 'Required to open protected apps',
                  level: SecurityLevel.notSet,
                ),
                Divider(),
                SecurityStatusItem(
                  icon: Icons.photo_camera_outlined,
                  title: 'Intruder selfie',
                  subtitle: 'Photograph anyone who enters a wrong PIN',
                  level: SecurityLevel.notSet,
                ),
                Divider(),
                SecurityStatusItem(
                  icon: Icons.notifications_active_outlined,
                  title: 'Break-in alerts',
                  subtitle: 'Get notified about blocked attempts',
                  level: SecurityLevel.notSet,
                ),
                Divider(),
                SecurityStatusItem(
                  icon: Icons.visibility_off_outlined,
                  title: 'Stealth mode',
                  subtitle: 'Hide the app lock from the launcher',
                  level: SecurityLevel.notSet,
                ),
                Divider(),
                SecurityStatusItem(
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
