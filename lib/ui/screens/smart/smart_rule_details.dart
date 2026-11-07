import 'package:flutter/material.dart';

import '../../../data/models/app_security_level.dart';
import '../../../data/models/protected_app.dart';
import '../../../design_system/design_system.dart';
import '../../../rules/smart_rule.dart';
import '../../../rules/smart_rule_diagnostics.dart';
import '../../../rules/smart_rule_evaluator.dart';
import 'smart_rule_presentation.dart';

/// Phase 10 / M3 (PRD 10K): user-facing wording of the rule details view.
abstract final class SmartRuleDetailsText {
  static const String title = 'Rule details';
  static const String showHint = 'Show why rules apply right now';
  static const String hideHint = 'Hide rule details';
  static const String refresh = 'Refresh';
  static const String calculatedNote =
      'Calculated from your saved rules. This is not a confirmation from '
      'protection.';
  static const String protectionLabel = 'Protection status';
  static const String nativeConfirmed =
      'Confirmed: protection is using these saved rules.';
  static const String nativeHeld =
      'Not confirmed: earlier, stricter rule settings still apply.';
  static const String nativeNotConfirmed =
      'Not confirmed: protection hasn\'t confirmed these saved rules.';
  static const String nativeNotReported =
      'Not checked yet: protection hasn\'t reported on your rules since the '
      'app started.';
  static const String engineNotLoaded =
      'Your Smart Rules haven\'t been read yet, so protected apps are treated '
      'as Critical for now.';
  static const String engineReadFailed =
      'Your Smart Rules couldn\'t be read, so protected apps are treated as '
      'Critical for now.';
  static const String engineBehind =
      'The app hasn\'t loaded your latest saved rules yet. Apps keep at least '
      'their saved security levels.';
  static const String noTargets = 'No rule selects an app.';
  static const String notProtected =
      'Not protected: Smart Rules have no effect on this app.';
  static const String decidedBySaved = 'Decided by: saved level';

  static String checkedAt(DateTime at) =>
      'Checked at ${SmartRuleText.minute(at.hour * 60 + at.minute)}, '
      '${SmartRuleText.dayLong(at.weekday)}';
  static String saved(AppSecurityLevel level) => 'Saved level: ${level.label}';
  static String calculated(AppSecurityLevel level) =>
      'Calculated level now: ${level.label}';
  static String decidedByRule(String name) => 'Decided by: $name';

  static String requested(SmartRuleAction action) => switch (action) {
        SmartRuleAction.critical => 'Critical',
        SmartRuleAction.sensitive => 'Sensitive',
        SmartRuleAction.standard => 'Standard',
        SmartRuleAction.unlocked => 'Unlocked (not available)',
      };

  /// Why a rule has (or has no) effect, for [d]'s app.
  static String role(
    SmartRuleDiagnosticEntry e,
    SmartRuleAppDiagnosis d,
    String Function(String ruleId) nameOf,
    SmartRuleTime time,
  ) =>
      switch (e.role) {
        SmartRuleRole.decides => 'applies now and decides the level',
        SmartRuleRole.tied =>
          'applies now, same level as ${nameOf(d.decidingRuleId ?? '')}',
        SmartRuleRole.outranked => 'applies now, but a stricter rule decides',
        SmartRuleRole.coveredBySaved =>
          'applies now, but the saved level is already '
              '${d.savedLevel?.label ?? ''}',
        SmartRuleRole.addsNothing => 'applies now, but adds no protection',
        SmartRuleRole.appNotProtected =>
          'applies now, but the app isn\'t protected',
        SmartRuleRole.notApplying => switch (e.reason) {
            SmartRuleReason.ruleDisabled => 'turned off',
            SmartRuleReason.outsideTimeWindow =>
              'not now: outside ${SmartRuleText.time(time)}',
            SmartRuleReason.dayNotSelected => 'not now: not scheduled for '
                '${SmartRuleText.dayLong(e.evaluation.ownerDay ?? 1)}',
            SmartRuleReason.appNotTargeted => 'doesn\'t select this app',
            SmartRuleReason.invalidAppPackage ||
            SmartRuleReason.nonLocalTime =>
              'can\'t be checked',
            SmartRuleReason.matched => 'applies now',
          },
      };

  static String native(SmartRuleNativeState s) => switch (s) {
        SmartRuleNativeState.confirmed => nativeConfirmed,
        SmartRuleNativeState.heldStricter => nativeHeld,
        SmartRuleNativeState.notConfirmed => nativeNotConfirmed,
        SmartRuleNativeState.notReported => nativeNotReported,
      };

  static String? engine(SmartRuleEngineState s) => switch (s) {
        SmartRuleEngineState.inUse => null,
        SmartRuleEngineState.notLoaded => engineNotLoaded,
        SmartRuleEngineState.readFailed => engineReadFailed,
        SmartRuleEngineState.behindSaved => engineBehind,
      };
}

/// Phase 10 / M3 (PRD 10K): the collapsed "Rule details" section of the
/// Smart tab. Read-only: it computes [SmartRuleDiagnostics] from the rules
/// the screen already read, at [clock] when opened or refreshed (no timer),
/// and shows native status only from [nativeState]. It never writes, never
/// talks to native and never touches authorization, challenges or grace.
class SmartRuleDetails extends StatefulWidget {
  const SmartRuleDetails({
    super.key,
    required this.rules,
    required this.apps,
    required this.engineState,
    required this.nativeState,
    this.clock,
  });

  /// The saved rules as read by the screen.
  final List<SmartRule> rules;

  /// Protected apps by package (saved levels).
  final Map<String, ProtectedApp> apps;
  final SmartRuleEngineState engineState;
  final SmartRuleNativeState nativeState;
  final DateTime Function()? clock;

  @override
  State<SmartRuleDetails> createState() => _SmartRuleDetailsState();
}

class _SmartRuleDetailsState extends State<SmartRuleDetails> {
  bool _open = false;
  DateTime? _at;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  void _toggle() => setState(() {
        _open = !_open;
        if (_open) _at = _now();
      });

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return DsCard(
      key: const Key('smart_rule_details'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(
            // Its own node: otherwise the button flags would attach to the
            // card's node and absorb every line of the details body.
            container: true,
            button: true,
            expanded: _open,
            onTapHint: _open
                ? SmartRuleDetailsText.hideHint
                : SmartRuleDetailsText.showHint,
            excludeSemantics: true,
            label: SmartRuleDetailsText.title,
            // The InkWell's own semantics are excluded, so the action is
            // declared here for screen readers.
            onTap: _toggle,
            child: InkWell(
              key: const Key('smart_rule_details_toggle'),
              onTap: _toggle,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        SmartRuleDetailsText.title,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    Icon(_open ? Icons.expand_less : Icons.expand_more),
                  ],
                ),
              ),
            ),
          ),
          if (_open) ..._body(context),
        ],
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? secondary = theme.textTheme.bodySmall?.copyWith(
      color: context.dsColors.textSecondary,
    );
    final DateTime at = _at ?? _now();
    final Map<String, SmartRule> byId = <String, SmartRule>{
      for (final SmartRule r in widget.rules) r.id: r,
    };
    String nameOf(String id) => byId[id]?.name ?? id;
    final List<String> packages = <String>{
      for (final SmartRule r in widget.rules) ...r.targetPackages,
    }.toList()
      ..sort((String a, String b) {
        final String la = widget.apps[a]?.label ?? a;
        final String lb = widget.apps[b]?.label ?? b;
        final int byLabel = la.toLowerCase().compareTo(lb.toLowerCase());
        return byLabel != 0 ? byLabel : a.compareTo(b);
      });
    final String? engine = SmartRuleDetailsText.engine(widget.engineState);
    return <Widget>[
      Container(
        key: const Key('smart_rule_details_body'),
        padding: const EdgeInsets.only(top: DsSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              SmartRuleDetailsText.checkedAt(at),
              key: const Key('smart_rule_details_checked'),
              style: secondary,
            ),
            Text(SmartRuleDetailsText.calculatedNote, style: secondary),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: const Key('smart_rule_details_refresh'),
                onPressed: () => setState(() => _at = _now()),
                child: const Text(SmartRuleDetailsText.refresh),
              ),
            ),
            Text(
              SmartRuleDetailsText.protectionLabel,
              style: theme.textTheme.labelLarge,
            ),
            Text(
              SmartRuleDetailsText.native(widget.nativeState),
              key: Key('smart_rule_details_native_${widget.nativeState.name}'),
            ),
            if (engine != null) ...<Widget>[
              const SizedBox(height: DsSpacing.xs),
              Text(
                engine,
                key: Key(
                  'smart_rule_details_engine_${widget.engineState.name}',
                ),
              ),
            ],
            const SizedBox(height: DsSpacing.sm),
            if (packages.isEmpty) const Text(SmartRuleDetailsText.noTargets),
            for (final String pkg in packages)
              _appBlock(context, pkg, at, nameOf, byId, secondary),
          ],
        ),
      ),
    ];
  }

  Widget _appBlock(
    BuildContext context,
    String pkg,
    DateTime at,
    String Function(String) nameOf,
    Map<String, SmartRule> byId,
    TextStyle? secondary,
  ) {
    final ProtectedApp? app = widget.apps[pkg];
    final SmartRuleAppDiagnosis d = SmartRuleDiagnostics.diagnose(
      rules: widget.rules,
      packageName: pkg,
      savedLevel: app?.securityLevel,
      at: at,
      engineState: widget.engineState,
      nativeState: widget.nativeState,
    );
    final List<SmartRuleDiagnosticEntry> shown = <SmartRuleDiagnosticEntry>[
      for (final SmartRuleDiagnosticEntry e in d.entries)
        if (e.appMatch == true) e,
    ];
    final AppSecurityLevel? saved = d.savedLevel;
    final AppSecurityLevel? calculated = d.calculatedLevel;
    return Padding(
      key: Key('smart_rule_details_app_$pkg'),
      padding: const EdgeInsets.only(top: DsSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Divider(height: DsSpacing.md),
          Text(
            app?.label ?? pkg,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          if (saved == null || calculated == null)
            const Text(SmartRuleDetailsText.notProtected)
          else ...<Widget>[
            Text(SmartRuleDetailsText.saved(saved)),
            Text(
              SmartRuleDetailsText.calculated(calculated),
              key: Key('smart_rule_details_level_$pkg'),
            ),
            Text(
              d.decidingRuleId == null
                  ? SmartRuleDetailsText.decidedBySaved
                  : SmartRuleDetailsText.decidedByRule(
                      nameOf(d.decidingRuleId!),
                    ),
              key: Key('smart_rule_details_decided_$pkg'),
            ),
          ],
          for (final SmartRuleDiagnosticEntry e in shown)
            Padding(
              padding: const EdgeInsets.only(top: DsSpacing.xxs),
              child: Text(
                '${e.name} · ${SmartRuleDetailsText.requested(e.requested)}: '
                '${SmartRuleDetailsText.role(e, d, nameOf, byId[e.ruleId]!.time)}',
                key: Key('smart_rule_details_entry_${pkg}_${e.ruleId}'),
                style: e.contributed ? null : secondary,
              ),
            ),
        ],
      ),
    );
  }
}
