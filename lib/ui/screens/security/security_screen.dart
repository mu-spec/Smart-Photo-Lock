import 'package:flutter/material.dart';

import '../../../app/app_container.dart';
import '../../../app/app_scope.dart';
import '../../../app/router.dart';
import '../../../data/storage/preferences_store.dart';
import '../../../design_system/design_system.dart';
import '../../../security/credentials/auth_type.dart';
import '../../../security/credentials/biometric_options.dart';
import '../../../security/credentials/credential_manager.dart';
import '../../../services/accessibility_lock_service.dart';
import '../../../services/capability_monitor.dart';
import '../../../services/installed_apps_service.dart';
import '../../../services/overlay_lock_service.dart';
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

  static const String revokedTitle = 'A permission was revoked';
  static const String revokedMessage =
      'A capability Smart App Lock needs was turned off in system '
      'settings. Re-enable it to keep protection working.';

  /// Phase 4 UX: first-install / never-granted state banner.
  static const String setupRequiredTitle = 'Protection setup required';
  static const String setupRequiredMessage =
      'Smart App Lock needs a few Android permissions before app '
      'protection can work correctly.';
  static String readyCount(int n) => '$n of 3 ready';

  /// Phase 4 UX: healthy state banner (all three capabilities granted).
  static const String protectionReadyTitle = 'Protection ready';
  static const String protectionReadyMessage =
      'All required app-lock permissions are granted.';

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

class _SecurityScreenState extends State<SecurityScreen>
    with WidgetsBindingObserver {
  /// Cached settings (null while loading).
  bool? _randomized;
  bool? _patternVisible;
  bool _hasPin = false;
  bool _hasPattern = false;
  bool _biometricEnrolled = false;

  /// Phase 4B: usage-access capability state (false until loaded).
  bool _usageAccessGranted = false;

  /// Phase 4C: accessibility fallback state (false until loaded).
  bool _accessibilityEnabled = false;

  /// Phase 4D: overlay (draw-over-apps) capability state (false until
  /// loaded).
  bool _overlayGranted = false;

  /// Phase 4 UX: persisted grant history per capability (false until the
  /// capability has been observed granted at least once). Combined with
  /// the LIVE state this distinguishes first-install setup (never
  /// granted) from revocation (previously granted, now missing).
  bool _usageAccessEverGranted = false;
  bool _accessibilityEverGranted = false;
  bool _overlayEverGranted = false;

  /// A capability that was granted before and is now missing.
  bool get _hasRevokedCapability =>
      (!_usageAccessGranted && _usageAccessEverGranted) ||
      (!_accessibilityEnabled && _accessibilityEverGranted) ||
      (!_overlayGranted && _overlayEverGranted);

  /// At least one capability has NEVER been granted (fresh install or
  /// incomplete first-time setup).
  bool get _setupIncomplete =>
      (!_usageAccessGranted && !_usageAccessEverGranted) ||
      (!_accessibilityEnabled && !_accessibilityEverGranted) ||
      (!_overlayGranted && !_overlayEverGranted);

  /// All three required capabilities are currently granted.
  bool get _protectionReady =>
      _usageAccessGranted && _accessibilityEnabled && _overlayGranted;

  int get _readyCount =>
      (_usageAccessGranted ? 1 : 0) +
      (_accessibilityEnabled ? 1 : 0) +
      (_overlayGranted ? 1 : 0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadStatus();
    // Phase 4F: a revoked capability (detected anywhere) marks the tab
    // and the next status reload reflects it.
    AppScope.read(context)?.capabilityMonitor.changes.listen(
          (change) {
        if (!mounted || change.state != CapabilityState.revoked) {
          return;
        }
        // Re-classify from the live snapshot: the derived banner state
        // (setup vs revoked vs ready) is recomputed on every load.
        _loadStatus();
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Phase 4G repair: grants and revocations happen in the SYSTEM
  /// settings — when the app returns to the foreground the capability
  /// rows must reflect reality without an app restart. The setup flows
  /// and the capability monitor also refresh, but this keeps the
  /// Security tab itself current on every resume.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadStatus();
    }
  }

  Future<void> _loadStatus() async {
    final AppContainer? container = AppScope.read(context);
    if (container == null) {
      return; // no container in scope (pure widget tests)
    }
    final CredentialManager auth = container.auth;
    // Phase 4F repair: resolve the shared capability bridges BEFORE any
    // await — BuildContext must never be read across an async gap.
    final InstalledAppsService installedApps = container.installedAppsService;
    final AccessibilityLockService accessibility = container.accessibility;
    final OverlayLockService overlay = container.overlay;
    final PreferencesStore preferences = container.preferences;

    final state = (await auth.status()).valueOrNull;
    if (!mounted || state == null) {
      return;
    }
    // Phase 4B: usage-access capability state, read from the SAME shared
    // service the lock engine will use.
    bool usageAccessGranted = false;
    final Result<bool> usage = await installedApps.hasUsageAccess();
    usageAccessGranted = usage.isSuccess && usage.valueOrNull == true;
    // Phase 4C: accessibility fallback state from the shared bridge.
    bool accessibilityEnabled = false;
    final Result<bool> accessibilityState =
        await accessibility.isServiceEnabled();
    accessibilityEnabled =
        accessibilityState.isSuccess && accessibilityState.valueOrNull == true;
    // Phase 4D: overlay capability state from the shared bridge.
    bool overlayGranted = false;
    final Result<bool> overlayState = await overlay.canDrawOverlays();
    overlayGranted = overlayState.isSuccess && overlayState.valueOrNull == true;

    // Phase 4 UX: grant history — a capability observed granted is
    // recorded (idempotent) and counted as ever-granted; a missing
    // capability reads its persisted history to classify setup vs
    // revocation.
    bool usageEver = usageAccessGranted;
    if (usageAccessGranted) {
      await preferences.markCapabilityEverGranted('usageAccess');
    } else {
      usageEver = await preferences.wasCapabilityEverGranted('usageAccess');
    }
    bool accessibilityEver = accessibilityEnabled;
    if (accessibilityEnabled) {
      await preferences.markCapabilityEverGranted('accessibility');
    } else {
      accessibilityEver =
          await preferences.wasCapabilityEverGranted('accessibility');
    }
    bool overlayEver = overlayGranted;
    if (overlayGranted) {
      await preferences.markCapabilityEverGranted('overlay');
    } else {
      overlayEver = await preferences.wasCapabilityEverGranted('overlay');
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
      _accessibilityEnabled = accessibilityEnabled;
      _overlayGranted = overlayGranted;
      _usageAccessEverGranted = usageEver;
      _accessibilityEverGranted = accessibilityEver;
      _overlayEverGranted = overlayEver;
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

  /// Phase 4C: opens the accessibility setup flow (disclosure → system
  /// settings → recheck), then refreshes the capability state.
  Future<void> _onAccessibilityTap() async {
    final container = AppScope.read(context);
    if (container == null) {
      return;
    }
    await Navigator.of(context).pushNamed(RouteNames.accessibilitySetup);
    if (mounted) {
      await _loadStatus();
    }
  }

  /// Phase 4E: opens the centralized permission setup (Enabled / Action
  /// Required overview), then refreshes capability state.
  Future<void> _onPermissionSetupTap() async {
    final container = AppScope.read(context);
    if (container == null) {
      return;
    }
    await Navigator.of(context).pushNamed(RouteNames.permissionSetup);
    if (mounted) {
      await _loadStatus();
    }
  }

  /// Phase 4D: opens the overlay setup flow (disclosure → system
  /// settings → recheck), then refreshes the capability state.
  Future<void> _onOverlayTap() async {
    final container = AppScope.read(context);
    if (container == null) {
      return;
    }
    await Navigator.of(context).pushNamed(RouteNames.overlaySetup);
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
    final ThemeData theme = Theme.of(context);
    return SafeArea(
      child: ListView(
        padding: DsInsets.screen,
        children: <Widget>[
          const DsSectionTitle('Security status'),
          const SizedBox(height: DsSpacing.md),
          if (_hasRevokedCapability) ...<Widget>[
            SecurityStatusBanner(
              level: SecurityLevel.vulnerable,
              title: SecurityScreen.revokedTitle,
              message: SecurityScreen.revokedMessage,
              actionLabel: 'Review permissions',
              onAction: _onPermissionSetupTap,
            ),
            const SizedBox(height: DsSpacing.md),
          ],
          // Phase 4 UX: first-install / incomplete setup — capabilities
          // that have NEVER been granted. Distinct from the revocation
          // banner above (previously granted, now missing).
          if (!_hasRevokedCapability && _setupIncomplete) ...<Widget>[
            SecurityStatusBanner(
              level: SecurityLevel.atRisk,
              title: SecurityScreen.setupRequiredTitle,
              message: SecurityScreen.setupRequiredMessage,
              actionLabel: 'Set up',
              onAction: _onPermissionSetupTap,
              footer: Text(
                SecurityScreen.readyCount(_readyCount),
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: DsSpacing.md),
          ],
          // Phase 4 UX: healthy state — all three required capabilities
          // granted.
          if (!_hasRevokedCapability && _protectionReady) ...<Widget>[
            SecurityStatusBanner(
              level: SecurityLevel.secured,
              title: SecurityScreen.protectionReadyTitle,
              message: SecurityScreen.protectionReadyMessage,
            ),
            const SizedBox(height: DsSpacing.md),
          ],
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
          Row(
            children: <Widget>[
              DsDotBadge(show: _hasRevokedCapability),
              const SizedBox(width: DsSpacing.xs),
              Expanded(
                child: DsSectionTitle(
                  'App lock permissions',
                  actionLabel: 'Set up',
                  onAction: _onPermissionSetupTap,
                ),
              ),
            ],
          ),
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
                const Divider(),
                SecurityStatusItem(
                  icon: Icons.accessibility_new,
                  title: 'Accessibility service',
                  subtitle: 'Detection fallback if usage access is off',
                  level: _accessibilityEnabled
                      ? SecurityLevel.secured
                      : SecurityLevel.notSet,
                  statusLabel: _accessibilityEnabled ? 'Enabled' : 'Needed',
                  onTap: _onAccessibilityTap,
                ),
                const Divider(),
                SecurityStatusItem(
                  icon: Icons.layers,
                  title: 'Draw over apps',
                  subtitle: 'Shows the lock screen over protected apps',
                  level: _overlayGranted
                      ? SecurityLevel.secured
                      : SecurityLevel.notSet,
                  statusLabel: _overlayGranted ? 'Enabled' : 'Needed',
                  onTap: _onOverlayTap,
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
