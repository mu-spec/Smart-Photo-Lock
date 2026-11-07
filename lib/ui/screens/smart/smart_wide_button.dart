import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';

/// Phase 10 / M2: full-width action button for the Smart Rules screens.
///
/// Unlike the fixed-height `DsButton`, the label wraps and the button grows
/// vertically, so it stays readable at 320 dp with 2× text (PRD 10G
/// accessibility). Same palette as `DsButton` (primary or danger).
class SmartWideButton extends StatelessWidget {
  const SmartWideButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.danger = false,
    this.busy = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool danger;

  /// Shows a small progress indicator instead of the icon (and disables).
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final DsPalette palette = context.dsColors;
    final Color background = danger ? palette.danger : palette.primary;
    final Color foreground = danger ? palette.onError : palette.onPrimary;
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: background,
          foregroundColor: foreground,
          minimumSize: const Size.fromHeight(44),
          padding: const EdgeInsets.symmetric(
            horizontal: DsSpacing.lg,
            vertical: DsSpacing.sm,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DsRadii.md),
          ),
        ),
        onPressed: busy ? null : onPressed,
        icon: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon, size: 18),
        label: Text(label, textAlign: TextAlign.center),
      ),
    );
  }
}
