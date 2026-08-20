import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../data/models/app_entry.dart';
import '../../../data/models/protected_app.dart';
import '../../../design_system/design_system.dart';
import '../../widgets/app_icon.dart';

/// Filter groups of the Apps tab (Phase 3D).
enum AppsFilter {
  all('All'),
  protected('Protected'),
  unprotected('Unprotected');

  const AppsFilter(this.label);

  final String label;
}

/// Apps tab — the installed-apps list with search (3C) and filters (3D).
///
/// Shows every app that is appropriate for App Lock selection with its
/// launcher icon, name, and current protection status. The search field
/// filters by name; the segmented control groups the list into
/// All / Protected / Unprotected. Data flows through the shared container
/// (Phase 3A): the discovery repository for the catalog and the
/// protected-apps repository for the status.
class AppsScreen extends StatefulWidget {
  const AppsScreen({super.key});

  /// Shown as the screen subtitle (also asserted by the navigation tests).
  static const String description =
      'Choose which apps to protect and manage your locked list.';

  static const String title = 'Protect your apps';
  static const String protectedLabel = 'Locked';
  static const String unlockedLabel = 'Unlocked';
  static const String errorTitle = 'Could not load apps';
  static const String retryLabel = 'Retry';
  static const String emptyTitle = 'No apps found';
  static const String emptyMessage =
      'No lockable apps were found on this device.';
  static const String unavailableMessage = 'App discovery is unavailable.';
  static const String searchHint = 'Search apps by name';
  static const String noMatchTitle = 'No apps match';
  static const String noMatchMessage = 'Try a different name.';
  static const String clearSearchLabel = 'Clear search';
  static const String noProtectedTitle = 'No protected apps';
  static const String noProtectedMessage =
      'Protect apps to see them here.';
  static const String allProtectedTitle = 'All apps are protected';
  static const String allProtectedMessage =
      'Nothing is left unlocked.';
  static const String showAllLabel = 'Show all';
  static const String protectedSnack = ' protected ✓';
  static const String unprotectedSnack = ' unprotected';
  static const String updateFailedMessage = 'Could not update protection.';

  @override
  State<AppsScreen> createState() => _AppsScreenState();
}

enum _LoadState { loading, ready, error }

class _AppsScreenState extends State<AppsScreen> with WidgetsBindingObserver {
  _LoadState _state = _LoadState.loading;
  List<AppEntry> _apps = <AppEntry>[];
  Set<String> _protected = <String>{};
  int _fetchGeneration = 0;

  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  AppsFilter _filter = AppsFilter.all;

  // Phase 3G — bulk selection state.
  bool _selectionMode = false;
  Set<String> _selected = <String>{};
  bool _bulkBusy = false;

  /// Memoized visible list (Phase 3H). Recomputed ONLY when the catalog,
  /// query, filter or protection set changes — never during scroll builds,
  /// so large installed-app lists stay responsive.
  List<AppEntry> _visible = <AppEntry>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  /// Phase 3F: when the app resumes (after suspension, backgrounding, or a
  /// process hand-off), re-read the protected set from the persisted store
  /// so the list always reflects what survived on disk.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshProtection();
    }
  }

  /// Re-reads ONLY the protection set (the catalog itself changes rarely
  /// and is cached by the repository).
  Future<void> _refreshProtection() async {
    final container = AppScope.read(context);
    if (container == null) {
      return;
    }
    final result = await container.protectedApps.getProtectedApps();
    if (!mounted || result.isFailure) {
      return;
    }
    setState(() {
      _protected = result.valueOrNull!
          .map((app) => app.packageName)
          .toSet();
      _recomputeVisible();
    });
  }

  void _onSearchChanged(String value) {
    setState(() {
      _query = value.trim();
      _recomputeVisible();
    });
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _query = '';
      _recomputeVisible();
    });
  }

  void _setFilter(AppsFilter filter) {
    setState(() {
      _filter = filter;
      _recomputeVisible();
    });
  }

  void _showAll() {
    _searchController.clear();
    setState(() {
      _query = '';
      _filter = AppsFilter.all;
      _recomputeVisible();
    });
  }

  // -- Phase 3G: bulk selection --------------------------------------------

  void _enterSelectionMode() {
    setState(() {
      _selectionMode = true;
      _selected = <String>{};
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selected = <String>{};
    });
  }

  void _toggleSelected(String packageName) {
    setState(() {
      _selected.contains(packageName)
          ? _selected.remove(packageName)
          : _selected.add(packageName);
    });
  }

  /// Selects every currently visible row (honors the active filter and
  /// search query).
  void _selectAllVisible() {
    setState(() {
      _selected = _visible.map((AppEntry app) => app.packageName).toSet();
    });
  }

  /// Marks every selected app protected (skips apps already protected).
  Future<void> _bulkProtect() async {
    final container = AppScope.read(context);
    if (container == null || _selected.isEmpty || _bulkBusy) {
      return;
    }
    setState(() => _bulkBusy = true);

    int changed = 0;
    final Set<String> failed = <String>{};
    for (final String packageName in _selected) {
      if (_protected.contains(packageName)) {
        continue; // already protected — sensible no-op
      }
      AppEntry? app;
      for (final AppEntry candidate in _apps) {
        if (candidate.packageName == packageName) {
          app = candidate;
          break;
        }
      }
      if (app == null) {
        failed.add(packageName);
        continue;
      }
      final result = await container.protectedApps.add(
        ProtectedApp(
          packageName: app.packageName,
          label: app.label,
          addedAt: DateTime.now(),
        ),
      );
      if (result.isSuccess) {
        changed++;
      } else {
        failed.add(packageName);
      }
    }

    if (!mounted) {
      return;
    }
    if (failed.isNotEmpty) {
      setState(() {
        _bulkBusy = false;
        _selected = failed; // keep only the failed ones selected
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppsScreen.bulkPartialFailure(failed.length))),
      );
      return;
    }

    // Refresh the protection set and leave selection mode.
    setState(() {
      _protected = <String>{
        ..._protected,
        ..._selected,
      };
      _recomputeVisible();
      _bulkBusy = false;
      _selectionMode = false;
      _selected = <String>{};
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppsScreen.bulkProtected(changed))),
    );
  }

  /// Marks every selected app unprotected (skips apps already unlocked).
  Future<void> _bulkUnprotect() async {
    final container = AppScope.read(context);
    if (container == null || _selected.isEmpty || _bulkBusy) {
      return;
    }
    setState(() => _bulkBusy = true);

    int changed = 0;
    final Set<String> failed = <String>{};
    for (final String packageName in _selected) {
      if (!_protected.contains(packageName)) {
        continue; // already unprotected — sensible no-op
      }
      final result = await container.protectedApps.remove(packageName);
      if (result.isSuccess) {
        changed++;
      } else {
        failed.add(packageName);
      }
    }

    if (!mounted) {
      return;
    }
    if (failed.isNotEmpty) {
      setState(() {
        _bulkBusy = false;
        _selected = failed;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppsScreen.bulkPartialFailure(failed.length))),
      );
      return;
    }

    setState(() {
      _protected = _protected.difference(_selected);
      _recomputeVisible();
      _bulkBusy = false;
      _selectionMode = false;
      _selected = <String>{};
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppsScreen.bulkUnprotected(changed))),
    );
  }

  /// Phase 3E: marks one application Protected or Unprotected through the
  /// protected-apps repository (persisted; no locking yet).
  ///
  /// Optimistic: the list updates immediately and reverts with a snackbar
  /// when the repository rejects the change.
  Future<void> _toggleProtection(AppEntry app) async {
    final container = AppScope.read(context);
    if (container == null) {
      return;
    }
    final bool wasProtected = _protected.contains(app.packageName);
    setState(() {
      wasProtected
          ? _protected.remove(app.packageName)
          : _protected.add(app.packageName);
      _recomputeVisible();
    });

    final result = wasProtected
        ? await container.protectedApps.remove(app.packageName)
        : await container.protectedApps.add(
            ProtectedApp(
              packageName: app.packageName,
              label: app.label,
              addedAt: DateTime.now(),
            ),
          );
    if (!mounted) {
      return;
    }
    if (result.isFailure) {
      setState(() {
        wasProtected
            ? _protected.add(app.packageName)
            : _protected.remove(app.packageName);
        _recomputeVisible();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(AppsScreen.updateFailedMessage)),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          wasProtected
              ? '${app.label}${AppsScreen.unprotectedSnack}'
              : '${app.label}${AppsScreen.protectedSnack}',
        ),
      ),
    );
  }

  /// Recomputes the visible list: the name query first, then the group
  /// filter. O(n) but only on user actions / data changes, never per frame.
  void _recomputeVisible() {
    List<AppEntry> base;
    if (_query.isEmpty) {
      base = _apps;
    } else {
      final String needle = _query.toLowerCase();
      base = _apps
          .where(
            (AppEntry app) => app.label.toLowerCase().contains(needle),
          )
          .toList(growable: false);
    }
    switch (_filter) {
      case AppsFilter.all:
        _visible = base;
      case AppsFilter.protected:
        _visible = base
            .where((AppEntry a) => _protected.contains(a.packageName))
            .toList(growable: false);
      case AppsFilter.unprotected:
        _visible = base
            .where((AppEntry a) => !_protected.contains(a.packageName))
            .toList(growable: false);
    }
  }

  /// Name-only filtered list — used solely by the filter-empty state to
  /// decide whether the QUERY (not the group) produced the empty result.
  List<AppEntry> get _nameFiltered {
    if (_query.isEmpty) {
      return _apps;
    }
    final String needle = _query.toLowerCase();
    return _apps
        .where(
          (AppEntry app) => app.label.toLowerCase().contains(needle),
        )
        .toList(growable: false);
  }

  bool get _isFiltered => _query.isNotEmpty || _filter != AppsFilter.all;

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
      _recomputeVisible();
      _state = _LoadState.ready;
    });
  }

  @override
  Widget build(BuildContext context) {
    final int visibleCount = _visible.length;
    final String countLabel = _isFiltered
        ? '$visibleCount / ${_apps.length}'
        : '${_apps.length} apps';
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
                if (_state == _LoadState.ready) ...<Widget>[
                  TextButton(
                    key: const Key('apps_select_button'),
                    onPressed: _selectionMode
                        ? _exitSelectionMode
                        : _enterSelectionMode,
                    child: Text(
                      _selectionMode
                          ? AppsScreen.cancelLabel
                          : AppsScreen.selectLabel,
                    ),
                  ),
                  const SizedBox(width: DsSpacing.xs),
                  DsStatusPill(label: countLabel, showDot: false),
                ],
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
          Padding(
            padding: const EdgeInsets.fromLTRB(
              DsSpacing.lg,
              DsSpacing.sm,
              DsSpacing.lg,
              DsSpacing.sm,
            ),
            child: DsTextField(
              key: const Key('apps_search_field'),
              controller: _searchController,
              hint: AppsScreen.searchHint,
              leadingIcon: const Icon(Icons.search),
              trailingIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      key: const Key('apps_search_clear'),
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.close),
                      onPressed: _clearSearch,
                    ),
              onChanged: _onSearchChanged,
            ),
          ),
          if (_state == _LoadState.ready)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                DsSpacing.lg,
                0,
                DsSpacing.lg,
                DsSpacing.sm,
              ),
              child: DsSegmented<AppsFilter>(
                segments: <DsSegment<AppsFilter>>[
                  for (final AppsFilter filter in AppsFilter.values)
                    DsSegment<AppsFilter>(
                      value: filter,
                      label: filter.label,
                    ),
                ],
                selected: _filter,
                onSelected: _setFilter,
              ),
            ),
          Expanded(child: _buildBody()),
          if (_selectionMode && _state == _LoadState.ready)
            _buildBulkBar(),
        ],
      ),
    );
  }

  /// Bottom action bar shown only in selection mode (Phase 3G).
  Widget _buildBulkBar() {
    final DsPalette palette = context.dsColors;
    final bool nothingSelected = _selected.isEmpty;
    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(
          top: BorderSide(color: palette.border.withValues(alpha: 0.6)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        DsSpacing.lg,
        DsSpacing.sm,
        DsSpacing.lg,
        DsSpacing.sm,
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    AppsScreen.selectedCount(_selected.length),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  TextButton(
                    key: const Key('apps_select_all'),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: _bulkBusy ? null : _selectAllVisible,
                    child: const Text(AppsScreen.selectAllLabel),
                  ),
                ],
              ),
            ),
            const SizedBox(width: DsSpacing.md),
            DsButton(
              key: const Key('apps_bulk_unprotect'),
              label: AppsScreen.unprotectBulkLabel,
              variant: DsButtonVariant.outline,
              size: DsButtonSize.small,
              onPressed:
                  (nothingSelected || _bulkBusy) ? null : _bulkUnprotect,
            ),
            const SizedBox(width: DsSpacing.sm),
            DsButton(
              key: const Key('apps_bulk_protect'),
              label: AppsScreen.protectBulkLabel,
              size: DsButtonSize.small,
              onPressed: (nothingSelected || _bulkBusy) ? null : _bulkProtect,
            ),
          ],
        ),
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
        final List<AppEntry> visible = _visible;
        if (visible.isEmpty) {
          return _buildFilterEmptyState();
        }
        final container = AppScope.read(context);
        final repository = container?.installedApps;
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: DsSpacing.xl),
          // Uniform two-line ListTile rows: a fixed extent lets the
          // list skip per-row layout during fast scrolls (Phase 3H).
          itemExtent: 72,
          itemCount: visible.length,
          itemBuilder: (BuildContext context, int index) {
            final AppEntry app = visible[index];
            final bool isProtected = _protected.contains(app.packageName);

            // Selection mode: checkbox row (the protection switch is
            // hidden — bulk actions decide the new state).
            if (_selectionMode) {
              return ListTile(
                key: Key('app_row_${app.packageName}'),
                leading: Checkbox(
                  key: Key('app_check_${app.packageName}'),
                  value: _selected.contains(app.packageName),
                  activeColor: context.dsColors.primary,
                  onChanged: (_) => _toggleSelected(app.packageName),
                ),
                title: Text(
                  app.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  isProtected
                      ? AppsScreen.protectedLabel
                      : AppsScreen.unlockedLabel,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: isProtected
                            ? context.dsColors.success
                            : context.dsColors.textSecondary,
                      ),
                ),
                onTap: () => _toggleSelected(app.packageName),
              );
            }

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
              // Status text sits under the name; the trailing switch is
              // the explicit Protected/Unprotected toggle (Phase 3E).
              subtitle: Text(
                isProtected
                    ? AppsScreen.protectedLabel
                    : AppsScreen.unlockedLabel,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: isProtected
                          ? context.dsColors.success
                          : context.dsColors.textSecondary,
                    ),
              ),
              trailing: Switch(
                key: Key('app_toggle_${app.packageName}'),
                value: isProtected,
                activeThumbColor: context.dsColors.primary,
                onChanged: container == null
                    ? null
                    : (_) => _toggleProtection(app),
              ),
            );
          },
        );
    }
  }

  /// Distinguishes why the visible list is empty: the name query matched
  /// nothing, or the group filter has no members.
  Widget _buildFilterEmptyState() {
    if (_query.isNotEmpty && _nameFiltered.isEmpty) {
      return _MessageCard(
        icon: Icons.search_off,
        title: AppsScreen.noMatchTitle,
        message: AppsScreen.noMatchMessage,
        actionLabel: AppsScreen.clearSearchLabel,
        onAction: _clearSearch,
      );
    }
    final bool protectedFilter = _filter == AppsFilter.protected;
    return _MessageCard(
      icon: protectedFilter ? Icons.lock_outline : Icons.lock_open,
      title: protectedFilter
          ? AppsScreen.noProtectedTitle
          : AppsScreen.allProtectedTitle,
      message: protectedFilter
          ? AppsScreen.noProtectedMessage
          : AppsScreen.allProtectedMessage,
      actionLabel: AppsScreen.showAllLabel,
      onAction: _showAll,
    );
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
