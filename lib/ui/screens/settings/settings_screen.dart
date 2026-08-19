import 'package:flutter/material.dart';

import '../../widgets/placeholder_screen.dart';

/// Settings tab — placeholder for app preferences.
///
/// Coming phases: appearance options, backup & restore, notifications,
/// language, and about/support.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const String description =
      'Tune Smart App Lock to behave exactly how you want.';

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      icon: Icons.settings,
      title: 'Settings',
      description: description,
      features: <String>[
        'Appearance & theme options',
        'Backup & restore your locks',
        'Language & notifications',
        'About & support',
      ],
    );
  }
}
