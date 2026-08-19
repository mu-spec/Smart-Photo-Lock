import 'package:flutter/material.dart';

import '../../widgets/placeholder_screen.dart';

/// Security tab — placeholder for PIN management and protection controls.
///
/// Coming phases: PIN setup/change backed by `security/pin_hasher.dart`,
/// intruder selfie, break-in alerts, stealth mode, uninstall protection.
class SecurityScreen extends StatelessWidget {
  const SecurityScreen({super.key});

  static const String description =
      'Your PIN, intruder protection and advanced security controls.';

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      icon: Icons.shield,
      title: 'Security',
      description: description,
      features: <String>[
        'Set or change your unlock PIN',
        'Intruder selfie on wrong PIN attempts',
        'Break-in alerts',
        'Stealth mode & uninstall protection',
      ],
    );
  }
}
