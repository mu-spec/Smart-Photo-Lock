import 'package:flutter/material.dart';

import '../../../data/models/app_security_level.dart';
import '../../../data/models/security_recommendation.dart';
import '../../../design_system/design_system.dart';

/// What the user did in the [SecurityLevelSheet].
class SecurityLevelSheetResult {
  const SecurityLevelSheetResult.level(AppSecurityLevel this.level)
      : dismissRecommendation = false;

  const SecurityLevelSheetResult.dismissRecommendation()
      : level = null,
        dismissRecommendation = true;

  /// The chosen level (null when the suggestion was dismissed instead).
  final AppSecurityLevel? level;

  /// The user tapped "Don't suggest again".
  final bool dismissRecommendation;
}

/// Phase 8 (PRD 8B, 8F): per-app security level picker.
///
/// A bottom sheet with the three levels. Choosing one only RETURNS it; the
/// caller saves it (lowering a level goes through the CR-2 credential
/// gate) and reports the result. The sheet itself writes nothing.
///
/// Phase 8 / M2: it may show an advisory [recommendation]. Accepting it is
/// the same explicit choice as tapping that level; dismissing it only
/// hides the suggestion. When native still enforces a stricter level than
/// the saved one ([enforced]), it says so.
class SecurityLevelSheet extends StatelessWidget {
  const SecurityLevelSheet({
    super.key,
    required this.appLabel,
    required this.current,
    this.enforced,
    this.recommendation,
  });

  final String appLabel;

  /// The saved level (marked "current").
  final AppSecurityLevel current;

  /// The level native enforces, when stricter than [current].
  final AppSecurityLevel? enforced;

  /// Advisory suggestion (8F), or null.
  final SecurityRecommendation? recommendation;

  static String title(String appLabel) => 'Security level for $appLabel';

  /// How levels behave (Phase 8 / M2: they are enforced).
  static const String levelNotice =
      'Stricter levels re-lock sooner. Lowering a level asks for your PIN or '
      'pattern first.';

  /// Shown when native still enforces a stricter level than the saved one.
  static String enforcedNotice(AppSecurityLevel enforced) =>
      '${enforced.label} is still enforced for this app because the last '
      'change could not be confirmed. Choose a level to try again.';

  static String recommendationTitle(AppSecurityLevel level) =>
      'Suggested: ${level.label}';
  static String acceptRecommendationLabel(AppSecurityLevel level) =>
      'Use ${level.label}';
  static const String dismissRecommendationLabel = "Don't suggest again";

  static Key optionKey(AppSecurityLevel level) =>
      Key('security_level_option_${level.storageId}');

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          DsSpacing.lg,
          DsSpacing.md,
          DsSpacing.lg,
          DsSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Semantics(
              header: true,
              child: Text(title(appLabel), style: text.titleMedium),
            ),
            const SizedBox(height: DsSpacing.sm),
            DsCard(
              key: const Key('security_level_notice'),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.info_outline,
                    size: 20,
                    color: context.dsColors.textSecondary,
                  ),
                  const SizedBox(width: DsSpacing.sm),
                  Expanded(
                    child: Text(levelNotice, style: text.bodySmall),
                  ),
                ],
              ),
            ),
            if (enforced != null && enforced!.isStricterThan(current)) ...[
              const SizedBox(height: DsSpacing.sm),
              DsCard(
                key: const Key('security_level_enforced_notice'),
                child: Text(enforcedNotice(enforced!), style: text.bodySmall),
              ),
            ],
            if (recommendation != null) ...[
              const SizedBox(height: DsSpacing.sm),
              _RecommendationCard(recommendation: recommendation!),
            ],
            const SizedBox(height: DsSpacing.sm),
            for (final AppSecurityLevel level in AppSecurityLevel.values)
              _LevelOption(
                level: level,
                selected: level == current,
                onTap: () => Navigator.of(context)
                    .pop(SecurityLevelSheetResult.level(level)),
              ),
          ],
        ),
      ),
    );
  }
}

class _RecommendationCard extends StatelessWidget {
  const _RecommendationCard({required this.recommendation});

  final SecurityRecommendation recommendation;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final AppSecurityLevel level = recommendation.level;
    return DsCard(
      key: const Key('security_level_recommendation'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            SecurityLevelSheet.recommendationTitle(level),
            style: text.titleSmall,
          ),
          const SizedBox(height: DsSpacing.xs),
          Text(recommendation.reason, style: text.bodySmall),
          const SizedBox(height: DsSpacing.sm),
          Wrap(
            spacing: DsSpacing.sm,
            runSpacing: DsSpacing.xs,
            children: <Widget>[
              FilledButton(
                key: const Key('security_level_recommendation_accept'),
                onPressed: () => Navigator.of(context)
                    .pop(SecurityLevelSheetResult.level(level)),
                child:
                    Text(SecurityLevelSheet.acceptRecommendationLabel(level)),
              ),
              TextButton(
                key: const Key('security_level_recommendation_dismiss'),
                onPressed: () => Navigator.of(context).pop(
                  const SecurityLevelSheetResult.dismissRecommendation(),
                ),
                child:
                    const Text(SecurityLevelSheet.dismissRecommendationLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LevelOption extends StatelessWidget {
  const _LevelOption({
    required this.level,
    required this.selected,
    required this.onTap,
  });

  final AppSecurityLevel level;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // One merged node: the tappable row carries the radio state, so screen
    // readers announce "checked, in group" on the control itself.
    return MergeSemantics(
      child: Semantics(
        inMutuallyExclusiveGroup: true,
        checked: selected,
        selected: selected,
        child: ListTile(
          key: SecurityLevelSheet.optionKey(level),
          minVerticalPadding: DsSpacing.sm,
          contentPadding: EdgeInsets.zero,
          selected: selected,
          selectedColor: context.dsColors.primary,
          leading: Icon(
            selected
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
          ),
          title: Text(selected ? '${level.label} (current)' : level.label),
          subtitle: Text(level.description),
          onTap: onTap,
        ),
      ),
    );
  }
}

/// Opens the picker. Returns what the user chose, or null when the sheet
/// was closed without a choice.
Future<SecurityLevelSheetResult?> showSecurityLevelSheet(
  BuildContext context, {
  required String appLabel,
  required AppSecurityLevel current,
  AppSecurityLevel? enforced,
  SecurityRecommendation? recommendation,
}) =>
    showModalBottomSheet<SecurityLevelSheetResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) => SecurityLevelSheet(
        appLabel: appLabel,
        current: current,
        enforced: enforced,
        recommendation: recommendation,
      ),
    );
