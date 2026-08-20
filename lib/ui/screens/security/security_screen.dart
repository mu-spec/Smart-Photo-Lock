import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../app/router.dart';
import '../../../design_system/design_system.dart';
import '../../../security/credentials/auth_type.dart';
import '../../../security/credentials/biometric_options.dart';
import '../../../utilities/result.dart';

/// Security tab — the authentication settings surface (Phase 2K).
///
/// Lets the user:
///  * set up or **change the PIN** (verify current → set new),
///  * set up or **change the pattern**,
///  * enable/disable **biometric unlock** (2J, real capability checks),
///  * configure the **randomized keypad** (2G),
///  * configure **pattern visibility** (2K).
///
/// The remaining rows (intruder selfie, ...) stay static until their
/// feature phases.
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});

  static const String description =
      'Your PIN, intruder protection and advanced security controls.';

  static const String randomizedTitle = 'Randomized keypad';
  static const String randomizedSubtitle =
      'Shuffle PIN digits on the unlock screen';

  static const String patternVisibilityTitle = 'Visible pattern';
  static const String patternVisibilitySubtitle =
      'Show the drawing trail while unlocking';

  static const String setPinTitle = 'Set up PIN';
  static const String changePinTitle = 'Change PIN';
  static const String setPatternTitle = 'Set up pattern';
  static const String changePatternTitle = 'Change pattern';
  static const String pinChangedMessage = 'PIN changed ✓';
  static const String patternChangedMessage = 'Pattern changed ✓';
  static const String couldNotSaveMessage = 'Could not save the setting.';

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  /// Cached settings (null while loading).
  bool? _randomized;
  bool? _patternVisible;
  bool _hasPin = false;
  bool _hasPattern = false;
  bool _biometricEnrolled = false;

  /// Phase 4B: usage-access capability state (false until loaded).
  bool _usageAccessGranted = false;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    final auth = AppScope.read(context)?.auth;
    if (auth == null) {
      return; // no container in scope (pure widget tests)
    }
    final state = (await auth.status()).valueOrNull;
    if (!mounted || state == null) {
      return;
    }
    // Phase 4B: usage-access capability state, read from the SAME shared
    // service the lock engine will use.
    bool usageAccessGranted = false;
    final service = AppScope.read(context)?.installedAppsService;
    if (service != null) {
      final result = await service.hasUsageAccess();
      usageAccessGranted = result.isSuccess && result.valueOrNull == true;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _randomized = state.randomizedKeypadEnabled;
      _patternVisible = state.patternVisibilityEnabled;
      _hasPin = state.hasEnrolled(AuthType.pin);
      _hasPattern = state.hasEnrolled(AuthType.pattern);
      _biometricEnrolled = state.hasEnrolled(AuthType.biometric);
      _usageAccessGranted = usageAccessGranted;
    });
  }

  // -- PIN / pattern lifecycle ----------------------------------------------

  Future<void> _onPinTap() async {
    if (!_hasPin) {
      await Navigator.of(context).pushNamed(RouteNames.pinSetup);
      // Refresh after the setup fall-through so the row flips to
      // "Change PIN" the moment a PIN now exists.
      if (mounted) {
        await _loadStatus();
      }
      return;
    }
    final bool? changed =
        await Navigator.of(context).pushNamed<bool>(RouteNames.pinChange);
    if (!mounted || changed != true) {
      return;
    }
    // Refresh credential state (e.g. a new PIN length) instead of showing
    // stale values.
    await _loadStatus();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text(SecurityScreen.pinChangedMessage)),
    );
  }

  /// Phase 4B: opens the usage-access setup flow (detect → explain →
  /// settings → recheck), then refreshes the capability state.
  Future<void> _onUsageAccessTap() async {
    final container = AppScope.read(context);
    if (container == null) {
      return;
    }
    await Navigator.of(context).pushNamed(RouteNames.usageAccess);
    if (mounted) {
      await _loadStatus();
    }
  }

  Future<void> _onPatternTap() async {
    if (!_hasPattern) {
      await Navigator.of(context).pushNamed(RouteNames.patternSetup);
      // Refresh after the setup fall-through so the row flips to
      // "Change pattern" the moment a pattern now exists.
      if (mounted) {
        await _loadStatus();
      }
      return;
    }
    final bool? changed =
        await Navigator.of(context).pushNamed<bool>(RouteNames.patternChange);
    if (!mounted || changed != true) {
      return;
    }
    // Refresh credential state instead of showing stale values.
    await _loadStatus();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text(SecurityScreen.patternChangedMessage)),
    );
  }

  // -- toggles --------------------------------------------------------------

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
        const SnackBar(content: Text(SecurityScreen.couldNotSaveMessage)),
      );
    }
  }

  Future<void> _setPatternVisible(bool value) async {
    setState(() => _patternVisible = value); // optimistic
    final auth = AppScope.read(context)?.auth;
    if (auth == null) {
      setState(() => _patternVisible = !value);
      return;
    }
    final result = await auth.setPatternVisibilityEnabled(value);
    if (!mounted) {
      return;
    }
    if (result.isFailure) {
      setState(() => _patternVisible = !value); // revert
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(SecurityScreen.couldNotSaveMessage)),
      );
    }
  }

  // -- biometric (Phase 2J) -------------------------------------------------

  Future<void> _onBiometricTap() async {
    final container = AppScope.read(context);
    if (container == null) {
      return;
    }
    final auth = container.auth;
    final service = container.biometrics;

    if (_biometricEnrolled) {
      await auth.updateBiometricOptions(null); // disable
      if (!mounted) {
        return;
      }
      setState(() => _biometricEnrolled = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Biometric unlock disabled.')),
      );
      return;
    }

    final state = (await auth.status()).valueOrNull;
    if (state == null || !state.hasAnyCredential) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Set up a PIN or pattern first.')),
      );
      return;
    }

    final Result<bool> supported = await service.isSupported();
    if (!mounted) {
      return;
    }
    if (supported.isFailure || supported.valueOrNull != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Biometric authentication is not available '
              'on this device.'),
        ),
      );
      return;
    }

    final Set<BiometricKind> kinds =
        (await service.availableKinds()).valueOrNull ??
            const <BiometricKind>{};
    if (!mounted) {
      return;
    }
    final BiometricOptions options = BiometricOptions(
      allowStrongBiometrics: kinds.contains(BiometricKind.strong),
      allowDeviceCredential: kinds.contains(BiometricKind.deviceCredential),
      requireConfirmation: true,
    );
    await auth.updateBiometricOptions(options);
    if (!mounted) {
      return;
    }
    setState(() => _biometricEnrolled = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Biometric unlock enabled ✓')),
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
          const DsSectionTitle('Authentication'),
          const SizedBox(height: DsSpacing.md),
          DsCard(
            padding: const EdgeInsets.symmetric(vertical: DsSpacing.xs),
            child: Column(
              children: <Widget>[
                SecurityStatusItem(
                  icon: Icons.lock_outline,
                  title: _hasPin
                      ? SecurityScreen.changePinTitle
                      : SecurityScreen.setPinTitle,
                  subtitle: 'Required to open protected apps',
                  level: _hasPin
                      ? SecurityLevel.secured
                      : SecurityLevel.notSet,
                  statusLabel: _hasPin ? 'Set' : null,
                  onTap: _onPinTap,
                ),
                const Divider(),
                SecurityStatusItem(
                  icon: Icons.gesture,
                  title: _hasPattern
                      ? SecurityScreen.changePatternTitle
                      : SecurityScreen.setPatternTitle,
                  subtitle: 'Alternative to PIN — draw on a 3x3 grid',
                  level: _hasPattern
                      ? SecurityLevel.secured
                      : SecurityLevel.notSet,
                  statusLabel: _hasPattern ? 'Set' : null,
                  onTap: _onPatternTap,
                ),
                const Divider(),
                _SwitchRow(
                  icon: Icons.visibility_outlined,
                  title: SecurityScreen.patternVisibilityTitle,
                  subtitle: SecurityScreen.patternVisibilitySubtitle,
                  value: _patternVisible ?? true,
                  onChanged:
                      _patternVisible == null ? null : _setPatternVisible,
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
                SecurityStatusItem(
                  icon: Icons.fingerprint,
                  title: 'Biometric unlock',
                  subtitle:
                      'Fingerprint / face via the Android BiometricPrompt',
                  level: _biometricEnrolled
                      ? SecurityLevel.secured
                      : SecurityLevel.notSet,
                  statusLabel: _biometricEnrolled ? 'Enabled' : null,
                  onTap: _onBiometricTap,
                ),
              ],
            ),
          ),
          const SizedBox(height: DsSpacing.xl),
          const DsSectionTitle('App lock permissions'),
          const SizedBox(height: DsSpacing.md),
          DsCard(
            padding: const EdgeInsets.symmetric(vertical: DsSpacing.xs),
            child: Column(
              children: <Widget>[
                SecurityStatusItem(
                  icon: Icons.insights,
                  title: 'Usage access',
                  subtitle: 'Detect which app you open so it can be locked',
                  level: _usageAccessGranted
                      ? SecurityLevel.secured
                      : SecurityLevel.atRisk,
                  statusLabel: _usageAccessGranted ? 'Granted' : 'Needed',
                  onTap: _onUsageAccessTap,
                ),
              ],
            ),
          ),
          const SizedBox(height: DsSpacing.xl),
          const DsSectionTitle('Advanced protection'),
          const SizedBox(height: DsSpacing.md),
          const DsCard(
            padding: EdgeInsets.symmetric(vertical: DsSpacing.xs),
            child: Column(
              children: <Widget>[
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
