import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../design_system/design_system.dart';
import '../../../services/installed_apps_service.dart';

/// Usage Access setup screen (Phase 4B).
///
/// The complete capability flow required by the architecture:
///  1. **detect status** — probes the AppOps state through the shared
///     [InstalledAppsService] on open;
///  2. **explain purpose** — why the detection capability is needed;
///  3. **send the user to the right Android settings** — the system
///     Usage Access screen (the only legal place to grant it);
///  4. **detect successful return** — re-checks when the app resumes
///     and after the settings intent fires, then shows the granted state.
class UsageAccessScreen extends StatefulWidget {
  const UsageAccessScreen({super.key, this.service, this.title = 'Usage access'});

  /// Overrides the service resolved from [AppScope] (tests/previews).
  final InstalledAppsService? service;

  final String title;

  static const String notGrantedTitle = 'Usage access is off';
  static const String notGrantedMessage =
      'Smart App Lock detects which app you open so it can lock protected '
      'apps instantly. Enable usage access to make locking work.';
  static const String openSettingsLabel = 'Open Settings';
  static const String settingsNote =
      'The Android settings screen will open — find Smart App Lock and '
      'allow usage access there, then come back.';
  static const String grantedTitle = 'Usage access enabled';
  static const String grantedMessage =
      'Smart App Lock can now detect the apps you open.';
  static const String doneLabel = 'Done';
  static const String unavailableTitle = 'Could not check usage access';
  static const String unavailableMessage =
      'Smart App Lock could not read the usage-access state. Please try '
      'again.';
  static const String retryLabel = 'Retry';

  @override
  State<UsageAccessScreen> createState() => _UsageAccessScreenState();
}

enum _AccessState { checking, granted, notGranted, unavailable }

class _UsageAccessScreenState extends State<UsageAccessScreen>
    with WidgetsBindingObserver {
  _AccessState _state = _AccessState.checking;

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

  InstalledAppsService get _service =>
      widget.service ?? AppScope.read(context)!.installedAppsService;

  /// Step 4 of the flow: the user returns from the system settings —
  /// re-probe the capability and reflect the result.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _check();
    }
  }

  Future<void> _check() async {
    final InstalledAppsService service;
    try {
      service = _service;
    } catch (_) {
      // No container in scope (pure widget tests) — report unavailable.
      if (!mounted) {
        return;
      }
      setState(() => _state = _AccessState.unavailable);
      return;
    }
    final result = await service.hasUsageAccess();
    if (!mounted) {
      return;
    }
    setState(() {
      if (result.isFailure) {
        _state = _AccessState.unavailable;
      } else if (result.valueOrNull == true) {
        _state = _AccessState.granted;
      } else {
        _state = _AccessState.notGranted;
      }
    });
  }

  /// Step 3: fire the system settings intent through the service, then
  /// re-check (the intent result is fire-and-forget; the resume observer
  /// covers the actual return).
  Future<void> _openSettings() async {
    final result = await _service.requestUsageAccess();
    if (!mounted) {
      return;
    }
    if (result.isFailure) {
      setState(() => _state = _AccessState.unavailable);
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
            _AccessState.checking => const Center(
                key: ValueKey<String>('checking'),
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            _AccessState.granted => _buildGranted(),
            _AccessState.notGranted => _buildNotGranted(),
            _AccessState.unavailable => _buildUnavailable(),
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
            UsageAccessScreen.grantedTitle,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        Center(
          child: Text(
            UsageAccessScreen.grantedMessage,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: DsSpacing.xxl),
        DsButton(
          label: UsageAccessScreen.doneLabel,
          expand: true,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }

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
            child: Icon(Icons.insights, size: 40, color: palette.warning),
          ),
        ),
        const SizedBox(height: DsSpacing.xl),
        Center(
          child: Text(
            UsageAccessScreen.notGrantedTitle,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        Center(
          child: Text(
            UsageAccessScreen.notGrantedMessage,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: DsSpacing.xxl),
        DsButton(
          key: const Key('usage_access_open_settings'),
          label: UsageAccessScreen.openSettingsLabel,
          expand: true,
          onPressed: _openSettings,
        ),
        const SizedBox(height: DsSpacing.lg),
        Center(
          child: Text(
            UsageAccessScreen.settingsNote,
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
            UsageAccessScreen.unavailableTitle,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: DsSpacing.sm),
        Center(
          child: Text(
            UsageAccessScreen.unavailableMessage,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: DsSpacing.xxl),
        DsButton(
          label: UsageAccessScreen.retryLabel,
          expand: true,
          onPressed: _check,
        ),
      ],
    );
  }
}
