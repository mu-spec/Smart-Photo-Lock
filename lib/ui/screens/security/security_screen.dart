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
/// PIN is enrolled yet). The "Randomized keypad" toggle (Phase 2G) is the
/// first live security option — it persists through [CredentialManager].
/// The other control rows stay static until their feature phases.
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});

  static const String description =
      'Your PIN, intruder protection and advanced security controls.';

  static const String randomizedTitle = 'Randomized keypad';
  static const String randomizedSubtitle =
      'Shuffle PIN digits on the unlock screen';

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  /// Cached value of the randomized-keypad setting (null while loading).
  bool? _randomized;

  @override
  void initState() {
    super.initState();
    _loadRandomized();
  }

  Future<void> _loadRandomized() async {
    final auth = AppScope.read(context)?.auth;
    if (auth == null) {
      return; // no container in scope (pure widget tests)
    }
    final state = (await auth.status()).valueOrNull;
    if (!mounted || state == null) {
      return;
    }
    setState(() => _randomized = state.randomizedKeypadEnabled);
  }

  Future<void> _setRandomized(bool value) async {
    setState(() => _randomized = value); // optimistic
    final auth = AppScope.read(context)?.auth;
    if (auth == null) {
      setState(() => _randomized = !value);
      return;
    }
    final result = await auth.setRandomizedKeypadEnabled(value);
    if (!mounted) {
      return;
    }
    if (result.isFailure) {
      setState(() => _randomized = !value); // revert
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save the setting.')),
      );
    }
  }

  /// Handles the "Pattern unlock" row: opens pattern setup when nothing is
  /// enrolled; otherwise hints at the upcoming unlock screen (next phase).
  Future<void> _onPatternTap() async {
    final auth = AppScope.read(context)?.auth;
    if (auth == null) {
      return;
    }
    final state = (await auth.status()).valueOrNull;
    if (!mounted) {
      return;
    }
    if (state == null || !state.hasEnrolled(AuthType.pattern)) {
      await Navigator.of(context).pushNamed(RouteNames.patternSetup);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Pattern unlock arrives in the next phase.')),
    );
  }

  /// Handles the "Unlock PIN" row: routes to setup when nothing is
  /// enrolled, otherwise opens the unlock challenge.
  Future<void> _onUnlockPinTap() async {
    final auth = AppScope.read(context)?.auth;
    if (auth == null) {
      return;
    }
    final state = (await auth.status()).valueOrNull;
    if (!mounted) {
      return;
    }
    if (state == null || !state.hasEnrolled(AuthType.pin)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Set up a PIN first.')),
      );
      return;
    }
    final bool? unlocked =
        await Navigator.of(context).pushNamed<bool>(RouteNames.pinUnlock);
    if (!mounted || unlocked != true) {
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
            message: SecurityScreen.description,
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
                  onTap: _onUnlockPinTap,
                ),
                const Divider(),
                SecurityStatusItem(
                  icon: Icons.gesture,
                  title: 'Pattern unlock',
                  subtitle: 'Alternative to PIN — draw on a 3x3 grid',
                  level: SecurityLevel.notSet,
                  onTap: _onPatternTap,
                ),
                const Divider(),
                _SwitchRow(
                  icon: Icons.shuffle,
                  title: SecurityScreen.randomizedTitle,
                  subtitle: SecurityScreen.randomizedSubtitle,
                  value: _randomized ?? false,
                  onChanged: _randomized == null ? null : _setRandomized,
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

/// Control row with a trailing [Switch] (used for live security options).
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: DsSpacing.lg,
        vertical: DsSpacing.sm + 2,
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: palette.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(DsRadii.md),
            ),
            child: Icon(icon, size: 20, color: palette.primary),
          ),
          const SizedBox(width: DsSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: DsSpacing.sm),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: palette.primary,
          ),
        ],
      ),
    );
  }
}
