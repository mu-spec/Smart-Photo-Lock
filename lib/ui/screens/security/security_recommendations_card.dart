import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../health/health_presentation.dart';
import 'security_center_recommendations.dart';

/// Phase 9 / M3 — "Recommended improvements" in the Security Center.
///
/// Renders a [RecommendationsAssessment] only. Every button opens an
/// existing screen or control, runs the existing health refresh, or (for
/// optional items) records "Don't suggest again" in the existing
/// preference. Nothing here changes a level, protects an app, changes a
/// setting, authorizes or unlocks.
class SecurityRecommendationsCard extends StatelessWidget {
  const SecurityRecommendationsCard({
    super.key,
    required this.assessment,
    this.onAction,
    this.onDismiss,
    this.onRetry,
    this.onCheckAgain,
  });

  final RecommendationsAssessment assessment;
  final ValueChanged<SecurityCenterRecommendation>? onAction;
  final ValueChanged<SecurityCenterRecommendation>? onDismiss;

  /// Re-reads apps, settings and dismissals.
  final VoidCallback? onRetry;

  /// Runs the Phase 7 health refresh.
  final VoidCallback? onCheckAgain;

  static const String heading = 'RECOMMENDED IMPROVEMENTS';
  static const String description =
      'Suggestions based on the last protection check and your saved '
      'settings. Nothing changes unless you choose it.';
  static const String assessingTitle = 'Checking for improvements…';
  static const String unavailableTitle = 'Recommendations unavailable';
  static String unavailableMessage(RecommendationsUnavailableReason r) =>
      switch (r) {
        RecommendationsUnavailableReason.appsUnreadable =>
          'The saved list of protected apps could not be read, so nothing is '
              'suggested. This does not mean there is nothing to improve.',
        RecommendationsUnavailableReason.settingsUnreadable =>
          'The re-lock setting could not be read, so nothing is suggested.',
        RecommendationsUnavailableReason.healthFailed =>
          'Protection could not be checked, so nothing is suggested.',
        RecommendationsUnavailableReason.healthNotChecked =>
          'Protection has not been checked yet.',
      };
  static const String allClearTitle = 'Nothing to suggest right now';
  static const String allClearMessage =
      'Every check Smart App Lock can run passed on the last check, and '
      'there are no suggested changes for your apps or re-lock setting. Some '
      'phone controls, such as manufacturer battery managers, cannot be '
      'checked.';
  static const String optionalUnavailableMessage =
      'Optional suggestions could not be loaded.';
  static const String setupTag = 'Setup';
  static const String optionalTag = 'Optional';
  static const String retryLabel = 'Try again';
  static const String checkAgainLabel = 'Check again';
  static const String dismissLabel = "Don't suggest again";

  /// Shown only after the dismissal was saved.
  static const String dismissedMessage =
      'Suggestion hidden. No level or setting was changed.';

  static String actionLabel(SecurityCenterRecommendation r) =>
      switch (r.action) {
        RecommendationAction.openHealthDetails => 'Review in Health Details',
        RecommendationAction.checkAgain => checkAgainLabel,
        RecommendationAction.openApps => r.kind == RecommendationKind.setupApps
            ? 'Choose apps'
            : 'Review in Apps',
        RecommendationAction.showAuthentication => 'Show PIN and pattern',
        RecommendationAction.showRelock => 'Show Grace period',
      };

  static String levelLine(LevelSuggestion s) =>
      '${s.label}: ${s.current.label} → ${s.suggested.label}';
  static String levelSemantics(LevelSuggestion s) =>
      '${s.label}: now ${s.current.label}, suggested ${s.suggested.label}. '
      '${s.reason}';
  static String relockLine(RelockSuggestion s) =>
      'Now: ${SecurityCenterRecommendations.durationLabel(s.current)} · '
      'Suggested: ${SecurityCenterRecommendations.durationLabel(s.suggested)}';

  static String tagFor(SecurityCenterRecommendation r) =>
      r.categoryLabel ??
      (r.priority == RecommendationPriority.setup ? setupTag : optionalTag);

  static DsTone toneFor(SecurityCenterRecommendation r) {
    final issue = r.healthIssue;
    if (issue != null) return HealthPresentation.issue(issue).tone;
    return r.priority == RecommendationPriority.setup
        ? DsTone.info
        : DsTone.neutral;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    final TextStyle? secondary =
        theme.textTheme.bodySmall?.copyWith(color: palette.textSecondary);
    final RecommendationsAssessment a = assessment;

    final List<Widget> body = <Widget>[];
    switch (a.status) {
      case RecommendationsStatus.assessing:
        body.add(_Title(
          key: const Key('sc_rec_assessing'),
          text: assessingTitle,
        ));
      case RecommendationsStatus.unavailable:
        final RecommendationsUnavailableReason reason = a.reason!;
        final bool reread =
            reason == RecommendationsUnavailableReason.appsUnreadable ||
                reason == RecommendationsUnavailableReason.settingsUnreadable;
        final VoidCallback? retry = reread ? onRetry : onCheckAgain;
        body.add(Column(
          key: const Key('sc_rec_unavailable'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const _Title(text: unavailableTitle),
            const SizedBox(height: DsSpacing.xs),
            Text(unavailableMessage(reason), style: secondary),
            if (retry != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: Key(reread ? 'sc_rec_retry' : 'sc_rec_check'),
                  onPressed: retry,
                  child: Text(reread ? retryLabel : checkAgainLabel),
                ),
              ),
          ],
        ));
      case RecommendationsStatus.ready:
        if (a.allClear) {
          body.add(Column(
            key: const Key('sc_rec_all_clear'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const _Title(text: allClearTitle),
              const SizedBox(height: DsSpacing.xs),
              Text(allClearMessage, style: secondary),
            ],
          ));
        }
        for (int i = 0; i < a.items.length; i++) {
          if (i > 0) body.add(const Divider(height: DsSpacing.lg));
          body.add(_Item(
            recommendation: a.items[i],
            onAction: onAction,
            onDismiss: onDismiss,
          ));
        }
        if (a.optionalUnavailable) {
          body.add(Row(
            key: const Key('sc_rec_optional_unavailable'),
            children: <Widget>[
              Expanded(
                  child: Text(optionalUnavailableMessage, style: secondary)),
              if (onRetry != null)
                TextButton(
                  key: const Key('sc_rec_retry'),
                  onPressed: onRetry,
                  child: const Text(retryLabel),
                ),
            ],
          ));
        }
    }

    return Semantics(
      container: true,
      child: DsCard(
        key: const Key('security_center_recommendations'),
        margin: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Semantics(
              header: true,
              container: true,
              child: Text(
                heading,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: palette.textSecondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: DsSpacing.xs),
            Text(description, style: secondary),
            const SizedBox(height: DsSpacing.md),
            ...body,
          ],
        ),
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
      );
}

class _Item extends StatelessWidget {
  const _Item({
    required this.recommendation,
    required this.onAction,
    required this.onDismiss,
  });

  final SecurityCenterRecommendation recommendation;
  final ValueChanged<SecurityCenterRecommendation>? onAction;
  final ValueChanged<SecurityCenterRecommendation>? onDismiss;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    final TextStyle? secondary =
        theme.textTheme.bodySmall?.copyWith(color: palette.textSecondary);
    final SecurityCenterRecommendation r = recommendation;
    final RelockSuggestion? relock = r.relock;
    return Semantics(
      container: true,
      child: Column(
        key: Key('sc_rec_${r.id}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _Tag(
            label: SecurityRecommendationsCard.tagFor(r),
            tone: SecurityRecommendationsCard.toneFor(r),
          ),
          const SizedBox(height: DsSpacing.xs),
          Text(
            r.title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: DsSpacing.xs),
          Text(r.reason, style: secondary),
          for (final LevelSuggestion s in r.levels)
            Padding(
              padding: const EdgeInsets.only(top: DsSpacing.xs),
              child: Semantics(
                container: true,
                label: SecurityRecommendationsCard.levelSemantics(s),
                excludeSemantics: true,
                child: Column(
                  key: Key('sc_rec_level_${s.packageName}'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      SecurityRecommendationsCard.levelLine(s),
                      style: theme.textTheme.bodyMedium,
                    ),
                    Text(s.reason, style: secondary),
                  ],
                ),
              ),
            ),
          if (relock != null)
            Padding(
              padding: const EdgeInsets.only(top: DsSpacing.xs),
              child: Text(
                SecurityRecommendationsCard.relockLine(relock),
                key: const Key('sc_rec_relock_values'),
                style: theme.textTheme.bodyMedium,
              ),
            ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: DsSpacing.sm,
            children: <Widget>[
              if (r.dismissible)
                TextButton(
                  key: Key('sc_rec_dismiss_${r.id}'),
                  onPressed: onDismiss == null ? null : () => onDismiss!(r),
                  child: const Text(SecurityRecommendationsCard.dismissLabel),
                ),
              TextButton(
                key: Key('sc_rec_action_${r.id}'),
                onPressed: onAction == null ? null : () => onAction!(r),
                child: Text(SecurityRecommendationsCard.actionLabel(r)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.tone});

  final String label;
  final DsTone tone;

  @override
  Widget build(BuildContext context) {
    final Color color = tone.colorOf(context.dsColors);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(DsRadii.pill),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
