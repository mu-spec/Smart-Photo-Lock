import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../data/models/app_entry.dart';
import '../../../data/models/app_security_level.dart';
import '../../../data/models/protected_app.dart';
import '../../../data/models/security_recommendation.dart';
import '../../../design_system/design_system.dart';
import '../../widgets/app_icon.dart';
import 'security_level_sheet.dart';
import 'unprotect_gate.dart';

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
  static const String noProtectedMessage = 'Protect apps to see them here.';
  static const String allProtectedTitle = 'All apps are protected';
  static const String allProtectedMessage = 'Nothing is left unlocked.';
  static const String showAllLabel = 'Show all';
  static const String protectedSnack = ' protected ✓';
  static const String unprotectedSnack = ' unprotected';
  static const String updateFailedMessage = 'Could not update protection.';
  static const String selectLabel = 'Select';
  static const String cancelLabel = 'Cancel';
  static const String selectAllLabel = 'Select all';
  static const String protectBulkLabel = 'Protect';
  static const String unprotectBulkLabel = 'Unprotect';
  static String selectedCount(int n) => '$n selected';
  static String bulkProtected(int n) =>
      n == 1 ? '1 app protected ✓' : '$n apps protected ✓';
  static String bulkUnprotected(int n) =>
      n == 1 ? '1 app unprotected' : '$n apps unprotected';
  static String bulkPartialFailure(int n) =>
      'Could not update $n ${n == 1 ? 'app' : 'apps'}.';

  // Phase 8 — per-app security level (M1 stores it; M2 enforces it).
  static String levelSuffix(AppSecurityLevel level) => ' · ${level.label}';
  static const String levelSavingSuffix = ' · Saving…';
  static const String levelTapHint = 'change security level';
  static String levelSaved(String app, AppSecurityLevel level) =>
      '$app: ${level.label} saved';
  static String levelSaveFailed(AppSecurityLevel kept) =>
      'Could not save the security level. It is still ${kept.label}.';
  static const String levelNotProtectedMessage =
      'This app is no longer protected. Nothing was saved.';

  // Phase 8 / M2 — enforcement status and suggestions.
  /// Row hint: native still enforces a stricter level than the saved one.
  static String levelHeldSuffix(AppSecurityLevel enforced) =>
      ' · ${enforced.label} still enforced';

  /// Upgrade saved, but native did not confirm it.
  static String levelSavedNotConfirmed(String app, AppSecurityLevel level) =>
      '$app: ${level.label} saved, but Smart App Lock could not confirm it '
      'is active everywhere yet. The earlier level may still apply in some '
      'cases until it is.';

  /// Downgrade saved, but native still enforces the stricter level.
  static String levelLowerNotApplied(
    String app,
    AppSecurityLevel level,
    AppSecurityLevel enforced,
  ) =>
      '$app: ${level.label} saved, but ${enforced.label} is still enforced '
      'until the change is confirmed. Try again to apply it.';

  static const String levelLowerNotConfirmedMessage =
      'Security level unchanged. Confirm with your PIN or pattern to lower '
      'it.';
  static const String levelLowerNoCredentialMessage =
      'Set up a PIN or pattern in Security before lowering a security level.';
  static const String levelLowerUnavailableMessage =
      'Could not verify your identity. Security level unchanged.';

  /// Maps a CR-2 denial of a downgrade to its user-facing message.
  static String levelLowerDeniedMessage(UnprotectDenial denial) =>
      switch (denial) {
        UnprotectDenial.notAuthenticated => levelLowerNotConfirmedMessage,
        UnprotectDenial.noAppCredential => levelLowerNoCredentialMessage,
        UnprotectDenial.credentialUnavailable => levelLowerUnavailableMessage,
      };

  static String suggestionSemantics(AppSecurityLevel level) =>
      'Suggested level: ${level.label}';
  static const String suggestionDismissedMessage =
      'Suggestion hidden. The security level was not changed.';

  /// CR-2: shown when an unprotect was not confirmed with the app
  /// credential. Protection is unchanged.
  static const String unprotectNotConfirmedMessage =
      'Protection unchanged. Confirm with your PIN or pattern to remove it.';
  static const String unprotectNoCredentialMessage =
      'Set up a PIN or pattern in Security before removing protection.';
  static const String unprotectUnavailableMessage =
      'Could not verify your identity. Protection unchanged.';

  /// Maps a CR-2 denial to its user-facing message.
  static String unprotectDeniedMessage(UnprotectDenial denial) =>
      switch (denial) {
        UnprotectDenial.notAuthenticated => unprotectNotConfirmedMessage,
        UnprotectDenial.noAppCredential => unprotectNoCredentialMessage,
        UnprotectDenial.credentialUnavailable => unprotectUnavailableMessage,
      };

  @override
  State<AppsScreen> createState() => _AppsScreenState();
}

enum _LoadState { loading, ready, error }

class _AppsScreenState extends State<AppsScreen> with WidgetsBindingObserver {
  _LoadState _state = _LoadState.loading;
  List<AppEntry> _apps = <AppEntry>[];
  Set<String> _protected = <String>{};
  int _fetchGeneration = 0;

  /// Phase 8 / M1: stored level per protected package, as last read from
  /// (or confirmed by) the repository. Never set optimistically.
  Map<String, AppSecurityLevel> _levels = <String, AppSecurityLevel>{};

  /// Packages whose level write is in flight (further taps are ignored).
  final Set<String> _levelSaving = <String>{};

  /// One level picker at a time.
  bool _levelSheetOpen = false;

  /// Phase 8 / M2 (8F): suggestions the user dismissed (`pkg@level`).
  Set<String> _dismissedSuggestions = <String>{};

  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  AppsFilter _filter = AppsFilter.all;

  // Phase 3G — bulk selection state.
  bool _selectionMode = false;
  Set<String> _selected = <String>{};
  bool _bulkBusy = false;

  /// CR-2: true while an unprotect confirmation is on screen. Further
  /// toggles are ignored so two confirmations can never interleave.
  bool _unprotectConfirming = false;

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
      _protected = result.valueOrNull!.map((app) => app.packageName).toSet();
      _levels = _levelsOf(result.valueOrNull!);
      _recomputeVisible();
    });
  }

  static Map<String, AppSecurityLevel> _levelsOf(List<ProtectedApp> apps) =>
      <String, AppSecurityLevel>{
        for (final ProtectedApp app in apps) app.packageName: app.securityLevel,
      };

  /// Phase 8 / M2 (8F): advisory only; a read failure shows no hints.
  Future<Set<String>> _readDismissedSuggestions() async {
    final container = AppScope.read(context);
    if (container == null) return <String>{};
    try {
      return await container.preferences.getDismissedSecurityRecommendations();
    } on Object {
      return <String>{};
    }
  }

  /// Phase 8 / M2: the level native last confirmed when it is STRICTER than
  /// the saved one (e.g. a downgrade not yet confirmed), else null.
  AppSecurityLevel? _heldLevel(String pkg) {
    final AppSecurityLevel? stored = _levels[pkg];
    final AppSecurityLevel? native =
        AppScope.read(context)?.protectionBootstrap.nativeLevelFor(pkg);
    if (stored == null || native == null) return null;
    return native.isStricterThan(stored) ? native : null;
  }

  /// Phase 8 / M2 (8F): the advisory suggestion for a protected row.
  SecurityRecommendation? _suggestionFor(String pkg) {
    final AppSecurityLevel? stored = _levels[pkg];
    if (stored == null) return null;
    return SecurityRecommendations.forApp(
      pkg,
      _heldLevel(pkg) ?? stored,
      dismissed: _dismissedSuggestions,
    );
  }

  /// Phase 8 (PRD 8B; M2 8C–8F): lets the user pick the security level of
  /// a protected app. Not optimistic: the row changes only after the
  /// repository confirms the write.
  ///
  ///  * Raising the level saves it, ends any unlock window or grace of the
  ///    app at once, then sends one snapshot to native (which also revokes
  ///    its authorization). No confirmation is needed.
  ///  * Lowering it (relative to the level actually ENFORCED, i.e. the
  ///    stricter of saved and native) first requires the CR-2 credential
  ///    gate; cancel or failure changes nothing. Only then is it saved and
  ///    sent to native with that package marked as a confirmed downgrade.
  ///  * If native does not confirm, the message says which level still
  ///    applies; a weaker level is never reported as active.
  ///
  /// Never grants a session, extends grace, clears a challenge or resets
  /// lockout.
  Future<void> _changeLevel(AppEntry app) async {
    final container = AppScope.read(context);
    final String pkg = app.packageName;
    final AppSecurityLevel? stored = _levels[pkg];
    if (container == null ||
        stored == null ||
        !_protected.contains(pkg) ||
        _levelSheetOpen ||
        _levelSaving.contains(pkg) ||
        _unprotectConfirming ||
        _bulkBusy ||
        _selectionMode) {
      return;
    }
    final AppSecurityLevel? held = _heldLevel(pkg);
    final AppSecurityLevel enforced = held ?? stored;
    final SecurityRecommendation? suggestion = _suggestionFor(pkg);
    _levelSheetOpen = true;
    final SecurityLevelSheetResult? picked;
    try {
      picked = await showSecurityLevelSheet(
        context,
        appLabel: app.label,
        current: stored,
        enforced: held,
        recommendation: suggestion,
      );
    } finally {
      _levelSheetOpen = false;
    }
    if (!mounted || picked == null) {
      return;
    }
    if (picked.dismissRecommendation) {
      if (suggestion == null) return;
      try {
        await container.preferences
            .dismissSecurityRecommendation(suggestion.dismissalKey);
      } on Object {
        // Advisory only: the hint is hidden for this session regardless.
      }
      if (!mounted) return;
      setState(() => _dismissedSuggestions = <String>{
            ..._dismissedSuggestions,
            suggestion.dismissalKey,
          });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(AppsScreen.suggestionDismissedMessage)),
      );
      return;
    }
    final AppSecurityLevel chosen = picked.level!;
    if (chosen == stored && chosen == enforced) {
      return;
    }
    if (!_protected.contains(pkg)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(AppsScreen.levelNotProtectedMessage)),
      );
      return;
    }
    final bool lowering = enforced.isStricterThan(chosen);
    UnprotectAuthorization? authorization;
    if (lowering) {
      final NavigatorState navigator = Navigator.of(context);
      _unprotectConfirming = true;
      final UnprotectRequestResult request;
      try {
        request = await requestUnprotectAuthorization(
          navigator: navigator,
          credentials: container.auth,
          packages: <String>{pkg},
          title: lowerLevelConfirmTitle,
        );
      } finally {
        _unprotectConfirming = false;
      }
      if (!mounted) {
        return; // torn down: nothing was changed
      }
      authorization = request.authorization;
      if (authorization == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppsScreen.levelLowerDeniedMessage(request.denial!)),
          ),
        );
        return;
      }
      if (!_protected.contains(pkg)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppsScreen.levelNotProtectedMessage)),
        );
        return;
      }
    }
    setState(() => _levelSaving.add(pkg));
    final result = lowering
        ? await lowerSecurityLevelWith(
            authorization!,
            container.protectedApps,
            pkg,
            chosen,
          )
        : await container.protectedApps.setSecurityLevel(pkg, chosen);
    if (!mounted) {
      return;
    }
    if (result.isFailure) {
      setState(() => _levelSaving.remove(pkg));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _protected.contains(pkg)
                ? AppsScreen.levelSaveFailed(enforced)
                : AppsScreen.levelNotProtectedMessage,
          ),
        ),
      );
      return;
    }
    if (!lowering) {
      // An older, more permissive unlock window never outlives an upgrade.
      await container.accessController.revokeImmediately(pkg);
    }
    final sync = await container.protectionBootstrap.synchronize(
      authorizedDowngrades: lowering ? <String>{pkg} : const <String>{},
    );
    if (!mounted) {
      return;
    }
    final AppSecurityLevel? native =
        container.protectionBootstrap.nativeLevelFor(pkg);
    final bool confirmed = sync.isSuccess && native == chosen;
    setState(() {
      _levelSaving.remove(pkg);
      _levels = <String, AppSecurityLevel>{..._levels, pkg: chosen};
    });
    final String message;
    if (confirmed) {
      message = AppsScreen.levelSaved(app.label, chosen);
    } else if (lowering) {
      message = AppsScreen.levelLowerNotApplied(
        app.label,
        chosen,
        native != null && native.isStricterThan(chosen) ? native : enforced,
      );
    } else {
      message = AppsScreen.levelSavedNotConfirmed(app.label, chosen);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
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
    final Set<String> succeeded = <String>{};
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
        succeeded.add(packageName);
      } else {
        failed.add(packageName);
      }
    }

    if (changed > 0) {
      await container.protectionBootstrap.synchronize();
    }

    if (!mounted) {
      return;
    }
    // Phase 8 / M1: show the stored level of every newly protected app.
    if (changed > 0) {
      final levels = await container.protectedApps.getProtectedApps();
      if (!mounted) {
        return;
      }
      _levels = levels.isSuccess
          ? _levelsOf(levels.valueOrNull!)
          : (Map<String, AppSecurityLevel>.of(_levels)
            ..removeWhere((String p, _) => succeeded.contains(p)));
    }
    if (failed.isNotEmpty) {
      setState(() {
        _protected = <String>{..._protected, ...succeeded};
        _recomputeVisible();
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
  ///
  /// CR-2: the selected PROTECTED apps are removed only after the user
  /// confirms with the Smart App Lock PIN or pattern. One confirmation
  /// covers exactly the selection snapshot. Denial changes nothing.
  Future<void> _bulkUnprotect() async {
    final container = AppScope.read(context);
    if (container == null ||
        _selected.isEmpty ||
        _bulkBusy ||
        _unprotectConfirming) {
      return;
    }
    // Snapshot: only apps that are protected now can lose protection, and
    // the confirmation covers exactly this set.
    final Set<String> targets = _selected.where(_protected.contains).toSet();
    final NavigatorState navigator = Navigator.of(context);
    setState(() => _bulkBusy = true);

    UnprotectAuthorization? authorization;
    if (targets.isNotEmpty) {
      _unprotectConfirming = true;
      final UnprotectRequestResult request;
      try {
        request = await requestUnprotectAuthorization(
          navigator: navigator,
          credentials: container.auth,
          packages: targets,
        );
      } finally {
        _unprotectConfirming = false;
      }
      if (!mounted) {
        return; // torn down: nothing was removed
      }
      authorization = request.authorization;
      if (authorization == null) {
        setState(() => _bulkBusy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppsScreen.unprotectDeniedMessage(request.denial!)),
          ),
        );
        return;
      }
    }

    int changed = 0;
    final Set<String> failed = <String>{};
    final Set<String> succeeded = <String>{};
    for (final String packageName in targets) {
      final result = await removeProtectionWith(
        authorization!,
        container.protectedApps,
        packageName,
      );
      if (result.isSuccess) {
        changed++;
        succeeded.add(packageName);
      } else {
        failed.add(packageName);
      }
    }

    if (changed > 0) {
      await container.protectionBootstrap.synchronize();
    }

    if (!mounted) {
      return;
    }
    _levels = Map<String, AppSecurityLevel>.of(_levels)
      ..removeWhere((String p, _) => succeeded.contains(p));
    if (failed.isNotEmpty) {
      setState(() {
        _protected = _protected.difference(succeeded);
        _recomputeVisible();
        _bulkBusy = false;
        _selected = failed;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppsScreen.bulkPartialFailure(failed.length))),
      );
      return;
    }

    setState(() {
      _protected = _protected.difference(targets);
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
  ///
  /// CR-2: turning protection OFF first requires confirmation with the
  /// Smart App Lock PIN or pattern. The switch does not move until the
  /// credential is verified. Denial leaves the app protected. Turning
  /// protection ON needs no confirmation.
  Future<void> _toggleProtection(AppEntry app) async {
    final container = AppScope.read(context);
    if (container == null || _unprotectConfirming) {
      return;
    }
    final bool wasProtected = _protected.contains(app.packageName);
    UnprotectAuthorization? authorization;
    if (wasProtected) {
      final NavigatorState navigator = Navigator.of(context);
      _unprotectConfirming = true;
      final UnprotectRequestResult request;
      try {
        request = await requestUnprotectAuthorization(
          navigator: navigator,
          credentials: container.auth,
          packages: <String>{app.packageName},
        );
      } finally {
        _unprotectConfirming = false;
      }
      if (!mounted) {
        return; // torn down: nothing was removed
      }
      authorization = request.authorization;
      if (authorization == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppsScreen.unprotectDeniedMessage(request.denial!)),
          ),
        );
        return;
      }
      if (!_protected.contains(app.packageName)) {
        return; // already unprotected meanwhile: nothing to remove
      }
    }
    setState(() {
      wasProtected
          ? _protected.remove(app.packageName)
          : _protected.add(app.packageName);
      _recomputeVisible();
    });

    final result = wasProtected
        ? await removeProtectionWith(
            authorization!,
            container.protectedApps,
            app.packageName,
          )
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
    await container.protectionBootstrap.synchronize();
    if (!mounted) {
      return;
    }
    // Phase 8 / M1: an unprotected app's level is retired with its record;
    // a newly protected app shows its stored level (Standard when new).
    if (wasProtected) {
      setState(() => _levels = Map<String, AppSecurityLevel>.of(_levels)
        ..remove(app.packageName));
    } else {
      await _refreshProtection();
      if (!mounted) {
        return;
      }
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
    if (protectedResult.isFailure) {
      // Never render an unknown protection set as "nothing protected".
      // That misrepresents persisted security state and lets subsequent
      // optimistic actions build on a false baseline.
      setState(() => _state = _LoadState.error);
      return;
    }
    final Set<String> protected =
        protectedResult.valueOrNull!.map((app) => app.packageName).toSet();
    final Set<String> dismissed = await _readDismissedSuggestions();
    if (!mounted || generation != _fetchGeneration) {
      return;
    }

    setState(() {
      _dismissedSuggestions = dismissed;
      _apps = appsResult.valueOrNull!;
      _protected = protected;
      _levels = _levelsOf(protectedResult.valueOrNull!);
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
          if (_selectionMode && _state == _LoadState.ready) _buildBulkBar(),
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
              onPressed: (nothingSelected || _bulkBusy) ? null : _bulkUnprotect,
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

            // Phase 8 / M1: a protected row shows its stored level and a
            // tap opens the level picker; unprotected rows are unchanged.
            final AppSecurityLevel? level =
                isProtected ? _levels[app.packageName] : null;
            final bool levelSaving = _levelSaving.contains(app.packageName);
            final AppSecurityLevel? held =
                isProtected ? _heldLevel(app.packageName) : null;
            final SecurityRecommendation? suggestion =
                isProtected ? _suggestionFor(app.packageName) : null;
            final bool canChangeLevel =
                container != null && level != null && !levelSaving;
            return Semantics(
              onTapHint: canChangeLevel ? AppsScreen.levelTapHint : null,
              child: ListTile(
                key: Key('app_tile_${app.packageName}'),
                onTap: canChangeLevel ? () => _changeLevel(app) : null,
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
                subtitle: Row(
                  children: <Widget>[
                    Text(
                      isProtected
                          ? AppsScreen.protectedLabel
                          : AppsScreen.unlockedLabel,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: isProtected
                                ? context.dsColors.success
                                : context.dsColors.textSecondary,
                          ),
                    ),
                    if (isProtected && (levelSaving || level != null))
                      Flexible(
                        child: Text(
                          levelSaving
                              ? AppsScreen.levelSavingSuffix
                              : AppsScreen.levelSuffix(level!),
                          key: Key('app_level_${app.packageName}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: context.dsColors.textSecondary),
                        ),
                      ),
                    if (isProtected && !levelSaving && held != null)
                      Flexible(
                        child: Text(
                          AppsScreen.levelHeldSuffix(held),
                          key: Key('app_level_held_${app.packageName}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: context.dsColors.warning),
                        ),
                      ),
                    if (isProtected && !levelSaving && suggestion != null)
                      Padding(
                        padding: const EdgeInsets.only(left: DsSpacing.xs),
                        child: Semantics(
                          label:
                              AppsScreen.suggestionSemantics(suggestion.level),
                          child: Icon(
                            Icons.tips_and_updates_outlined,
                            key: Key('app_suggestion_${app.packageName}'),
                            size: 16,
                            color: context.dsColors.primary,
                          ),
                        ),
                      ),
                  ],
                ),
                trailing: Switch(
                  key: Key('app_toggle_${app.packageName}'),
                  value: isProtected,
                  activeThumbColor: context.dsColors.primary,
                  onChanged:
                      container == null ? null : (_) => _toggleProtection(app),
                ),
              ),
            );
          },
        );
    }
  }

  /// Distinguishes why the visible list is empty: the name query matched
  /// nothing, the query matches something but the group filter has no
  /// members, or the group filter is empty globally.
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
    if (_query.isNotEmpty) {
      // The query matches apps, but none of them are in the active group:
      // clear the query to see them again.
      return _MessageCard(
        icon: Icons.filter_alt_off,
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
