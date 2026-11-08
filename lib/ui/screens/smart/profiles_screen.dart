/// Phase 11 / M2: list, switch, create, duplicate, edit and delete Security
/// Profiles. Opened from the Smart tab's profile card (no new tab).
///
/// Every change goes through `applyProfileChange` (profile_change.dart):
/// lowering protection needs the app's PIN/pattern; "active" is reported as
/// applied only after native acknowledged it.
library;

import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../data/models/protected_app.dart';
import '../../../design_system/design_system.dart';
import '../../../profiles/security_profile.dart';
import '../../../utilities/result.dart';
import 'profile_change.dart';
import 'profile_editor_screen.dart';
import 'profile_presentation.dart';
import 'smart_wide_button.dart';

class ProfilesScreen extends StatefulWidget {
  const ProfilesScreen({super.key, this.clock});

  static const String routeName = '/smart/profiles';

  /// Test seam for time.
  final DateTime Function()? clock;

  @override
  State<ProfilesScreen> createState() => _ProfilesScreenState();
}

class _ProfilesScreenState extends State<ProfilesScreen> {
  SecurityProfileSet? _set;
  Object? _error;
  bool _loading = false;
  bool _busy = false;
  List<ProtectedApp> _apps = const <ProtectedApp>[];
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _load();
    }
  }

  Future<void> _load() async {
    final container = AppScope.read(context);
    if (container == null) {
      _set = null;
      _error ??= StateError('Profiles are unavailable.');
      return;
    }
    setState(() => _loading = true);
    final Result<SecurityProfileSet> read =
        await container.securityProfiles.getProfiles();
    final Result<List<ProtectedApp>> apps =
        await container.protectedApps.getProtectedApps();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _set = read.valueOrNull;
      _error = read.isFailure
          ? (read.errorOrNull ?? StateError('No profiles read.'))
          : null;
      _apps = apps.valueOrNull ?? const <ProtectedApp>[];
    });
  }

  void _show(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(ProfileChange change, String name) async {
    final container = AppScope.read(context);
    if (container == null || _busy) return;
    final NavigatorState navigator = Navigator.of(context);
    setState(() => _busy = true);
    final ProfileChangeOutcome outcome = await applyProfileChange(
      change: change,
      navigator: navigator,
      profiles: container.securityProfiles,
      rules: container.smartRules,
      protectedApps: container.protectedApps,
      credentials: container.auth,
      accessController: container.accessController,
      bootstrap: container.protectionBootstrap,
      clock: widget.clock,
    );
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
    _show(ProfileText.outcome(outcome, name: name));
  }

  Future<void> _switchTo(SecurityProfile profile) async {
    final SecurityProfileSet? set = _set;
    if (set == null || set.activeProfileId == profile.id) return;
    final SecurityProfileSet? requested = switchedTo(set, profile.id);
    if (requested == null) return;
    await _run(
      ProfileChange(
        kind: ProfileChangeKind.switchProfile,
        expected: set,
        requested: requested,
      ),
      profile.name,
    );
  }

  Future<void> _delete(SecurityProfile profile) async {
    final SecurityProfileSet? set = _set;
    if (set == null || !profile.isRemovable) return;
    final bool active = set.activeProfileId == profile.id;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text(ProfileText.deleteTitle),
        content: Text(
          active ? ProfileText.deleteActiveBody : ProfileText.deleteBody,
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('profile_delete_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(ProfileText.cancel),
          ),
          TextButton(
            key: const Key('profile_delete_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(ProfileText.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(
      ProfileChange(
        kind: ProfileChangeKind.delete,
        expected: set,
        requested: set.without(profile.id),
      ),
      active ? SecurityProfileKind.normal.label : profile.name,
    );
  }

  Future<void> _openEditor({
    SecurityProfile? profile,
    SecurityProfile? duplicateOf,
  }) async {
    final SecurityProfileSet? set = _set;
    if (set == null || _busy) return;
    final ProfileEditorResult? result =
        await Navigator.of(context).push<ProfileEditorResult>(
      MaterialPageRoute<ProfileEditorResult>(
        settings: const RouteSettings(name: ProfileEditorScreen.routeName),
        builder: (BuildContext _) => ProfileEditorScreen(
          expected: set,
          profile: profile,
          duplicateOf: duplicateOf,
          protectedApps: _apps,
          clock: widget.clock,
        ),
      ),
    );
    if (!mounted) return;
    await _load();
    if (!mounted || result == null) return;
    _show(ProfileText.outcome(result.outcome, name: result.name));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(ProfileText.manageTitle)),
      body: SafeArea(
        child: ListView(
          key: const Key('profiles_list'),
          padding: DsInsets.screen,
          children: <Widget>[
            Text(
              ProfileText.intro,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: context.dsColors.textSecondary,
                  ),
            ),
            const SizedBox(height: DsSpacing.lg),
            ..._body(context),
          ],
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    final SecurityProfileSet? set = _set;
    if (set == null && _loading) {
      return const <Widget>[
        Padding(
          padding: EdgeInsets.all(DsSpacing.xl),
          child: Center(
            child: CircularProgressIndicator(
              semanticsLabel: ProfileText.loading,
            ),
          ),
        ),
      ];
    }
    if (set == null) {
      return <Widget>[
        DsCard(
          key: const Key('profiles_error'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(ProfileText.loadError(_error)),
              const SizedBox(height: DsSpacing.sm),
              TextButton(
                key: const Key('profiles_retry'),
                onPressed: _loading ? null : _load,
                child: const Text(ProfileText.retry),
              ),
            ],
          ),
        ),
      ];
    }
    final container = AppScope.read(context);
    final ProfileNativeStatus status = profileNativeStatus(
      saved: set,
      record: container?.protectionBootstrap.lastRuleExchange,
      protectedPackages: _apps.map((ProtectedApp a) => a.packageName).toSet(),
    );
    return <Widget>[
      SmartWideButton(
        key: const Key('profile_new'),
        label: ProfileText.create,
        icon: Icons.add,
        busy: _busy,
        onPressed: set.canAddCustom ? () => _openEditor() : null,
      ),
      if (!set.canAddCustom)
        Padding(
          padding: const EdgeInsets.only(top: DsSpacing.xs),
          child: Text(
            ProfileText.limitReached,
            key: const Key('profiles_limit'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      if (_apps.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: DsSpacing.sm),
          child: Text(
            ProfileText.noProtectedApps,
            key: const Key('profiles_no_apps'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      const SizedBox(height: DsSpacing.lg),
      for (final SecurityProfile p in set.profiles) ...<Widget>[
        _tile(context, set, p, status),
        const SizedBox(height: DsSpacing.md),
      ],
    ];
  }

  Widget _tile(
    BuildContext context,
    SecurityProfileSet set,
    SecurityProfile p,
    ProfileNativeStatus status,
  ) {
    final bool active = set.activeProfileId == p.id;
    final TextStyle? secondary =
        Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.dsColors.textSecondary,
            );
    return Semantics(
      selected: active,
      button: !active,
      label: active ? '${p.name}, ${ProfileText.active}' : p.name,
      excludeSemantics: false,
      child: DsCard(
        key: Key('profile_tile_${p.id}'),
        onTap: active || _busy ? null : () => _switchTo(p),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // The outer Semantics label already announces the name
                  // (and "Active"); don't make TalkBack read them twice.
                  ExcludeSemantics(
                    child: Text(
                      p.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(height: DsSpacing.xxs),
                  Text(ProfileText.explanation(p), style: secondary),
                  Text(ProfileText.summary(p), style: secondary),
                  const SizedBox(height: DsSpacing.xs),
                  Wrap(
                    spacing: DsSpacing.xs,
                    runSpacing: DsSpacing.xs,
                    children: <Widget>[
                      DsStatusPill(
                        label: p.isCustom
                            ? ProfileText.custom
                            : ProfileText.preset,
                        tone: DsTone.neutral,
                      ),
                      if (active)
                        const ExcludeSemantics(
                          child: DsStatusPill(
                            key: Key('profile_active_pill'),
                            label: ProfileText.active,
                            tone: DsTone.info,
                          ),
                        ),
                    ],
                  ),
                  if (active)
                    Padding(
                      padding: const EdgeInsets.only(top: DsSpacing.xs),
                      child: Text(
                        ProfileText.nativeStatus(status),
                        key: const Key('profile_native_status'),
                        style: secondary,
                      ),
                    ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              key: Key('profile_menu_${p.id}'),
              enabled: !_busy,
              tooltip: 'More actions for ${p.name}',
              onSelected: (String action) => switch (action) {
                'use' => _switchTo(p),
                'edit' => _openEditor(profile: p),
                'duplicate' => _openEditor(duplicateOf: p),
                'delete' => _delete(p),
                _ => null,
              },
              itemBuilder: (BuildContext _) => <PopupMenuEntry<String>>[
                if (!active)
                  const PopupMenuItem<String>(
                    value: 'use',
                    child: Text(ProfileText.makeActive),
                  ),
                if (p.isEditable)
                  const PopupMenuItem<String>(
                    value: 'edit',
                    child: Text(ProfileText.edit),
                  ),
                PopupMenuItem<String>(
                  value: 'duplicate',
                  enabled: set.canAddCustom,
                  child: const Text(ProfileText.duplicate),
                ),
                if (p.isRemovable)
                  const PopupMenuItem<String>(
                    value: 'delete',
                    child: Text(ProfileText.delete),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
