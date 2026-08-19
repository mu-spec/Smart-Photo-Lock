import 'package:flutter/material.dart';

import '../app/theme/app_colors.dart';

/// Semantic color tokens for the whole app.
///
/// Screens and components never hard-code colors — they read from the
/// [DsPalette] matched to the current brightness (see `context.dsColors`).
/// Brand raw colors live in `app/theme/app_colors.dart`; this layer maps
/// them onto semantic roles (background, surface, border, danger, ...).
class DsPalette {
  const DsPalette({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceElevated,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.primary,
    required this.onPrimary,
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.onError,
  });

  /// Dark palette — the brand's first-class look (navy + teal).
  static const DsPalette dark = DsPalette(
    brightness: Brightness.dark,
    background: AppColors.navy900,
    surface: AppColors.navy800,
    surfaceElevated: AppColors.navy700,
    border: Color(0xFF2A3866),
    textPrimary: AppColors.textPrimary,
    textSecondary: AppColors.textSecondary,
    primary: AppColors.accent,
    onPrimary: AppColors.navy900,
    success: AppColors.success,
    warning: AppColors.warning,
    danger: AppColors.danger,
    info: Color(0xFF60A5FA),
    onError: AppColors.navy900,
  );

  /// Light palette — navy-tinted surfaces with the same teal accent.
  static const DsPalette light = DsPalette(
    brightness: Brightness.light,
    background: Color(0xFFF3F5FB),
    surface: Colors.white,
    surfaceElevated: Color(0xFFE9EEF8),
    border: Color(0xFFD6DDF0),
    textPrimary: Color(0xFF141B36),
    textSecondary: Color(0xFF5B6688),
    primary: Color(0xFF0D9488),
    onPrimary: Colors.white,
    success: Color(0xFF059669),
    warning: Color(0xFFD97706),
    danger: Color(0xFFDC2626),
    info: Color(0xFF2563EB),
    onError: Colors.white,
  );

  final Brightness brightness;

  // Surfaces
  final Color background;
  final Color surface;
  final Color surfaceElevated;
  final Color border;

  // Text
  final Color textPrimary;
  final Color textSecondary;

  // Accent
  final Color primary;
  final Color onPrimary;

  // Status tones
  final Color success;
  final Color warning;
  final Color danger;
  final Color info;
  final Color onError;

  /// Material [ColorScheme] built from these tokens.
  ColorScheme toColorScheme() {
    final ColorScheme base = brightness == Brightness.dark
        ? ColorScheme.dark(
            primary: primary,
            onPrimary: onPrimary,
            secondary: primary,
            onSecondary: onPrimary,
            error: danger,
            onError: onError,
            surface: surface,
            onSurface: textPrimary,
            outline: border,
            surfaceContainerHighest: surfaceElevated,
          )
        : ColorScheme.light(
            primary: primary,
            onPrimary: onPrimary,
            secondary: primary,
            onSecondary: onPrimary,
            error: danger,
            onError: onError,
            surface: surface,
            onSurface: textPrimary,
            outline: border,
            surfaceContainerHighest: surfaceElevated,
          );
    return base.copyWith(errorContainer: danger.withValues(alpha: 0.15));
  }
}
