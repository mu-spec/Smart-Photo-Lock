import 'package:flutter/material.dart';

import '../../widgets/placeholder_screen.dart';

/// Smart tab — placeholder for the automation layer.
///
/// Coming phases: auto-lock triggers built on the `rules` module —
/// screen-off locking, time windows, launch limits, usage insights.
class SmartScreen extends StatelessWidget {
  const SmartScreen({super.key});

  static const String description =
      'Automations that lock apps at the right moment, automatically.';

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      icon: Icons.auto_awesome,
      title: 'Smart',
      description: description,
      features: <String>[
        'Lock everything when the screen turns off',
        'Time-window rules (e.g. lock at night)',
        'Launch-limit mode for focus',
        'Usage insights per protected app',
      ],
    );
  }
}
