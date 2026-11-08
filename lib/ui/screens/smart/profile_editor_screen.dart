/// Phase 11 / M2: create, duplicate or edit a Security Profile.
///
/// Only apps that are ALREADY protected can be given extra protection
/// (Sensitive or Critical); a profile never enrols an app and never changes
/// a saved level. Entries for apps that are no longer protected are kept
/// unchanged (they have no effect).
///
/// Saving goes through `applyProfileChange`: an inactive profile is saved
/// without contacting native; an edit of the ACTIVE profile that lowers
/// protection asks for the app's PIN/pattern first. A failed or conflicting
/// save keeps the draft. Leaving with unsaved changes asks
/// "Discard changes?" (Discard changes / Keep editing).
library;

import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../data/models/app_security_level.dart';
import '../../../data/models/protected_app.dart';
import '../../../design_system/design_system.dart';
import '../../../profiles/security_profile.dart';
import 'profile_change.dart';
import 'profile_presentation.dart';
import 'smart_wide_button.dart';

/// What the editor returns after a stored change.
final class ProfileEditorResult {
  const ProfileEditorResult(this.outcome, {required this.name});

  final ProfileChangeOutcome outcome;
  final String name;
}

class ProfileEditorScreen extends StatefulWidget {
  const ProfileEditorScreen({
    super.key,
    required this.expected,
    required this.protectedApps,
    this.profile,
    this.duplicateOf,
    this.clock,
  });

  static const String routeName = '/smart/profiles/edit';

  /// The profile set the list showed (compare-and-swap expectation).
  final SecurityProfileSet expected;

  /// The apps currently protected (the only ones that can be raised).
  final List<ProtectedApp> protectedApps;

  /// The profile being edited; null creates a new custom profile.
  final SecurityProfile? profile;

  /// Creates a new custom profile pre-filled from this one.
  final SecurityProfile? duplicateOf;

  final DateTime Function()? clock;

  @override
  State<ProfileEditorScreen> createState() => _ProfileEditorScreenState();
}

class _ProfileEditorScreenState extends State<ProfileEditorScreen> {
  late final TextEditingController _name;
  late final String _newId;
  late final String _initialName;
  late final AppSecurityLevel? _initialAll;
  late final Map<String, AppSecurityLevel> _initialApps;
  AppSecurityLevel? _all;
  late Map<String, AppSecurityLevel> _apps;
  String? _nameError;
  String? _message;
  bool _saving = false;
  bool _closing = false;

  bool get _isNew => widget.profile == null;
  bool get _nameEditable => _isNew || widget.profile!.isCustom;

  @override
  void initState() {
    super.initState();
    final SecurityProfile? source = widget.profile ?? widget.duplicateOf;
    // A new profile keeps ONE id across retries (no duplicates on retry).
    _newId = SecurityProfile.newCustomId(
      widget.expected.profiles.map((SecurityProfile p) => p.id).toSet(),
    );
    _initialName = widget.profile?.name ??
        (widget.duplicateOf == null ? '' : _copyName(widget.duplicateOf!));
    _initialAll = source?.allProtectedLevel;
    _initialApps = Map<String, AppSecurityLevel>.of(
      source?.appLevels ?? const <String, AppSecurityLevel>{},
    );
    _name = TextEditingController(text: _initialName);
    _all = _initialAll;
    _apps = Map<String, AppSecurityLevel>.of(_initialApps);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String _copyName(SecurityProfile p) {
    String candidate(int n) {
      final String suffix = n == 1 ? ' copy' : ' copy $n';
      final int room = SecurityProfile.maxNameLength - suffix.length;
      final String base =
          p.name.length > room ? p.name.substring(0, room) : p.name;
      return '${base.trim()}$suffix';
    }

    for (int n = 1; n < 100; n++) {
      if (widget.expected.isNameAvailable(candidate(n))) return candidate(n);
    }
    return '';
  }

  bool get _dirty {
    if (_name.text != _initialName || _all != _initialAll) return true;
    if (_apps.length != _initialApps.length) return true;
    for (final MapEntry<String, AppSecurityLevel> e in _apps.entries) {
      if (_initialApps[e.key] != e.value) return true;
    }
    return _isNew;
  }

  Future<void> _save() async {
    final container = AppScope.read(context);
    if (container == null || _saving) return;
    final SecurityProfileSet expected = widget.expected;
    final SecurityProfile? existing = widget.profile;
    final String name = _name.text.trim();
    if (_nameEditable) {
      final String? problem = SecurityProfile.validateName(name);
      final String? error = problem ??
          (expected.isNameAvailable(name, exceptId: existing?.id)
              ? null
              : ProfileText.nameTaken);
      if (error != null) {
        setState(() => _nameError = error);
        return;
      }
    }
    final SecurityProfileSet requested;
    final SecurityProfile built;
    try {
      built = existing == null
          ? SecurityProfile.custom(
              id: _newId,
              name: name,
              allProtectedLevel: _all,
              appLevels: _apps,
            )
          : existing.copyWith(
              name: existing.isCustom ? name : null,
              allProtectedLevel: _all,
              clearAll: _all == null,
              appLevels: _apps,
            );
      requested = existing == null
          ? expected.withAdded(built)
          : expected.withProfile(built);
    } on SecurityProfileFormatException catch (e) {
      setState(() {
        _nameError = null;
        _message = '${ProfileText.outcome(
          const ProfileChangeOutcome(ProfileChangeStatus.invalid),
          name: name,
        )} ${e.message}';
      });
      return;
    }
    final NavigatorState navigator = Navigator.of(context);
    setState(() {
      _saving = true;
      _nameError = null;
      _message = null;
    });
    final ProfileChangeOutcome outcome = await applyProfileChange(
      change: ProfileChange(
        kind: ProfileChangeKind.save,
        expected: expected,
        requested: requested,
      ),
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
    if (outcome.saved) {
      setState(() => _closing = true);
      Navigator.of(context).pop(ProfileEditorResult(outcome, name: built.name));
      return;
    }
    // Not saved: the draft stays for another try.
    setState(() {
      _saving = false;
      _message = ProfileText.outcome(outcome, name: built.name);
    });
  }

  Future<void> _confirmDiscard() async {
    final bool? discard = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text(ProfileText.discardTitle),
        content: const Text(ProfileText.discardBody),
        actions: <Widget>[
          TextButton(
            key: const Key('profile_keep_editing'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(ProfileText.keepEditing),
          ),
          TextButton(
            key: const Key('profile_discard'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(ProfileText.discard),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      setState(() => _closing = true);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool canLeave = _closing || !_dirty;
    final Set<String> protectedPackages =
        widget.protectedApps.map((ProtectedApp a) => a.packageName).toSet();
    final int kept =
        _apps.keys.where((String p) => !protectedPackages.contains(p)).length;
    final TextStyle? secondary =
        Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.dsColors.textSecondary,
            );
    return PopScope<Object?>(
      canPop: canLeave && !_saving,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop || _saving || _closing) return;
        _confirmDiscard();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _isNew ? ProfileText.editorNewTitle : ProfileText.editorEditTitle,
          ),
        ),
        body: SafeArea(
          child: ListView(
            key: const Key('profile_editor_list'),
            padding: DsInsets.screen,
            children: <Widget>[
              if (_nameEditable)
                TextField(
                  key: const Key('profile_editor_name'),
                  controller: _name,
                  enabled: !_saving,
                  maxLength: SecurityProfile.maxNameLength,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: ProfileText.nameLabel,
                    errorText: _nameError,
                  ),
                  onChanged: (_) => setState(() => _nameError = null),
                )
              else
                Semantics(
                  header: true,
                  child: Text(
                    widget.profile!.name,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
              const SizedBox(height: DsSpacing.md),
              Text(
                ProfileText.allLabel,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: DsSpacing.xs),
              _levelChoice(
                keyPrefix: 'profile_editor_all',
                label: ProfileText.allLabel,
                value: _all,
                onChanged: (AppSecurityLevel? v) => setState(() => _all = v),
              ),
              const SizedBox(height: DsSpacing.lg),
              Text(
                ProfileText.appsLabel,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: DsSpacing.xs),
              if (widget.protectedApps.isEmpty)
                Text(ProfileText.noProtectedApps, style: secondary),
              for (final ProtectedApp app in widget.protectedApps)
                Padding(
                  padding: const EdgeInsets.only(bottom: DsSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(app.label),
                      Text(
                        'Saved level: '
                        '${ProfileText.levelName(app.securityLevel)}',
                        style: secondary,
                      ),
                      const SizedBox(height: DsSpacing.xxs),
                      _levelChoice(
                        keyPrefix: 'profile_editor_app_${app.packageName}',
                        label: app.label,
                        value: _apps[app.packageName],
                        onChanged: (AppSecurityLevel? v) => setState(() {
                          if (v == null) {
                            _apps.remove(app.packageName);
                          } else {
                            _apps[app.packageName] = v;
                          }
                        }),
                      ),
                    ],
                  ),
                ),
              if (kept > 0)
                Text(
                  '$kept setting${kept == 1 ? '' : 's'} for apps that are no '
                  'longer protected are kept and have no effect.',
                  key: const Key('profile_editor_kept'),
                  style: secondary,
                ),
              const SizedBox(height: DsSpacing.sm),
              Text(ProfileText.suggestionNote, style: secondary),
              if (_message case final String message) ...<Widget>[
                const SizedBox(height: DsSpacing.md),
                Text(
                  message,
                  key: const Key('profile_editor_message'),
                  style: TextStyle(color: context.dsColors.danger),
                ),
              ],
              const SizedBox(height: DsSpacing.lg),
              SmartWideButton(
                key: const Key('profile_editor_save'),
                label: ProfileText.save,
                icon: Icons.check,
                busy: _saving,
                onPressed: _save,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _levelChoice({
    required String keyPrefix,
    required String label,
    required AppSecurityLevel? value,
    required ValueChanged<AppSecurityLevel?> onChanged,
  }) {
    const List<AppSecurityLevel?> options = <AppSecurityLevel?>[
      null,
      AppSecurityLevel.sensitive,
      AppSecurityLevel.critical,
    ];
    return Wrap(
      spacing: DsSpacing.xs,
      runSpacing: DsSpacing.xs,
      children: <Widget>[
        for (final AppSecurityLevel? option in options)
          Semantics(
            label: '$label: ${ProfileText.levelName(option)}',
            excludeSemantics: true,
            selected: value == option,
            button: true,
            child: ChoiceChip(
              key: Key('${keyPrefix}_${option?.storageId ?? 'none'}'),
              label: Text(ProfileText.levelName(option)),
              selected: value == option,
              onSelected: _saving ? null : (_) => onChanged(option),
            ),
          ),
      ],
    );
  }
}
