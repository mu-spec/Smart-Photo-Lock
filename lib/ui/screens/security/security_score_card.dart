import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import 'security_score.dart';

/// Phase 9 / M2 (PRD 9F) — the Security Score section of the Security
/// Center.
///
/// Renders one [SecurityScoreAssessment] exactly. A number is shown only
/// for `available` and `provisional`; every other status shows its reason
/// and no number (never 0, never a default 100). There is deliberately no
/// ring or progress bar, and the number always uses the normal text colour
/// (never a reassuring green); a provisional number carries a warning-toned
/// "Provisional" tag and the remaining problems. Read-only: the buttons only open existing flows
/// (Health Details, Apps tab) or ask the Security Center to read again.
class SecurityScoreCard extends StatefulWidget {
  const SecurityScoreCard({
    super.key,
    required this.assessment,
    this.onOpenDetails,
    this.onCheckAgain,
    this.onRetry,
    this.onManageApps,
  });

  final SecurityScoreAssessment assessment;

  /// Opens Health Details (Fix protection).
  final VoidCallback? onOpenDetails;

  /// Runs a new Protection Health check.
  final VoidCallback? onCheckAgain;

  /// Re-reads the saved apps and the re-lock setting.
  final VoidCallback? onRetry;

  /// Opens the Apps tab.
  final VoidCallback? onManageApps;

  static const String heading = 'Security score';
  static const String description =
      'An assessment of your current protection setup, not a guarantee '
      'against bypasses.';
  static const String outOf = '/ 100 points';
  static const String provisionalTag = 'Provisional';
  static const String provisionalMessage =
      'Problems remain, so the health points are not counted until a check '
      'passes.';
  static const String availableMessage =
      'Based on the last health check, which passed.';
  static const String maxedMessage =
      'Every factor in this assessment is at its maximum. Protection can '
      'still be limited by things Smart App Lock cannot check.';

  static const String assessingTitle = 'Assessing your setup…';
  static const String unavailableTitle = 'Score unavailable';
  static String unavailableMessage(ScoreUnavailableReason r) => switch (r) {
        ScoreUnavailableReason.appsUnreadable =>
          'The saved app list could not be read, so no score is shown.',
        ScoreUnavailableReason.settingsUnreadable =>
          'Your re-lock setting could not be read, so no score is shown.',
        ScoreUnavailableReason.healthFailed =>
          'Protection could not be checked, so no score is shown.',
        ScoreUnavailableReason.healthNotChecked =>
          'Protection has not been checked yet, so no score is shown.',
        ScoreUnavailableReason.healthStale =>
          'The last protection check is out of date, so no score is shown. '
              'Check again for a current assessment.',
      };
  static const String withheldTitle = 'No score while protection is offline';
  static const String withheldMessage =
      'A score would be misleading while protection is offline. Restore '
      'protection to get an assessment.';
  static const String setupTitle = 'No score until setup is finished';
  static const String setupCredentialStep = 'Create an unlock PIN or pattern.';
  static const String setupAppsStep = 'Choose at least one app to protect.';
  static const String setupGeneric =
      'Finish setting up protection to get an assessment.';

  static const String healthFactor = 'Protection health';
  static const String relockFactor = 'Re-lock after leaving';
  static String factorValue(int earned, int max) => '$earned of $max';
  static const String healthPassed = 'The last health check passed.';

  /// The problem itself is named once, in the Protection Health card above
  /// (one wording source, no duplicate issue text).
  static const String healthProblem =
      'Needs attention: see Protection health above.';

  static String tierLine(RelockTier tier, int n) {
    final String apps = n == 1 ? '1 app' : '$n apps';
    final String verb = n == 1 ? 'stays' : 'stay';
    return switch (tier) {
      RelockTier.noDelay => n == 1
          ? '1 app re-locks with no delay'
          : '$n apps re-lock with no '
              'delay',
      RelockTier.upTo15Seconds =>
        '$apps $verb unlocked up to 15 seconds after you leave',
      RelockTier.upTo1Minute =>
        '$apps $verb unlocked up to 1 minute after you leave',
      RelockTier.upTo5Minutes =>
        '$apps $verb unlocked up to 5 minutes after you leave',
      RelockTier.longer =>
        '$apps $verb unlocked more than 5 minutes after you leave',
    };
  }

  static const String lowersHeading = 'What lowers the score';
  static String lowersHealth(int points) =>
      'Protection needs attention (−$points points).';
  static String lowersRelock(int points) =>
      'Apps that stay unlocked for a while after you leave them '
      '(−$points points).';
  static String unconfirmedNote(int n) => n == 1
      ? '1 app level is not confirmed by protection yet, so it counts with '
          'your general re-lock setting.'
      : '$n app levels are not confirmed by protection yet, so they count '
          'with your general re-lock setting.';
  static String heldNote(int n) => n == 1
      ? '1 app still re-locks at a stricter level until its lower level is '
          'confirmed. The score counts the lower level.'
      : '$n apps still re-lock at a stricter level until their lower levels '
          'are confirmed. The score counts the lower levels.';

  static const String howLabel = 'How the score works';
  static const String hideHowLabel = 'Hide details';
  static const List<String> howLines = <String>[
    'Protection health: 60 points when the last health check passed and '
        'is current, 0 points while something needs attention. No score '
        'while protection is offline or the check is out of date.',
    'Re-lock after leaving: up to 40 points, averaged over your protected '
        'apps. Per app: no delay 40, up to 15 seconds 30, up to 1 minute 20, '
        'up to 5 minutes 10. A level counts only after protection confirms '
        'it.',
    'Not counted: how many apps you protect, PIN or pattern, fingerprint '
        'or face unlock, and your phone model.',
    'These weights are Smart App Lock\'s own product choices. They are not '
        'measured odds of stopping someone.',
    'The score cannot measure resistance to bypass attempts, and it cannot '
        'see manufacturer battery managers or anything Android does not '
        'report.',
  ];

  static const String fixLabel = 'Fix protection';
  static const String checkAgainLabel = 'Check again';
  static const String retryLabel = 'Try again';
  static const String chooseAppsLabel = 'Choose apps';

  /// The screen-reader summary of the score or its status.
  static String semanticsSummary(SecurityScoreAssessment a) =>
      switch (a.status) {
        SecurityScoreStatus.available =>
          'Security score: ${a.points} out of 100 points.',
        SecurityScoreStatus.provisional =>
          'Provisional security score: ${a.points} out of 100 points. '
              'Problems remain.',
        SecurityScoreStatus.assessing => 'Security score: assessing.',
        SecurityScoreStatus.unavailable => 'Security score unavailable. '
            '${unavailableMessage(a.reason!)}',
        SecurityScoreStatus.withheldOffline =>
          'Security score: $withheldTitle.',
        SecurityScoreStatus.setupNeeded => 'Security score: $setupTitle.',
      };

  @override
  State<SecurityScoreCard> createState() => _SecurityScoreCardState();
}

class _SecurityScoreCardState extends State<SecurityScoreCard> {
  bool _showHow = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    final SecurityScoreAssessment a = widget.assessment;
    final TextStyle? secondary =
        theme.textTheme.bodySmall?.copyWith(color: palette.textSecondary);

    final List<Widget> body = <Widget>[];
    final List<Widget> actions = <Widget>[];
    switch (a.status) {
      case SecurityScoreStatus.assessing:
        body.add(_StatusText(
          key: const Key('sc_score_assessing'),
          title: SecurityScoreCard.assessingTitle,
        ));
      case SecurityScoreStatus.unavailable:
        final ScoreUnavailableReason reason = a.reason!;
        body.add(_StatusText(
          key: const Key('sc_score_unavailable'),
          title: SecurityScoreCard.unavailableTitle,
          message: SecurityScoreCard.unavailableMessage(reason),
        ));
        final bool reread = reason == ScoreUnavailableReason.appsUnreadable ||
            reason == ScoreUnavailableReason.settingsUnreadable;
        if (reread && widget.onRetry != null) {
          actions.add(TextButton(
            key: const Key('sc_score_retry'),
            onPressed: widget.onRetry,
            child: const Text(SecurityScoreCard.retryLabel),
          ));
        } else if (!reread && widget.onCheckAgain != null) {
          actions.add(TextButton(
            key: const Key('sc_score_check'),
            onPressed: widget.onCheckAgain,
            child: const Text(SecurityScoreCard.checkAgainLabel),
          ));
        }
      case SecurityScoreStatus.withheldOffline:
        body.add(_StatusText(
          key: const Key('sc_score_withheld'),
          title: SecurityScoreCard.withheldTitle,
          message: SecurityScoreCard.withheldMessage,
        ));
        if (widget.onOpenDetails != null) {
          actions.add(TextButton(
            key: const Key('sc_score_fix'),
            onPressed: widget.onOpenDetails,
            child: const Text(SecurityScoreCard.fixLabel),
          ));
        }
      case SecurityScoreStatus.setupNeeded:
        final List<String> steps = <String>[
          if (a.needsCredential ?? false) SecurityScoreCard.setupCredentialStep,
          if (a.needsApps) SecurityScoreCard.setupAppsStep,
        ];
        body.add(_StatusText(
          key: const Key('sc_score_setup'),
          title: SecurityScoreCard.setupTitle,
          message:
              steps.isEmpty ? SecurityScoreCard.setupGeneric : steps.join(' '),
        ));
        if (a.needsApps && widget.onManageApps != null) {
          actions.add(TextButton(
            key: const Key('sc_score_choose_apps'),
            onPressed: widget.onManageApps,
            child: const Text(SecurityScoreCard.chooseAppsLabel),
          ));
        }
      case SecurityScoreStatus.provisional:
      case SecurityScoreStatus.available:
        body.addAll(_scored(context, a));
        if (a.status == SecurityScoreStatus.provisional &&
            widget.onOpenDetails != null) {
          actions.add(TextButton(
            key: const Key('sc_score_fix'),
            onPressed: widget.onOpenDetails,
            child: const Text(SecurityScoreCard.fixLabel),
          ));
        }
    }

    return Semantics(
      container: true,
      child: DsCard(
        key: const Key('security_center_score'),
        margin: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Semantics(
              header: true,
              container: true,
              child: Text(
                SecurityScoreCard.heading,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: palette.textSecondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: DsSpacing.xs),
            Text(
              SecurityScoreCard.description,
              key: const Key('sc_score_description'),
              style: secondary,
            ),
            const SizedBox(height: DsSpacing.md),
            ...body,
            if (_showHow) ...<Widget>[
              const SizedBox(height: DsSpacing.sm),
              Column(
                key: const Key('sc_score_how_details'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final String line in SecurityScoreCard.howLines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: DsSpacing.xs),
                      child: Text(line, style: secondary),
                    ),
                ],
              ),
            ],
            Wrap(
              alignment: WrapAlignment.end,
              spacing: DsSpacing.sm,
              children: <Widget>[
                ...actions,
                TextButton(
                  key: const Key('sc_score_how'),
                  onPressed: () => setState(() => _showHow = !_showHow),
                  child: Text(
                    _showHow
                        ? SecurityScoreCard.hideHowLabel
                        : SecurityScoreCard.howLabel,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _scored(BuildContext context, SecurityScoreAssessment a) {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    final bool provisional = a.status == SecurityScoreStatus.provisional;
    // Normal text colour in every state (readable contrast, never a
    // reassuring green); the Provisional tag carries the warning tone.
    final Color valueColor = palette.textPrimary;
    final TextStyle? secondary =
        theme.textTheme.bodySmall?.copyWith(color: palette.textSecondary);
    final int health = a.healthEarned!;
    final int relock = a.relockEarned!;
    final List<String> tierLines = <String>[
      for (final RelockTier t in RelockTier.values)
        if ((a.tierCounts[t] ?? 0) > 0)
          SecurityScoreCard.tierLine(t, a.tierCounts[t]!),
    ];
    final String healthDetail = provisional
        ? SecurityScoreCard.healthProblem
        : SecurityScoreCard.healthPassed;
    final int healthLost = SecurityScore.healthPoints - health;
    final int relockLost = SecurityScore.relockPoints - relock;
    return <Widget>[
      Semantics(
        container: true,
        label: SecurityScoreCard.semanticsSummary(a),
        excludeSemantics: true,
        child: Wrap(
          key: const Key('sc_score_value_row'),
          spacing: DsSpacing.sm,
          runSpacing: DsSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: <Widget>[
            Text(
              '${a.points}',
              key: const Key('sc_score_value'),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: valueColor,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(SecurityScoreCard.outOf, style: secondary),
            ),
            if (provisional)
              _ScoreTag(
                key: const Key('sc_score_provisional'),
                label: SecurityScoreCard.provisionalTag,
                tone: DsTone.warning,
              ),
          ],
        ),
      ),
      const SizedBox(height: DsSpacing.xs),
      Text(
        provisional
            ? SecurityScoreCard.provisionalMessage
            : a.points == SecurityScore.maxPoints
                ? SecurityScoreCard.maxedMessage
                : SecurityScoreCard.availableMessage,
        key: const Key('sc_score_message'),
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(height: DsSpacing.md),
      _FactorRow(
        key: const Key('sc_factor_health'),
        label: SecurityScoreCard.healthFactor,
        earned: health,
        max: SecurityScore.healthPoints,
        details: <String>[healthDetail],
      ),
      const SizedBox(height: DsSpacing.sm),
      _FactorRow(
        key: const Key('sc_factor_relock'),
        label: SecurityScoreCard.relockFactor,
        earned: relock,
        max: SecurityScore.relockPoints,
        details: tierLines,
      ),
      if (healthLost > 0 ||
          relockLost > 0 ||
          a.unconfirmedLevels > 0 ||
          a.heldStricter > 0) ...<Widget>[
        const SizedBox(height: DsSpacing.md),
        Column(
          key: const Key('sc_score_lowers'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (healthLost > 0 || relockLost > 0)
              Text(
                SecurityScoreCard.lowersHeading,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: palette.textSecondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            if (healthLost > 0)
              Text(
                SecurityScoreCard.lowersHealth(healthLost),
                key: const Key('sc_lowers_health'),
                style: theme.textTheme.bodySmall,
              ),
            if (relockLost > 0)
              Text(
                SecurityScoreCard.lowersRelock(relockLost),
                key: const Key('sc_lowers_relock'),
                style: theme.textTheme.bodySmall,
              ),
            if (a.unconfirmedLevels > 0)
              Text(
                SecurityScoreCard.unconfirmedNote(a.unconfirmedLevels),
                key: const Key('sc_score_unconfirmed'),
                style: secondary,
              ),
            if (a.heldStricter > 0)
              Text(
                SecurityScoreCard.heldNote(a.heldStricter),
                key: const Key('sc_score_held'),
                style: secondary,
              ),
          ],
        ),
      ],
    ];
  }
}

/// A title with an optional explanation (non-score statuses).
class _StatusText extends StatelessWidget {
  const _StatusText({super.key, required this.title, this.message});

  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        if (message != null) ...<Widget>[
          const SizedBox(height: DsSpacing.xs),
          Text(
            message!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: context.dsColors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

/// One factor: "Label  earned of max" plus its explanation lines, read as
/// one phrase by screen readers.
class _FactorRow extends StatelessWidget {
  const _FactorRow({
    super.key,
    required this.label,
    required this.earned,
    required this.max,
    required this.details,
  });

  final String label;
  final int earned;
  final int max;
  final List<String> details;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DsPalette palette = context.dsColors;
    final String value = SecurityScoreCard.factorValue(earned, max);
    return MergeSemantics(
      child: Semantics(
        label: '$label: $value points. ${details.join('. ')}',
        excludeSemantics: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: DsSpacing.sm,
              children: <Widget>[
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  value,
                  key: const Key('sc_factor_value'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            for (final String line in details)
              Text(
                line,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.textSecondary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The design-system pill style, wrapping under large text.
class _ScoreTag extends StatelessWidget {
  const _ScoreTag({super.key, required this.label, required this.tone});

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
