import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../app/router.dart';
import '../../../design_system/design_system.dart';

/// One required capability shown on the centralized setup screen.
class _Capability {
  const _Capability({
    required this.name,
    required this.description,
    required this.route,
    required this.icon,
    required this.rowKey,
  });

  final String name;
  final String description;
  final String route;
  final IconData icon;
  final String rowKey;
}

/// Centralized permission setup (Phase 4E).
///
/// Shows every capability the protection architecture requires — Usage
/// Access, Accessibility (detection fallback), Draw over apps — each with
/// an **Enabled** or **Action Required** status. Tapping a row opens that
/// capability's dedicated setup flow (4B/4C/4D); returning re-checks the
/// capability state. App resume also re-checks (the user may have enabled
/// a capability in the system settings and come back directly).
class PermissionSetupScreen extends StatefulWidget {
  const PermissionSetupScreen({super.key, this.title = 'Permissions'});

  final String title;

  static const String headerTitle = 'App lock permissions';
  static const String headerSubtitle =
      'Enable every capability Smart App Lock needs to protect your apps.';
  static const String enabledLabel = 'Enabled';
  static const String actionRequiredLabel = 'Action Required';
  static String readyCount(int n) => '$n of 3 ready';

  @override
  State<PermissionSetupScreen> createState() => _PermissionSetupScreenState();
}

class _PermissionSetupScreenState extends State<PermissionSetupScreen>
    with WidgetsBindingObserver {
  static const List<_Capability> _capabilities = <_Capability>[
    _Capability(
      name: 'Usage access',
      description: 'Detects which app you open so it can be locked',
      route: RouteNames.usageAccess,
      icon: Icons.insights,
      rowKey: 'perm_row_usage',
    ),
    _Capability(
      name: 'Accessibility service',
      description: 'Detection fallback if usage access is off',
      route: RouteNames.accessibilitySetup,
      icon: Icons.accessibility_new,
      rowKey: 'perm_row_accessibility',
    ),
    _Capability(
      name: 'Draw over apps',
      description: 'Shows the lock screen over protected apps',
      route: RouteNames.overlaySetup,
      icon: Icons.layers,
      rowKey: 'perm_row_overlay',
    ),
  ];

  final Map<String, bool> _granted = <String, bool>{
    'usage': false,
    'accessibility': false,
    'overlay': false,
  };
  bool _probing = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Returning from the system settings (or from a setup flow) re-checks
  /// every capability.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  int get _readyCount =>
      _granted.values.where((bool granted) => granted).length;

  Future<void> _refresh() async {
    final container = AppScope.read(context);
    if (container == null) {
      if (!mounted) {
        return;
      }
      setState(() => _probing = false);
      return;
    }

    final usage = await container.installedAppsService.hasUsageAccess();
    final accessibility = await container.accessibility.isServiceEnabled();
    final overlay = await container.overlay.canDrawOverlays();
    if (!mounted) {
      return;
    }
    setState(() {
      _granted['usage'] = usage.isSuccess && usage.valueOrNull == true;
      _granted['accessibility'] =
          accessibility.isSuccess && accessibility.valueOrNull == true;
      _granted['overlay'] = overlay.isSuccess && overlay.valueOrNull == true;
      _probing = false;
    });
  }

  Future<void> _openCapability(_Capability capability) async {
    await Navigator.of(context).pushNamed(capability.route);
    if (mounted) {
      await _refresh();
    }
  }

  bool _grantedFor(_Capability capability) => switch (capability.rowKey) {
        'perm_row_usage' => _granted['usage']!,
        'perm_row_accessibility' => _granted['accessibility']!,
        _ => _granted['overlay']!,
      };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: ListView(
          padding: DsInsets.screen,
          children: <Widget>[
            const SizedBox(height: DsSpacing.sm),
            Text(
              PermissionSetupScreen.headerTitle,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: DsSpacing.xs),
            Text(
              PermissionSetupScreen.headerSubtitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: context.dsColors.textSecondary,
              ),
            ),
            const SizedBox(height: DsSpacing.md),
            DsStatusPill(
              key: const Key('perm_ready_count'),
              label: _probing
                  ? 'Checking…'
                  : PermissionSetupScreen.readyCount(_readyCount),
              tone: _probing || _readyCount < 3
                  ? DsTone.warning
                  : DsTone.success,
              showDot: !_probing,
            ),
            const SizedBox(height: DsSpacing.xl),
            DsCard(
              padding: const EdgeInsets.symmetric(vertical: DsSpacing.xs),
              child: Column(
                children: <Widget>[
                  for (final _Capability capability in _capabilities) ...<Widget>[
                    SecurityStatusItem(
                      key: Key(capability.rowKey),
                      icon: capability.icon,
                      title: capability.name,
                      subtitle: capability.description,
                      level: _grantedFor(capability)
                          ? SecurityLevel.secured
                          : SecurityLevel.atRisk,
                      statusLabel: _grantedFor(capability)
                          ? PermissionSetupScreen.enabledLabel
                          : PermissionSetupScreen.actionRequiredLabel,
                      onTap: () => _openCapability(capability),
                    ),
                    if (capability != _capabilities.last)
                      const Divider(),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
