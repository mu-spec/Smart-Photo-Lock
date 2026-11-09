import 'dart:math';

import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../data/models/app_security_level.dart';
import '../../../data/models/protected_app.dart';
import '../../../design_system/design_system.dart';
import '../../../profiles/security_profile.dart';
import '../../../profiles/security_profile_policy.dart';
import '../../../rules/smart_rule.dart';
import '../../../rules/smart_rule_policy.dart';
import '../../../utilities/result.dart';
import 'smart_rule_change.dart';
import 'smart_rule_presentation.dart';
import 'smart_wide_button.dart';

/// Phase 10 / M2 (PRD 10G, 10H): create or edit one Smart Rule.
///
/// Sections in flow order: name → protected apps → days → time (or All
/// day) → security level → review. Validation never lets a blank name, an
/// empty app or day selection, a zero-length window or a missing level
/// through, and only protected apps (or targets the rule already had) can
/// be selected.
///
/// Saving goes through [applySmartRuleChange] (fresh read, stale-form
/// check, CR-2 when protection is reduced, compare-and-swap write, native
/// sync). The screen closes only once the change is stored; on any failure
/// the draft stays for a retry.
///
/// Unsaved-draft guard: leaving with changes asks "Discard changes?"
/// (Discard changes / Keep editing). An unchanged or saved form closes
/// normally. Routes pushed on top (the CR-2 confirmation, a lock challenge)
/// are never intercepted: the guard applies to this route only.
///
/// Phase 11 / M3: the level choices include "Apply profile". Such a rule has
/// no app list (the profile decides which protected apps get extra
/// protection); a profile picker replaces it. The manually selected profile
/// is never changed by a rule.
class SmartRuleEditorScreen extends StatefulWidget {
  const SmartRuleEditorScreen({
    super.key,
    this.initial,
    this.pickTime,
    this.newId,
    this.clock,
  });

  static const String routeName = '/smart/rule-editor';

  /// The rule as shown in the list (null = new rule).
  final SmartRule? initial;

  /// Test seam for the time picker (defaults to [showTimePicker]).
  final Future<TimeOfDay?> Function(BuildContext context, TimeOfDay initial)?
      pickTime;

  /// Test seam for new rule ids.
  final String Function()? newId;

  /// Test seam for the CR-2 proof and immediate-revocation clock.
  final DateTime Function()? clock;

  @override
  State<SmartRuleEditorScreen> createState() => _SmartRuleEditorScreenState();
}

/// Everything the form can change (for the dirty check).
@immutable
class _Draft {
  const _Draft({
    required this.name,
    required this.targets,
    required this.days,
    required this.allDay,
    required this.start,
    required this.end,
    required this.action,
    required this.profileId,
  });

  final String name;
  final Set<String> targets;
  final Set<int> days;
  final bool allDay;
  final int start;
  final int end;
  final SmartRuleAction? action;
  final String? profileId;

  static bool _sameSet<T>(Set<T> a, Set<T> b) =>
      a.length == b.length && a.containsAll(b);

  @override
  bool operator ==(Object other) =>
      other is _Draft &&
      other.name == name &&
      _sameSet(other.targets, targets) &&
      _sameSet(other.days, days) &&
      other.allDay == allDay &&
      // The window only matters when it is used.
      (allDay || (other.start == start && other.end == end)) &&
      other.action == action &&
      other.profileId == profileId;

  @override
  int get hashCode => Object.hash(name, allDay, action, profileId);
}

class _SmartRuleEditorScreenState extends State<SmartRuleEditorScreen> {
  static const int _defaultStart = 9 * 60;
  static const int _defaultEnd = 17 * 60;

  late final TextEditingController _name;
  late Set<String> _targets;
  late Set<int> _days;
  late bool _allDay;
  late int _start;
  late int _end;
  SmartRuleAction? _action;
  String? _profileId;
  late _Draft _initialDraft;

  /// Phase 11 / M3: the profiles a rule can apply (null until loaded).
  SecurityProfileSet? _profileSet;
  bool _profilesFailed = false;

  List<ProtectedApp>? _apps;
  bool _appsFailed = false;
  bool _appsRequested = false;

  bool _saving = false;
  bool _submitted = false;
  bool _closing = false;
  String? _message;

  bool get _isNew => widget.initial == null;

  @override
  void initState() {
    super.initState();
    final SmartRule? r = widget.initial;
    _name = TextEditingController(text: r?.name ?? '');
    _targets = <String>{...?r?.targetPackages};
    _days = <int>{...?r?.days};
    final SmartRuleTime? time = r?.time;
    _allDay = time is SmartRuleAllDay;
    _start = time is SmartRuleWindow ? time.startMinute : _defaultStart;
    _end = time is SmartRuleWindow ? time.endMinute : _defaultEnd;
    _action = r?.action;
    _profileId = r?.profileId;
    _initialDraft = _draft();
    _name.addListener(_onNameChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_appsRequested) {
      _appsRequested = true;
      _loadApps();
    }
  }

  @override
  void dispose() {
    _name.removeListener(_onNameChanged);
    _name.dispose();
    super.dispose();
  }

  void _onNameChanged() => setState(() {});

  _Draft _draft() => _Draft(
        name: _name.text,
        targets: <String>{..._targets},
        days: <int>{..._days},
        allDay: _allDay,
        start: _start,
        end: _end,
        action: _action,
        profileId: _isProfile ? _profileId : null,
      );

  bool get _isProfile => _action == SmartRuleAction.applyProfile;

  bool get _dirty => _draft() != _initialDraft;

  Future<void> _loadApps() async {
    final container = AppScope.read(context);
    if (container == null) {
      setState(() => _appsFailed = true);
      return;
    }
    setState(() {
      _appsFailed = false;
      _profilesFailed = false;
    });
    final Result<SecurityProfileSet> profiles =
        await container.securityProfiles.getProfiles();
    final Result<List<ProtectedApp>> result =
        await container.protectedApps.getProtectedApps();
    if (!mounted) return;
    setState(() {
      _profileSet = profiles.valueOrNull;
      _profilesFailed = profiles.isFailure || profiles.valueOrNull == null;
    });
    final List<ProtectedApp>? apps = result.valueOrNull;
    setState(() {
      if (result.isFailure || apps == null) {
        _appsFailed = true;
      } else {
        _apps = <ProtectedApp>[...apps]..sort(
            (ProtectedApp a, ProtectedApp b) =>
                a.label.toLowerCase().compareTo(b.label.toLowerCase()),
          );
      }
    });
  }

  // ---- Validation -------------------------------------------------------

  String? get _nameError {
    final String name = _name.text.trim();
    if (name.isEmpty) return SmartRuleText.nameRequired;
    if (name.runes.length > SmartRule.maxNameLength) {
      return SmartRuleText.nameTooLong;
    }
    try {
      SmartRule(
        id: 'validate',
        name: name,
        targetPackages: const <String>['a.b'],
        days: const <int>[1],
        time: const SmartRuleTime.allDay(),
      );
    } on SmartRuleFormatException {
      return SmartRuleText.nameInvalid;
    }
    return null;
  }

  String? get _appsError =>
      !_isProfile && _targets.isEmpty ? SmartRuleText.appsRequired : null;

  /// Phase 11 / M3: a profile rule needs an existing profile.
  String? get _profileError {
    if (!_isProfile) return null;
    final String? id = _profileId;
    if (id == null) return SmartRuleText.profileRequired;
    final SecurityProfileSet? set = _profileSet;
    if (set == null) return SmartRuleText.profilesUnavailable;
    if (set.byId(id) == null) return SmartRuleText.profileMissing;
    return null;
  }

  String? get _daysError => _days.isEmpty ? SmartRuleText.daysRequired : null;

  String? get _timeError =>
      !_allDay && _start == _end ? SmartRuleText.windowInvalid : null;

  String? get _levelError =>
      _action == null ? SmartRuleText.levelRequired : null;

  /// The rule the form describes, or null when anything is invalid.
  SmartRule? _buildRule() {
    final SmartRuleAction? action = _action;
    if (_nameError != null ||
        _appsError != null ||
        _daysError != null ||
        _timeError != null ||
        _profileError != null ||
        action == null) {
      return null;
    }
    try {
      return SmartRule(
        id: widget.initial?.id ?? (widget.newId ?? _generateId)(),
        name: _name.text.trim(),
        enabled: widget.initial?.enabled ?? true,
        targetPackages: _isProfile ? const <String>[] : _targets,
        days: _days,
        time: _allDay
            ? const SmartRuleTime.allDay()
            : SmartRuleTime.window(startMinute: _start, endMinute: _end),
        action: action,
        profileId: _isProfile ? _profileId : null,
      );
    } on SmartRuleFormatException {
      return null;
    }
  }

  static String _generateId() {
    final Random random = Random.secure();
    return 'rule-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '-${random.nextInt(1 << 30).toRadixString(36)}';
  }

  // ---- Actions ----------------------------------------------------------

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _submitted = true;
      _message = null;
    });
    final SmartRule? rule = _buildRule();
    final container = AppScope.read(context);
    if (rule == null || container == null) return;
    final SmartRule? initial = widget.initial;
    final NavigatorState navigator = Navigator.of(context);
    setState(() => _saving = true);
    final SmartRuleChangeOutcome outcome = await applySmartRuleChange(
      change: initial == null
          ? SmartRuleCreate(rule)
          : SmartRuleEdit(expected: initial, rule: rule),
      navigator: navigator,
      repository: container.smartRules,
      profiles: container.securityProfiles,
      protectedApps: container.protectedApps,
      credentials: container.auth,
      accessController: container.accessController,
      bootstrap: container.protectionBootstrap,
      clock: widget.clock,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (outcome.saved) {
      _close(outcome);
    } else {
      setState(() => _message = SmartRuleText.outcome(outcome));
    }
  }

  Future<void> _delete() async {
    final SmartRule? initial = widget.initial;
    final container = AppScope.read(context);
    if (_saving || initial == null || container == null) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text(SmartRuleText.deleteConfirmTitle),
        content: const Text(SmartRuleText.deleteConfirmBody),
        actions: <Widget>[
          TextButton(
            key: const Key('smart_delete_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(SmartRuleText.cancel),
          ),
          TextButton(
            key: const Key('smart_delete_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(SmartRuleText.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final NavigatorState navigator = Navigator.of(context);
    setState(() {
      _saving = true;
      _message = null;
    });
    final SmartRuleChangeOutcome outcome = await applySmartRuleChange(
      change: SmartRuleDelete(initial),
      navigator: navigator,
      repository: container.smartRules,
      profiles: container.securityProfiles,
      protectedApps: container.protectedApps,
      credentials: container.auth,
      accessController: container.accessController,
      bootstrap: container.protectionBootstrap,
      clock: widget.clock,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (outcome.saved) {
      _close(outcome, deleted: true);
    } else {
      setState(() => _message = SmartRuleText.outcome(outcome, deleting: true));
    }
  }

  /// Leaves after a stored change (the guard no longer applies).
  void _close(SmartRuleChangeOutcome outcome, {bool deleted = false}) {
    setState(() => _closing = true);
    Navigator.of(context).pop(SmartRuleEditorResult(outcome, deleted: deleted));
  }

  Future<void> _confirmDiscard() async {
    final bool? discard = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text(SmartRuleText.discardTitle),
        content: const Text(SmartRuleText.discardBody),
        actions: <Widget>[
          TextButton(
            key: const Key('smart_keep_editing'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(SmartRuleText.keepEditing),
          ),
          TextButton(
            key: const Key('smart_discard'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(SmartRuleText.discard),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      setState(() => _closing = true);
      Navigator.of(context).pop();
    }
  }

  Future<void> _pick(bool start) async {
    final int current = start ? _start : _end;
    final TimeOfDay initial =
        TimeOfDay(hour: current ~/ 60, minute: current % 60);
    final TimeOfDay? picked = widget.pickTime != null
        ? await widget.pickTime!(context, initial)
        : await showTimePicker(context: context, initialTime: initial);
    if (picked == null || !mounted) return;
    setState(() {
      final int minute = picked.hour * 60 + picked.minute;
      if (start) {
        _start = minute;
      } else {
        _end = minute;
      }
    });
  }

  // ---- Build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final bool canLeave = _closing || !_dirty;
    return PopScope<Object?>(
      canPop: canLeave && !_saving,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop || _saving || _closing) return;
        _confirmDiscard();
      },
      child: Scaffold(
        appBar: AppBar(
          title:
              Text(_isNew ? SmartRuleText.newTitle : SmartRuleText.editTitle),
        ),
        body: SafeArea(
          child: ListView(
            key: const Key('smart_editor_list'),
            padding: DsInsets.screen,
            children: <Widget>[
              _nameSection(context),
              const SizedBox(height: DsSpacing.xl),
              if (!_isProfile) ...<Widget>[
                _appsSection(context),
                const SizedBox(height: DsSpacing.xl),
              ],
              _daysSection(context),
              const SizedBox(height: DsSpacing.xl),
              _timeSection(context),
              const SizedBox(height: DsSpacing.xl),
              _levelSection(context),
              const SizedBox(height: DsSpacing.xl),
              if (_isProfile) ...<Widget>[
                _profileSection(context),
                const SizedBox(height: DsSpacing.xl),
              ],
              _reviewSection(context),
              const SizedBox(height: DsSpacing.lg),
              if (_message != null) ...<Widget>[
                Semantics(
                  liveRegion: true,
                  child: DsCard(
                    key: const Key('smart_editor_message'),
                    color: context.dsColors.danger.withValues(alpha: 0.08),
                    child: Text(_message!),
                  ),
                ),
                const SizedBox(height: DsSpacing.lg),
              ],
              SmartWideButton(
                key: const Key('smart_save'),
                label: SmartRuleText.save,
                icon: Icons.check,
                busy: _saving,
                onPressed: _save,
              ),
              if (!_isNew) ...<Widget>[
                const SizedBox(height: DsSpacing.md),
                SmartWideButton(
                  key: const Key('smart_delete'),
                  label: SmartRuleText.delete,
                  icon: Icons.delete_outline,
                  danger: true,
                  onPressed: _saving ? null : _delete,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _error(BuildContext context, String? text, String key) {
    if (!_submitted || text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: DsSpacing.xs),
      child: Semantics(
        liveRegion: true,
        child: Text(
          text,
          key: Key(key),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
    );
  }

  Widget _title(String text) => Semantics(
        header: true,
        child: DsSectionTitle(text),
      );

  Widget _nameSection(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            key: const Key('smart_name'),
            controller: _name,
            enabled: !_saving,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: SmartRuleText.nameLabel,
              errorText: _submitted ? _nameError : null,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      );

  Widget _appsSection(BuildContext context) {
    final List<ProtectedApp>? apps = _apps;
    final List<Widget> rows = <Widget>[];
    if (apps == null && !_appsFailed) {
      rows.add(const Padding(
        padding: EdgeInsets.all(DsSpacing.md),
        child: Center(child: CircularProgressIndicator()),
      ));
    } else if (apps == null) {
      rows.add(Row(
        children: <Widget>[
          const Expanded(child: Text(SmartRuleText.appsLoadFailed)),
          TextButton(
            key: const Key('smart_apps_retry'),
            onPressed: _loadApps,
            child: const Text(SmartRuleText.retry),
          ),
        ],
      ));
    } else {
      final Set<String> protected =
          apps.map((ProtectedApp a) => a.packageName).toSet();
      if (apps.isEmpty && _targets.isEmpty) {
        rows.add(const Text(SmartRuleText.noProtectedApps));
      }
      for (final ProtectedApp app in apps) {
        rows.add(_appTile(app.packageName, app.label, app.securityLevel.label));
      }
      // Targets the rule already had but that are no longer protected stay
      // visible (never silently dropped) so the user can remove them.
      for (final String pkg in (_targets.difference(protected).toList()
        ..sort())) {
        rows.add(_appTile(pkg, pkg, SmartRuleText.notProtectedNote));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _title(SmartRuleText.appsTitle),
        Text(
          SmartRuleText.appsHelp,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        ...rows,
        _error(context, _appsError, 'smart_apps_error'),
      ],
    );
  }

  Widget _appTile(String pkg, String label, String subtitle) =>
      CheckboxListTile(
        key: Key('smart_app_$pkg'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _targets.contains(pkg),
        title: Text(label),
        subtitle: Text(subtitle),
        onChanged: _saving
            ? null
            : (bool? v) => setState(() {
                  if (v == true) {
                    _targets.add(pkg);
                  } else {
                    _targets.remove(pkg);
                  }
                }),
      );

  Widget _daysSection(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _title(SmartRuleText.daysTitle),
          const SizedBox(height: DsSpacing.xs),
          Wrap(
            spacing: DsSpacing.sm,
            runSpacing: DsSpacing.sm,
            children: <Widget>[
              for (final int day in SmartRuleDays.everyDay)
                Semantics(
                  label: SmartRuleText.dayLong(day),
                  excludeSemantics: true,
                  selected: _days.contains(day),
                  button: true,
                  onTap: _saving ? null : () => _toggleDay(day),
                  child: FilterChip(
                    key: Key('smart_day_$day'),
                    label: Text(SmartRuleText.dayShort(day)),
                    selected: _days.contains(day),
                    onSelected: _saving ? null : (_) => _toggleDay(day),
                  ),
                ),
            ],
          ),
          _error(context, _daysError, 'smart_days_error'),
        ],
      );

  void _toggleDay(int day) => setState(() {
        if (!_days.remove(day)) _days.add(day);
      });

  Widget _timeSection(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _title(SmartRuleText.timeTitle),
          SwitchListTile(
            key: const Key('smart_all_day'),
            contentPadding: EdgeInsets.zero,
            title: const Text(SmartRuleText.allDay),
            value: _allDay,
            onChanged: _saving ? null : (bool v) => setState(() => _allDay = v),
          ),
          if (!_allDay) ...<Widget>[
            ListTile(
              key: const Key('smart_start'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule),
              title: const Text(SmartRuleText.startLabel),
              subtitle: Text(SmartRuleText.minute(_start)),
              trailing: const Icon(Icons.edit_outlined),
              onTap: _saving ? null : () => _pick(true),
            ),
            ListTile(
              key: const Key('smart_end'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule_outlined),
              title: const Text(SmartRuleText.endLabel),
              subtitle: Text(
                _end < _start
                    ? '${SmartRuleText.minute(_end)} (next day)'
                    : SmartRuleText.minute(_end),
              ),
              trailing: const Icon(Icons.edit_outlined),
              onTap: _saving ? null : () => _pick(false),
            ),
          ],
          _error(context, _timeError, 'smart_time_error'),
        ],
      );

  Widget _levelSection(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _title(SmartRuleText.levelTitle),
          for (final SmartRuleAction action in SmartRuleAction.values)
            _levelTile(context, action),
          _error(context, _levelError, 'smart_level_error'),
        ],
      );

  Widget _levelTile(BuildContext context, SmartRuleAction action) {
    final bool selected = _action == action;
    // Unlocked is reserved: shown as not available, never selectable.
    final bool available = action != SmartRuleAction.unlocked;
    // MergeSemantics: the group / selected flags land on the tile's own
    // node (the one TalkBack focuses), not on an ancestor.
    return MergeSemantics(
      child: Semantics(
        inMutuallyExclusiveGroup: true,
        selected: selected,
        child: ListTile(
          key: Key('smart_level_${action.storageId}'),
          contentPadding: EdgeInsets.zero,
          enabled: available && !_saving,
          leading: Icon(
            selected
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
          ),
          title: Text(action.label),
          subtitle: Text(SmartRuleText.actionDescription(action)),
          onTap: available ? () => setState(() => _action = action) : null,
        ),
      ),
    );
  }

  /// Phase 11 / M3: the profile picker of an "Apply profile" rule.
  Widget _profileSection(BuildContext context) {
    final SecurityProfileSet? set = _profileSet;
    final List<Widget> rows = <Widget>[];
    if (set == null && !_profilesFailed) {
      rows.add(const Padding(
        padding: EdgeInsets.all(DsSpacing.md),
        child: Center(child: CircularProgressIndicator()),
      ));
    } else if (set == null) {
      rows.add(Row(
        children: <Widget>[
          const Expanded(child: Text(SmartRuleText.profilesUnavailable)),
          TextButton(
            key: const Key('smart_profiles_retry'),
            onPressed: _loadApps,
            child: const Text(SmartRuleText.retry),
          ),
        ],
      ));
    } else {
      final String? id = _profileId;
      if (id != null && set.byId(id) == null) {
        rows.add(DsCard(
          key: const Key('smart_profile_missing'),
          color: context.dsColors.warning.withValues(alpha: 0.10),
          child: const Text(SmartRuleText.profileMissing),
        ));
      }
      for (final SecurityProfile p in set.profiles) {
        final bool selected = _profileId == p.id;
        rows.add(MergeSemantics(
            child: Semantics(
          inMutuallyExclusiveGroup: true,
          selected: selected,
          child: ListTile(
            key: Key('smart_profile_${p.id}'),
            contentPadding: EdgeInsets.zero,
            enabled: !_saving,
            leading: Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
            ),
            title: Text(p.name),
            subtitle: Text(_profileExplanation(p)),
            onTap: () => setState(() => _profileId = p.id),
          ),
        )));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _title(SmartRuleText.profileTitle),
        Text(
          SmartRuleText.profileAppsNote,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        ...rows,
        if (_profileError != SmartRuleText.profileMissing)
          _error(context, _profileError, 'smart_profile_error'),
      ],
    );
  }

  static String _profileExplanation(SecurityProfile p) {
    final AppSecurityLevel? all = p.allProtectedLevel;
    final int apps = p.appLevels.length;
    if (all == null && apps == 0) return 'Adds no protection';
    if (all != null) return 'Every protected app at least ${all.label}';
    return apps == 1 ? '1 selected app' : '$apps selected apps';
  }

  String _whenText() {
    final String days =
        _days.isEmpty ? '—' : SmartRuleText.days(_days.toList());
    final String time = _allDay
        ? SmartRuleText.allDay
        : _start == _end
            ? '—'
            : SmartRuleText.time(
                SmartRuleTime.window(startMinute: _start, endMinute: _end),
              );
    return '$days · $time';
  }

  Widget _reviewSection(BuildContext context) {
    final List<ProtectedApp> apps = _apps ?? const <ProtectedApp>[];
    final Map<String, ProtectedApp> byPackage = <String, ProtectedApp>{
      for (final ProtectedApp a in apps) a.packageName: a,
    };
    final List<String> targets = _targets.toList()..sort();
    final SmartRuleAction? action = _action;
    final List<String> labels = <String>[
      for (final String pkg in targets) byPackage[pkg]?.label ?? pkg,
    ];
    final List<String> notes = <String>[];
    final SecurityProfileSet? profileSet = _profileSet;
    final SecurityProfile? profile =
        _isProfile && _profileId != null ? profileSet?.byId(_profileId!) : null;
    if (_isProfile &&
        profile != null &&
        profile.allProtectedLevel == null &&
        profile.appLevels.isEmpty) {
      notes.add(SmartRuleText.profileNoEffect);
    }
    if (action != null && !_isProfile) {
      for (final String pkg in targets) {
        final ProtectedApp? app = byPackage[pkg];
        final AppSecurityLevel? baseline = app?.securityLevel;
        if (baseline == null) continue;
        final String? reason = SmartRuleText.noEffectReason(action, baseline);
        if (reason != null) notes.add('${app!.label}: $reason');
      }
    }
    final SmartRule? rule = _buildRule();
    final SmartRule? initial = widget.initial;
    // Phase 11 / M3: compared over the combined policy (profile rules
    // compile to their profile's overlay); the save path decides for real.
    final bool reduces = rule != null &&
        initial != null &&
        (profileSet == null
                ? SmartRulePolicy.relaxedPackages(
                    <SmartRule>[initial],
                    <SmartRule>[rule],
                  )
                : SecurityProfilePolicy.combinedRelaxedPackages(
                    rulesBefore: <SmartRule>[initial],
                    rulesAfter: <SmartRule>[rule],
                    profilesBefore: profileSet,
                    profilesAfter: profileSet,
                    protectedPackages:
                        apps.map((ProtectedApp a) => a.packageName).toSet(),
                  ))
            .isNotEmpty;
    final TextStyle? small = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _title(SmartRuleText.reviewTitle),
        DsCard(
          key: const Key('smart_review'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(_name.text.trim().isEmpty ? '—' : _name.text.trim()),
              const SizedBox(height: DsSpacing.xs),
              if (_isProfile)
                Text('Profile: ${profile?.name ?? '—'}')
              else
                Text('Apps: ${labels.isEmpty ? '—' : labels.join(', ')}'),
              Text('When: ${_whenText()}'),
              Text(
                _isProfile
                    ? 'Effect: ${profile == null ? '—' : SmartRuleText.profileSummary(profile.name)}'
                    : 'Level: ${action == null ? '—' : SmartRuleText.actionSummary(action)}',
              ),
              for (final String note in notes)
                Padding(
                  padding: const EdgeInsets.only(top: DsSpacing.xs),
                  child: Text(note, style: small),
                ),
              if (reduces)
                Padding(
                  padding: const EdgeInsets.only(top: DsSpacing.sm),
                  child: Text(
                    'Saving needs your PIN or pattern because this change '
                    'reduces rule protection.',
                    key: const Key('smart_review_reduces'),
                    style: small,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: DsSpacing.sm),
                child: Text(
                  'Rules use your phone\'s local time. A rule that starts '
                  'while an app is open applies the next time you open or '
                  'return to it.',
                  style: small,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// What the editor returns when it closes after a stored change.
class SmartRuleEditorResult {
  const SmartRuleEditorResult(this.outcome, {this.deleted = false});

  final SmartRuleChangeOutcome outcome;
  final bool deleted;
}
