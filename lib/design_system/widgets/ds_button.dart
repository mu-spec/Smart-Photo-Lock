import 'package:flutter/material.dart';

import '../ds_context.dart';
import '../ds_palette.dart';
import '../ds_radii.dart';
import '../ds_spacing.dart';

/// Button variants. Maps onto Material button types:
/// primary/secondary/danger → FilledButton, outline → OutlinedButton,
/// ghost → TextButton.
enum DsButtonVariant { primary, secondary, outline, ghost, danger }

/// Button sizes.
enum DsButtonSize { small, medium, large }

/// The one button of the app — variants, sizes, icons and loading state.
class DsButton extends StatelessWidget {
  const DsButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = DsButtonVariant.primary,
    this.size = DsButtonSize.medium,
    this.icon,
    this.loading = false,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final DsButtonVariant variant;
  final DsButtonSize size;
  final IconData? icon;
  final bool loading;

  /// Stretch the button to the full available width.
  final bool expand;

  bool get _enabled => onPressed != null && !loading;

  @override
  Widget build(BuildContext context) {
    final DsPalette palette = context.dsColors;

    final (Color background, Color foreground) = switch (variant) {
      DsButtonVariant.primary => (palette.primary, palette.onPrimary),
      DsButtonVariant.secondary => (
          palette.primary.withValues(alpha: 0.16),
          palette.primary,
        ),
      DsButtonVariant.outline => (Colors.transparent, palette.primary),
      DsButtonVariant.ghost => (Colors.transparent, palette.primary),
      DsButtonVariant.danger => (palette.danger, palette.onError),
    };

    final Widget child = _buildChild(foreground);
    final Widget button = switch (variant) {
      DsButtonVariant.primary || DsButtonVariant.danger => FilledButton(
          style: _filledStyle(background, foreground),
          onPressed: _enabled ? onPressed : null,
          child: child,
        ),
      DsButtonVariant.secondary => FilledButton.tonal(
          style: _filledStyle(background, foreground),
          onPressed: _enabled ? onPressed : null,
          child: child,
        ),
      DsButtonVariant.outline => OutlinedButton(
          style: _outlineStyle(foreground),
          onPressed: _enabled ? onPressed : null,
          child: child,
        ),
      DsButtonVariant.ghost => TextButton(
          style: _ghostStyle(foreground),
          onPressed: _enabled ? onPressed : null,
          child: child,
        ),
    };

    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }

  Widget _buildChild(Color foreground) {
    final double iconSize = switch (size) {
      DsButtonSize.small => 16,
      DsButtonSize.medium => 18,
      DsButtonSize.large => 20,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (loading)
          SizedBox(
            width: iconSize,
            height: iconSize,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: foreground,
            ),
          )
        else if (icon != null)
          Icon(icon, size: iconSize),
        if (loading || icon != null) const SizedBox(width: DsSpacing.sm),
        Text(label),
      ],
    );
  }

  double get _height => switch (size) {
        DsButtonSize.small => 36,
        DsButtonSize.medium => 44,
        DsButtonSize.large => 52,
      };

  EdgeInsetsGeometry get _padding => EdgeInsets.symmetric(
        horizontal: switch (size) {
          DsButtonSize.small => 14,
          DsButtonSize.medium => 18,
          DsButtonSize.large => 24,
        },
        vertical: 0,
      );

  TextStyle get _textStyle => TextStyle(
        fontSize: switch (size) {
          DsButtonSize.small => 13,
          DsButtonSize.medium => 14,
          DsButtonSize.large => 15,
        },
        fontWeight: FontWeight.w600,
      );

  RoundedRectangleBorder get _shape => RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DsRadii.md),
      );

  ButtonStyle _filledStyle(Color background, Color foreground) {
    return FilledButton.styleFrom(
      backgroundColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => states.contains(WidgetState.disabled)
            ? background.withValues(alpha: 0.4)
            : background,
      ),
      foregroundColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => states.contains(WidgetState.disabled)
            ? foreground.withValues(alpha: 0.6)
            : foreground,
      ),
      minimumSize: Size(0, _height),
      padding: _padding,
      shape: _shape,
      textStyle: _textStyle,
    );
  }

  ButtonStyle _outlineStyle(Color foreground) {
    return OutlinedButton.styleFrom(
      foregroundColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => states.contains(WidgetState.disabled)
            ? foreground.withValues(alpha: 0.5)
            : foreground,
      ),
      side: BorderSide(color: foreground.withValues(alpha: 0.6)),
      minimumSize: Size(0, _height),
      padding: _padding,
      shape: _shape,
      textStyle: _textStyle,
    );
  }

  ButtonStyle _ghostStyle(Color foreground) {
    return TextButton.styleFrom(
      foregroundColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => states.contains(WidgetState.disabled)
            ? foreground.withValues(alpha: 0.5)
            : foreground,
      ),
      minimumSize: Size(0, _height),
      padding: _padding,
      shape: _shape,
      textStyle: _textStyle,
    );
  }
}
