import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../design_system/design_system.dart';
import '../../../services/overlay_lock_service.dart';

/// Overlay ("Draw over apps") setup screen (Phase 4D).
///
/// The draw-over-apps capability is what lets the lock screen appear on
/// top of any protected app — the entire enforcement surface. This screen
/// follows the same capability flow as Usage Access (4B) and
/// Accessibility (4C):
///
///  1. **detect status** — probes `Settings.canDrawOverlays`;
///  2. **explain purpose** — prominent disclosure of the single use;
///  3. **send the user to the right Android settings**;
///  4. **detect successful return** — re-checks on app resume.
class OverlaySetupScreen extends StatefulWidget {
  const OverlaySetupScreen({
    super.key,
    this.service,
    this.title = 'Draw over apps',
  });

  /// Overrides the service resolved from [AppScope] (tests/previews).
  final OverlayLockService? service;

  final String title;

  static const String notGrantedTitle = 'Draw over apps is off';
  static const String disclosureTitle =
      'Why Smart App Lock needs Draw over apps';
  static const String disclosureBody =
      'Smart App Lock shows its lock screen on top of the app you open. '
      'To do that, Android requires the draw-over-other-apps permission.';
  static const String disclosureNever =
      'It is used only to display the lock screen — never to cover or '
      'change anything else on your device.';
  static const String notUsedElsewhere = 'Used only for the lock screen.';
  static const String openSettingsLabel = 'Open Settings';
  /// Granted-state secondary action: reopen the same system settings
  /// destination so the user can always manage (or revoke) the grant.
  static const String manageSettingsLabel = 'Manage Settings';
  static const String settingsNote =
      'Android will open the draw-over-apps screen — allow Smart App '
      'Lock, then come back.';
  static const String grantedTitle = 'Draw over apps enabled';
  static const String grantedMessage =
      'The lock screen can now appear over protected apps.';
  static const String doneLabel = 'Done';
  static const String unavailableTitle = 'Could not check draw-over-apps';
  static const String unavailableMessage =
      'Smart App Lock could not read the overlay permission state. Please '
      'try again.';
  static const String retryLabel = 'Retry';

  @override
  State<OverlaySetupScreen> createState() => _OverlaySetupScreenState();
}

enum _OverlayState { checking, granted, notGranted, unavailable }

class _OverlaySetupScreenState extends State<OverlaySetupScreen>
    with WidgetsBindingObserver {
  _OverlayState _state = _OverlayState.checking;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  OverlayLockService get _service =>
      widget.service ?? AppScope.read(context)!.overlay;

  /// Step 4: the user returns from the system settings — re-probe.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _check();
    }
  }

  Future<void> _check() async {
    final OverlayLockService service;
    try {
      service = _service;
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _state = _OverlayState.unavailable);
      return;
    }
    final result = await service.canDrawOverlays();
    if (!mounted) {
      return;
    }
    setState(() {
      if (result.isFailure) {
        _state = _OverlayState.unavailable;
      } else if (result.valueOrNull == true) {
        _state = _OverlayState.granted;
      } else {
        _state = _OverlayState.notGranted;
      }
    });
  }

  Future<void> _openSettings() async {
    final result = await _service.requestOverlayPermission();
    if (!mounted) {
      return;
    }
    if (result.isFailure) {
      setState(() => _state = _OverlayState.unavailable);
      return;
    }
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: switch (_state) {
            _OverlayState.checking => const Center(
                key: ValueKey<String>('checking'),
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            _OverlayState.granted => _buildGranted(),
            _OverlayState.notGranted => _buildNotGranted(),
            _OverlayState.unavailable => _buildUnavailable(),
          },
        ),
      ),
    );
  }

  Widget _buildGranted() {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    return ListView(
      key: const ValueKey<String>('granted'),
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      children: <Widget>[
        Center(
          child: Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: palette.success.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(
                color: palette.success.withValues(alpha: 0.4),
              ),
            ),
            child: Icon(Icons.check_rounded, size: 44, color: palette.success),
          ),
        ),
        const SizedBox(height: DsSpacing.xl),
        Center(
          child: Text(
            OverlaySetupScreen.grantedTitle,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        Center(
          child: Text(
            OverlaySetupScreen.grantedMessage,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: DsSpacing.xxl),
        // The user can always return to the system overlay-permission
        // screen — essential on OEM devices where the setting is hard to
        // find.
        DsButton(
          key: const Key('overlay_manage_settings'),
          label: OverlaySetupScreen.manageSettingsLabel,
          variant: DsButtonVariant.secondary,
          expand: true,
          onPressed: _openSettings,
        ),
        const SizedBox(height: DsSpacing.md),
        DsButton(
          label: OverlaySetupScreen.doneLabel,
          expand: true,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }

  /// The prominent disclosure view (Step 2 of the flow).
  Widget _buildNotGranted() {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    return ListView(
      key: const ValueKey<String>('not_granted'),
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      children: <Widget>[
        Center(
          child: Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: palette.warning.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(
                color: palette.warning.withValues(alpha: 0.4),
              ),
            ),
            child: Icon(Icons.layers, size: 40, color: palette.warning),
          ),
        ),
        const SizedBox(height: DsSpacing.xl),
        Center(
          child: Text(
            OverlaySetupScreen.notGrantedTitle,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: DsSpacing.lg),
        // -- The disclosure card: the exact reason, and the exact non-uses.
        DsCard(
          title: OverlaySetupScreen.disclosureTitle,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                OverlaySetupScreen.disclosureBody,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: DsSpacing.sm),
              Text(
                OverlaySetupScreen.disclosureNever,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: palette.textSecondary,
                ),
              ),
              const SizedBox(height: DsSpacing.md),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: DsSpacing.md,
                  vertical: DsSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: palette.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(DsRadii.md),
                ),
                child: Text(
                  OverlaySetupScreen.notUsedElsewhere,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: palette.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: DsSpacing.xl),
        DsButton(
          key: const Key('overlay_open_settings'),
          label: OverlaySetupScreen.openSettingsLabel,
          expand: true,
          onPressed: _openSettings,
        ),
        const SizedBox(height: DsSpacing.lg),
        Center(
          child: Text(
            OverlaySetupScreen.settingsNote,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.textSecondary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildUnavailable() {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    return ListView(
      key: const ValueKey<String>('unavailable'),
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      children: <Widget>[
        Center(
          child: Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: palette.danger.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(
                color: palette.danger.withValues(alpha: 0.4),
              ),
            ),
            child: Icon(Icons.error_outline, size: 40, color: palette.danger),
          ),
        ),
        const SizedBox(height: DsSpacing.xl),
        Center(
          child: Text(
            OverlaySetupScreen.unavailableTitle,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        Center(
          child: Text(
            OverlaySetupScreen.unavailableMessage,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: DsSpacing.xxl),
        DsButton(
          label: OverlaySetupScreen.retryLabel,
          expand: true,
          onPressed: _check,
        ),
      ],
    );
  }
}
