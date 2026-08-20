import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../data/models/app_entry.dart';
import '../../../design_system/design_system.dart';
import '../../widgets/app_icon.dart';

/// Apps tab — the installed-apps list (Phase 3B).
///
/// Shows every app that is appropriate for App Lock selection with its
/// launcher icon, name, and current protection status. Data flows through
/// the shared container (Phase 3A): the discovery repository for the
/// catalog and the protected-apps repository for the status.
class AppsScreen extends StatefulWidget {
  const AppsScreen({super.key});

  /// Shown as the screen subtitle (also asserted by the navigation tests).
  static const String description =
      'Choose which apps to protect and manage your locked list.';

  static const String title = 'Protect your apps';
  static const String protectedLabel = 'Protected';
  static const String unlockedLabel = 'Not locked';
  static const String errorTitle = 'Could not load apps';
  static const String retryLabel = 'Retry';
  static const String emptyTitle = 'No apps found';
  static const String emptyMessage =
      'No lockable apps were found on this device.';
  static const String unavailableMessage = 'App discovery is unavailable.';

  @override
  State<AppsScreen> createState() => _AppsScreenState();
}

enum _LoadState { loading, ready, error }

class _AppsScreenState extends State<AppsScreen> {
  _LoadState _state = _LoadState.loading;
  List<AppEntry> _apps = <AppEntry>[];
  Set<String> _protected = <String>{};
  int _fetchGeneration = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final int generation = ++_fetchGeneration;
    setState(() => _state = _LoadState.loading);

    final container = AppScope.read(context);
    if (container == null) {
      if (!mounted || generation != _fetchGeneration) {
        return;
      }
      setState(() => _state = _LoadState.error);
      return;
    }

    final appsResult = await container.installedApps.getInstalledApps();
    if (!mounted || generation != _fetchGeneration) {
      return;
    }
    if (appsResult.isFailure) {
      setState(() => _state = _LoadState.error);
      return;
    }

    final protectedResult = await container.protectedApps.getProtectedApps();
    if (!mounted || generation != _fetchGeneration) {
      return;
    }
    final Set<String> protected = protectedResult.isSuccess
        ? protectedResult
            .valueOrNull!
            .map((app) => app.packageName)
            .toSet()
        : <String>{};

    setState(() {
      _apps = appsResult.valueOrNull!;
      _protected = protected;
      _state = _LoadState.ready;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              DsSpacing.lg,
              DsSpacing.sm + 2,
              DsSpacing.lg,
              0,
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    AppsScreen.title,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                if (_state == _LoadState.ready)
                  DsStatusPill(label: '${_apps.length} apps', showDot: false),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              DsSpacing.lg,
              DsSpacing.xs,
              DsSpacing.lg,
              DsSpacing.sm,
            ),
            child: Text(
              AppsScreen.description,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.dsColors.textSecondary,
                  ),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    switch (_state) {
      case _LoadState.loading:
        return const Center(
          child: CircularProgressIndicator(strokeWidth: 2.5),
        );
      case _LoadState.error:
        return _MessageCard(
          icon: Icons.error_outline,
          title: AppsScreen.errorTitle,
          message: AppsScreen.unavailableMessage,
          actionLabel: AppsScreen.retryLabel,
          onAction: _load,
        );
      case _LoadState.ready:
        if (_apps.isEmpty) {
          return _MessageCard(
            icon: Icons.apps_outage,
            title: AppsScreen.emptyTitle,
            message: AppsScreen.emptyMessage,
            actionLabel: AppsScreen.retryLabel,
            onAction: _load,
          );
        }
        final container = AppScope.read(context);
        final repository = container?.installedApps;
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: DsSpacing.xl),
          itemCount: _apps.length,
          itemBuilder: (BuildContext context, int index) {
            final AppEntry app = _apps[index];
            final bool isProtected = _protected.contains(app.packageName);
            return ListTile(
              leading: repository == null
                  ? null
                  : AppIcon(
                      packageName: app.packageName,
                      repository: repository,
                    ),
              title: Text(
                app.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: isProtected
                  ? const DsStatusPill(
                      label: AppsScreen.protectedLabel,
                      tone: DsTone.success,
                    )
                  : const DsStatusPill(label: AppsScreen.unlockedLabel),
            );
          },
        );
    }
  }
}

/// Centered message card for error and empty states.
class _MessageCard extends StatelessWidget {
  const _MessageCard({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final DsPalette palette = context.dsColors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(DsSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: palette.textSecondary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 30, color: palette.textSecondary),
            ),
            const SizedBox(height: DsSpacing.lg),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: DsSpacing.xs),
            Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: palette.textSecondary,
                  ),
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null) ...<Widget>[
              const SizedBox(height: DsSpacing.lg),
              DsButton(
                label: actionLabel!,
                variant: DsButtonVariant.outline,
                size: DsButtonSize.small,
                onPressed: onAction,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
