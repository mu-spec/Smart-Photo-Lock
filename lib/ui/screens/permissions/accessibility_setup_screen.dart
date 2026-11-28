import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../design_system/design_system.dart';
import '../../../services/accessibility_lock_service.dart';

/// Accessibility setup screen (Phase 4C).
///
/// Accessibility is used for ONE purpose only — early app-window detection —
/// and this screen says so prominently before asking the user for
/// anything:
///
///  1. **detect status** — probes ENABLED_ACCESSIBILITY_SERVICES through
///     the shared [AccessibilityLockService];
///  2. **prominent disclosure** — exactly why the service is used, and
///     what it is NEVER used for;
///  3. **send the user to the right Android settings**;
///  4. **detect successful return** — re-checks on app resume.
class AccessibilitySetupScreen extends StatefulWidget {
  const AccessibilitySetupScreen({
    super.key,
    this.service,
    this.title = 'Accessibility service',
  });

  /// Overrides the service resolved from [AppScope] (tests/previews).
  final AccessibilityLockService? service;

  final String title;

  static const String notEnabledTitle = 'Accessibility is off';
  static const String disclosureTitle = 'Why Smart App Lock uses Accessibility';
  static const String disclosureBody =
      'Smart App Lock uses the Android Accessibility service for one '
      'purpose only: to notice which app has just opened, so it can lock '
      'the apps you chose to protect right away.\n\n'
      'While the service is on, even when Smart App Lock is closed, Android '
      'tells Smart App Lock the app name (package name, for example '
      'com.example.app) and the window type each time an app window opens. '
      'Smart App Lock checks the app name against your protected apps on '
      'this phone and shows the lock screen when it matches. Without it, '
      'Smart App Lock can only use Usage access, which is slower.';
  static const String disclosureNever =
      'Smart App Lock does not read the text or anything else on your '
      'screen, does not tap, type or act for you, and does not keep a list '
      'of the apps you open. This information never leaves your phone and '
      'is not shared. If someone fails to unlock a protected app, that '
      "app's name can be saved in your encrypted security records on this "
      'phone.';
  static const String notUsedElsewhere = 'Not used for anything else.';

  /// P19/M1: the separate, affirmative consent request. "Agree" is the
  /// consent; only then are Android's Accessibility settings opened (the
  /// Android switch itself stays the user's decision). "Not now" declines
  /// without opening anything.
  static const String consentQuestion =
      'Do you agree to let Smart App Lock use the Accessibility service '
      'this way?';
  static const String openSettingsLabel = 'Agree';
  static const String declineLabel = 'Not now';

  /// Granted-state secondary action: reopen the same system settings
  /// destination so the user can always manage (or revoke) the service.
  static const String manageSettingsLabel = 'Manage Settings';
  static const String settingsNote =
      "Agree opens Android's Accessibility settings. Android will show its "
      'own warning — this is normal. Find Smart App Lock in the list, turn '
      'it on, then come back. You can turn it off there at any time. If you '
      'choose Not now, nothing is turned on.';
  static const String enabledTitle = 'Accessibility enabled';
  static const String enabledMessage =
      'Early event-driven protection detection is active.';
  static const String doneLabel = 'Done';
  static const String unavailableTitle = 'Could not check accessibility';
  static const String unavailableMessage =
      'Smart App Lock could not read the accessibility state. Please try '
      'again.';
  static const String retryLabel = 'Retry';

  @override
  State<AccessibilitySetupScreen> createState() =>
      _AccessibilitySetupScreenState();
}

enum _ServiceState { checking, enabled, notEnabled, unavailable }

class _AccessibilitySetupScreenState extends State<AccessibilitySetupScreen>
    with WidgetsBindingObserver {
  _ServiceState _state = _ServiceState.checking;

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

  AccessibilityLockService get _service =>
      widget.service ?? AppScope.read(context)!.accessibility;

  /// Step 4: the user returns from the system settings — re-probe.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _check();
    }
  }

  Future<void> _check() async {
    final AccessibilityLockService service;
    try {
      service = _service;
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _state = _ServiceState.unavailable);
      return;
    }
    final result = await service.isServiceEnabled();
    if (!mounted) {
      return;
    }
    setState(() {
      if (result.isFailure) {
        _state = _ServiceState.unavailable;
      } else if (result.valueOrNull == true) {
        _state = _ServiceState.enabled;
      } else {
        _state = _ServiceState.notEnabled;
      }
    });
  }

  Future<void> _openSettings() async {
    final result = await _service.requestServiceEnable();
    if (!mounted) {
      return;
    }
    if (result.isFailure) {
      setState(() => _state = _ServiceState.unavailable);
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
            _ServiceState.checking => const Center(
                key: ValueKey<String>('checking'),
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            _ServiceState.enabled => _buildEnabled(),
            _ServiceState.notEnabled => _buildNotEnabled(),
            _ServiceState.unavailable => _buildUnavailable(),
          },
        ),
      ),
    );
  }

  Widget _buildEnabled() {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    return ListView(
      key: const ValueKey<String>('enabled'),
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
            AccessibilitySetupScreen.enabledTitle,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        Center(
          child: Text(
            AccessibilitySetupScreen.enabledMessage,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: DsSpacing.xxl),
        // The user can always return to the system Accessibility screen —
        // essential on OEM devices where the setting is hard to find.
        DsButton(
          key: const Key('accessibility_manage_settings'),
          label: AccessibilitySetupScreen.manageSettingsLabel,
          variant: DsButtonVariant.secondary,
          expand: true,
          onPressed: _openSettings,
        ),
        const SizedBox(height: DsSpacing.md),
        DsButton(
          label: AccessibilitySetupScreen.doneLabel,
          expand: true,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }

  /// The prominent disclosure view (Step 2 of the flow).
  Widget _buildNotEnabled() {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    return ListView(
      key: const ValueKey<String>('not_enabled'),
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
            child:
                Icon(Icons.accessibility_new, size: 40, color: palette.warning),
          ),
        ),
        const SizedBox(height: DsSpacing.xl),
        Center(
          child: Text(
            AccessibilitySetupScreen.notEnabledTitle,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: DsSpacing.lg),
        // -- The disclosure card: the exact reason, and the exact non-uses.
        DsCard(
          title: AccessibilitySetupScreen.disclosureTitle,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                AccessibilitySetupScreen.disclosureBody,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: DsSpacing.sm),
              Text(
                AccessibilitySetupScreen.disclosureNever,
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
                  AccessibilitySetupScreen.notUsedElsewhere,
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
        Text(
          AccessibilitySetupScreen.consentQuestion,
          key: const Key('accessibility_consent_question'),
          textAlign: TextAlign.center,
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: DsSpacing.md),
        // P19/M1: affirmative consent first; the Android hand-off follows.
        DsButton(
          key: const Key('accessibility_open_settings'),
          label: AccessibilitySetupScreen.openSettingsLabel,
          expand: true,
          onPressed: _openSettings,
        ),
        const SizedBox(height: DsSpacing.md),
        // P19/M1: a genuine decline — opens nothing, records nothing.
        DsButton(
          key: const Key('accessibility_decline'),
          label: AccessibilitySetupScreen.declineLabel,
          variant: DsButtonVariant.secondary,
          expand: true,
          onPressed: () => Navigator.of(context).maybePop(false),
        ),
        const SizedBox(height: DsSpacing.lg),
        Center(
          child: Text(
            AccessibilitySetupScreen.settingsNote,
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
            AccessibilitySetupScreen.unavailableTitle,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        Center(
          child: Text(
            AccessibilitySetupScreen.unavailableMessage,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: DsSpacing.xxl),
        DsButton(
          label: AccessibilitySetupScreen.retryLabel,
          expand: true,
          onPressed: _check,
        ),
      ],
    );
  }
}
