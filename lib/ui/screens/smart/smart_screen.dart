import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../data/models/protected_app.dart';
import '../../../data/repositories/smart_rule_repository.dart';
import '../../../design_system/design_system.dart';
import '../../../rules/smart_rule.dart';
import '../../../rules/smart_rule_diagnostics.dart';
import '../../../services/watcher_service.dart';
import '../../../utilities/result.dart';
import 'smart_rule_change.dart';
import 'smart_rule_details.dart';
import 'smart_rule_editor_screen.dart';
import 'smart_rule_presentation.dart';
import 'smart_wide_button.dart';

/// Smart tab (Phase 10 / M2, PRD 10G–10I): the Smart Rules list.
///
/// Shows each saved rule (enabled state, apps, days, time, requested
/// level) with loading, empty, error, corrupt and newer-version states,
/// and "Create Smart Rule". Rules are read only while the tab is visible
/// (never at startup by this screen); a failed read never shows an empty
/// list, and an unreadable document is never offered for editing.
///
/// The enable switch shows the STORED state: a change goes through
/// [applySmartRuleChange] and the list re-reads storage afterwards, so a
/// failed save leaves the switch where it was. Nothing here claims that a
/// rule is active right now; the only enforcement statements are native
/// acknowledgements.
///
/// Phase 10 / M3 (PRD 10K): a collapsed, read-only "Rule details" section
/// under the list ([SmartRuleDetails]) explains which rules apply now, which
/// one decides each app's calculated level, and separately whether
/// protection confirmed the saved rules.
class SmartScreen extends StatefulWidget {
  const SmartScreen({
    super.key,
    this.isActive = true,
    this.pickTime,
    this.clock,
  });

  /// The tab's description line (shown under the heading).
  static const String description = SmartRuleText.intro;

  /// Whether the Smart tab is visible (rules load on activation).
  final bool isActive;

  /// Test seam forwarded to the editor.
  final Future<TimeOfDay?> Function(BuildContext context, TimeOfDay initial)?
      pickTime;

  /// Test seam forwarded to the change flow.
  final DateTime Function()? clock;

  @override
  State<SmartScreen> createState() => _SmartScreenState();
}

class _SmartScreenState extends State<SmartScreen> {
  List<SmartRule>? _rules;
  Object? _error;
  bool _loading = false;
  Map<String, ProtectedApp> _apps = const <String, ProtectedApp>{};
  final Set<String> _busy = <String>{};
  bool _confirmingHeld = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started && widget.isActive) {
      _started = true;
      _load();
    }
  }

  @override
  void didUpdateWidget(SmartScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _started = true;
      _load();
    }
  }

  Future<void> _load() async {
    final container = AppScope.read(context);
    if (_loading) return;
    if (container == null) {
      // No persistence wired (pure widget tests): an error state, never an
      // endless spinner or an empty list. Called before a build follows.
      _rules = null;
      _error ??= StateError('Smart Rules are unavailable.');
      return;
    }
    setState(() => _loading = true);
    final Result<List<SmartRule>> rules = await container.smartRules.getRules();
    final Result<List<ProtectedApp>> apps =
        await container.protectedApps.getProtectedApps();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (rules.isFailure || rules.valueOrNull == null) {
        _rules = null;
        _error = rules.errorOrNull ?? StateError('No rules read.');
      } else {
        _rules = rules.valueOrNull;
        _error = null;
      }
      _apps = <String, ProtectedApp>{
        for (final ProtectedApp a in apps.valueOrNull ?? const <ProtectedApp>[])
          a.packageName: a,
      };
    });
  }

  void _show(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openEditor([SmartRule? rule]) async {
    if (_rules == null || _loading) return;
    final SmartRuleEditorResult? result =
        await Navigator.of(context).push<SmartRuleEditorResult>(
      MaterialPageRoute<SmartRuleEditorResult>(
        settings: const RouteSettings(name: SmartRuleEditorScreen.routeName),
        builder: (BuildContext _) => SmartRuleEditorScreen(
          initial: rule,
          pickTime: widget.pickTime,
          clock: widget.clock,
        ),
      ),
    );
    if (!mounted) return;
    await _load();
    if (!mounted || result == null) return;
    _show(SmartRuleText.outcome(result.outcome, deleting: result.deleted));
  }

  Future<void> _toggle(SmartRule rule, bool enabled) async {
    final container = AppScope.read(context);
    if (container == null || _busy.contains(rule.id)) return;
    final NavigatorState navigator = Navigator.of(context);
    setState(() => _busy.add(rule.id));
    final SmartRuleChangeOutcome outcome = await applySmartRuleChange(
      change: SmartRuleToggle(rule: rule, enabled: enabled),
      navigator: navigator,
      repository: container.smartRules,
      credentials: container.auth,
      accessController: container.accessController,
      bootstrap: container.protectionBootstrap,
      clock: widget.clock,
    );
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    setState(() => _busy.remove(rule.id));
    _show(SmartRuleText.outcome(outcome));
  }

  Future<void> _confirmHeld() async {
    final container = AppScope.read(context);
    if (container == null || _confirmingHeld) return;
    final NavigatorState navigator = Navigator.of(context);
    setState(() => _confirmingHeld = true);
    final Result<List<ProtectedApp>> apps =
        await container.protectedApps.getProtectedApps();
    final SmartRuleChangeOutcome outcome = apps.valueOrNull == null
        ? const SmartRuleChangeOutcome(SmartRuleChangeStatus.failed)
        : await confirmHeldRuleRelaxation(
            navigator: navigator,
            credentials: container.auth,
            bootstrap: container.protectionBootstrap,
            packages: <String>{
              for (final ProtectedApp a in apps.valueOrNull!) a.packageName,
            },
            clock: widget.clock,
          );
    if (!mounted) return;
    setState(() => _confirmingHeld = false);
    _show(switch (outcome.status) {
      SmartRuleChangeStatus.enforced => SmartRuleText.heldConfirmed,
      SmartRuleChangeStatus.denied => SmartRuleText.denied(outcome.denial),
      // Only after native durably re-held the stricter rules.
      SmartRuleChangeStatus.savedHeld => SmartRuleText.heldNotConfirmed,
      _ => SmartRuleText.heldUnknown,
    });
  }

  bool get _held =>
      AppScope.read(context)?.protectionBootstrap.lastPolicyAck?.ruleStatus ==
      SmartRuleSyncStatus.held;

  @override
  Widget build(BuildContext context) {
    final List<SmartRule>? rules = _rules;
    final bool canCreate = rules != null && !_loading;
    return ListView(
      key: const Key('smart_rules_list'),
      padding: DsInsets.screen,
      children: <Widget>[
        Semantics(
          header: true,
          child: Text(
            SmartRuleText.heading,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
        const SizedBox(height: DsSpacing.xs),
        Text(
          SmartScreen.description,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.dsColors.textSecondary,
              ),
        ),
        const SizedBox(height: DsSpacing.lg),
        if (_held) ...<Widget>[
          _heldNotice(context),
          const SizedBox(height: DsSpacing.lg)
        ],
        SmartWideButton(
          key: const Key('smart_create'),
          label: SmartRuleText.create,
          icon: Icons.add,
          onPressed: canCreate ? () => _openEditor() : null,
        ),
        const SizedBox(height: DsSpacing.lg),
        ..._body(context),
      ],
    );
  }

  List<Widget> _body(BuildContext context) {
    final List<SmartRule>? rules = _rules;
    if (rules == null && !_loading && _error == null) {
      // Not loaded yet (the tab was never shown): nothing is in progress,
      // so no spinner (an offstage indeterminate animation never settles).
      return const <Widget>[];
    }
    if (rules == null && _loading) {
      return <Widget>[
        const Padding(
          padding: EdgeInsets.all(DsSpacing.xl),
          child: Center(
            child: CircularProgressIndicator(
              semanticsLabel: SmartRuleText.loading,
            ),
          ),
        ),
      ];
    }
    if (rules == null) {
      final Object? error = _error;
      final SmartRuleStoreErrorKind? kind =
          error is SmartRuleStoreException ? error.kind : null;
      return <Widget>[
        DsCard(
          key: Key('smart_rules_error_${kind?.name ?? 'unknown'}'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(switch (kind) {
                SmartRuleStoreErrorKind.corrupt => SmartRuleText.corrupt,
                SmartRuleStoreErrorKind.unsupportedVersion =>
                  SmartRuleText.unsupported,
                _ => SmartRuleText.loadFailed,
              }),
              if (_engineNoteWithoutRules() case final String note)
                Padding(
                  padding: const EdgeInsets.only(top: DsSpacing.xs),
                  child: Text(note, key: const Key('smart_rules_engine_note')),
                ),
              const SizedBox(height: DsSpacing.sm),
              TextButton(
                key: const Key('smart_rules_retry'),
                onPressed: _loading ? null : _load,
                child: const Text(SmartRuleText.retry),
              ),
            ],
          ),
        ),
      ];
    }
    if (rules.isEmpty) {
      return <Widget>[
        DsCard(
          key: const Key('smart_rules_empty'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                SmartRuleText.emptyTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: DsSpacing.xs),
              const Text(SmartRuleText.emptyBody),
            ],
          ),
        ),
      ];
    }
    final container = AppScope.read(context);
    return <Widget>[
      for (final SmartRule rule in rules) ...<Widget>[
        _ruleCard(context, rule),
        const SizedBox(height: DsSpacing.md),
      ],
      if (container != null)
        SmartRuleDetails(
          rules: rules,
          apps: _apps,
          clock: widget.clock,
          engineState: SmartRuleDiagnostics.engineStateFor(
            container.protectionBootstrap.ruleCache,
            rules,
          ),
          nativeState: SmartRuleDiagnostics.nativeStateFor(
            rules,
            container.protectionBootstrap.lastRuleExchange,
          ),
        ),
    ];
  }

  /// Phase 10 / M3: the engine note shown with a read error (only when the
  /// Dart engine is itself without current rules).
  String? _engineNoteWithoutRules() {
    final container = AppScope.read(context);
    if (container == null) return null;
    return SmartRuleDetailsText.engine(
      SmartRuleDiagnostics.engineStateWithoutSaved(
        container.protectionBootstrap.ruleCache,
      ),
    );
  }

  Widget _heldNotice(BuildContext context) => DsCard(
        key: const Key('smart_rules_held'),
        color: context.dsColors.warning.withValues(alpha: 0.10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(SmartRuleText.heldNotice),
            const SizedBox(height: DsSpacing.sm),
            TextButton(
              key: const Key('smart_rules_held_confirm'),
              onPressed: _confirmingHeld ? null : _confirmHeld,
              child: const Text(SmartRuleText.heldConfirm),
            ),
          ],
        ),
      );

  Widget _ruleCard(BuildContext context, SmartRule rule) {
    final String apps =
        rule.targetPackages.map((String p) => _apps[p]?.label ?? p).join(', ');
    final bool busy = _busy.contains(rule.id);
    final TextStyle? secondary =
        Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.dsColors.textSecondary,
            );
    return DsCard(
      key: Key('smart_rule_${rule.id}'),
      onTap: busy ? null : () => _openEditor(rule),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  rule.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: DsSpacing.xxs),
                Text(apps, style: secondary),
                Text(
                  '${SmartRuleText.days(rule.days)} · '
                  '${SmartRuleText.time(rule.time)}',
                  style: secondary,
                ),
                Text(SmartRuleText.actionSummary(rule.action),
                    style: secondary),
                const SizedBox(height: DsSpacing.xs),
                DsStatusPill(
                  label: rule.enabled ? 'On' : 'Off',
                  tone: rule.enabled ? DsTone.info : DsTone.neutral,
                ),
              ],
            ),
          ),
          Semantics(
            label: '${rule.enabled ? 'Turn off' : 'Turn on'} ${rule.name}',
            child: Switch(
              key: Key('smart_toggle_${rule.id}'),
              value: rule.enabled,
              onChanged: busy ? null : (bool v) => _toggle(rule, v),
            ),
          ),
        ],
      ),
    );
  }
}
