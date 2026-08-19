import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../widgets/module_card.dart';

/// Phase 1B home screen — architecture overview dashboard.
///
/// Lists the eight feature modules and their current status. Real feature
/// screens (PIN setup, app list, lock challenge, ...) replace this dashboard
/// in later phases.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  /// Exact label used by the header chip (also asserted in widget tests).
  static const String phaseLabel = 'Phase 1B — Core Architecture';

  static const List<ModuleInfo> _modules = <ModuleInfo>[
    ModuleInfo(
      icon: Icons.dashboard,
      title: 'UI',
      description: 'Screens & shared widgets',
      path: 'lib/ui',
    ),
    ModuleInfo(
      icon: Icons.storage,
      title: 'Data',
      description: 'Models & repositories',
      path: 'lib/data',
    ),
    ModuleInfo(
      icon: Icons.shield,
      title: 'Security',
      description: 'PIN hashing & policies',
      path: 'lib/security',
    ),
    ModuleInfo(
      icon: Icons.lock_outline,
      title: 'Protection',
      description: 'Lock engine & access control',
      path: 'lib/protection',
    ),
    ModuleInfo(
      icon: Icons.rule,
      title: 'Rules',
      description: 'Lock rule evaluation',
      path: 'lib/rules',
    ),
    ModuleInfo(
      icon: Icons.category,
      title: 'Profiles',
      description: 'Lock profiles',
      path: 'lib/profiles',
    ),
    ModuleInfo(
      icon: Icons.settings_input_component,
      title: 'Services',
      description: 'Android platform bridges',
      path: 'lib/services',
    ),
    ModuleInfo(
      icon: Icons.build,
      title: 'Utilities',
      description: 'Logger, Result, time helpers',
      path: 'lib/utilities',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Smart App Lock')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: <Widget>[
            const _Header(),
            const SizedBox(height: 24),
            Text('Architecture modules', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            for (final ModuleInfo info in _modules)
              ModuleCard(info: info, status: 'Scaffolded'),
            const SizedBox(height: 16),
            const _BuildInfoCard(),
          ],
        ),
      ),
    );
  }
}

/// Header: brand mark, phase chip, and a short status note.
class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      children: <Widget>[
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.12),
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
          ),
          child: const Icon(Icons.lock_outline, size: 36, color: AppColors.accent),
        ),
        const SizedBox(height: 16),
        Text('Smart App Lock', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
          ),
          child: const Text(
            HomeScreen.phaseLabel,
            style: TextStyle(
              color: AppColors.accent,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Foundation layers are in place. Lock enforcement is intentionally '
          'not implemented yet — it arrives in the later phases.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// Compact build-configuration summary card.
class _BuildInfoCard extends StatelessWidget {
  const _BuildInfoCard();

  static const List<(String, String)> _rows = <(String, String)>[
    ('Application ID', 'com.smartapplock.app'),
    ('minSdk / targetSdk', '24 / 36'),
    ('Version', '0.2.0+2'),
    ('Phase', '1B'),
  ];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: <Widget>[
            for (final (String label, String value) in _rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Text(
                      label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    Text(
                      value,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
