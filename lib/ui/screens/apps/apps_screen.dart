import 'package:flutter/material.dart';

import '../../widgets/placeholder_screen.dart';

/// Apps tab — placeholder for the protected-apps list.
///
/// Coming phases: installed-apps browser (via `InstalledAppsService`),
/// search, category filters, and per-app lock toggles.
class AppsScreen extends StatelessWidget {
  const AppsScreen({super.key});

  static const String description =
      'Choose which apps to protect and manage your locked list.';

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      icon: Icons.apps,
      title: 'Apps',
      description: description,
      features: <String>[
        'Browse every installed app, with search',
        'Toggle the lock per app in one tap',
        'Filter by category or lock status',
        'Sort by name, size, or most used',
      ],
    );
  }
}
