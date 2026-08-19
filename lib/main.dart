import 'package:flutter/material.dart';

/// Smart App Lock — Phase 1A placeholder.
///
/// This file exists so the freshly created project compiles and runs.
/// It will be replaced by the real feature structure in later phases
/// (onboarding, PIN setup, app list, lock service, ...).
void main() {
  runApp(const SmartAppLockApp());
}

/// Root widget of the application.
class SmartAppLockApp extends StatelessWidget {
  const SmartAppLockApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart App Lock',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF101A3C), // brand navy
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0F1630),
        useMaterial3: true,
      ),
      home: const PlaceholderHomePage(),
    );
  }
}

/// Minimal placeholder screen that doubles as a build-config sanity check:
/// the app id and SDK levels printed here should match android/app/build.gradle.kts.
class PlaceholderHomePage extends StatelessWidget {
  const PlaceholderHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart App Lock'),
        backgroundColor: Colors.transparent,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_outline, size: 96, color: colorScheme.primary),
              const SizedBox(height: 24),
              Text(
                'Phase 1A complete',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Production Android project scaffold is ready.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 32),
              const _BuildInfoCard(
                rows: [
                  ('Application ID', 'com.smartapplock.app'),
                  ('minSdk', '24 (Android 7.0)'),
                  ('targetSdk', '36 (Android 16)'),
                  ('Build flavors', 'debug / release'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Simple card listing key build configuration values.
class _BuildInfoCard extends StatelessWidget {
  const _BuildInfoCard({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: [
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      label,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                    Text(
                      value,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
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
