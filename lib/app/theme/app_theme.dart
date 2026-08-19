import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Global dark theme for Smart App Lock.
///
/// Material 3, seeded from the brand navy and overridden with the teal
/// accent. Component themes (cards, inputs, dialogs) get tuned here as
/// feature screens land in later phases.
abstract final class AppTheme {
  static ThemeData get dark {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: AppColors.navy800,
      brightness: Brightness.dark,
    ).copyWith(
      primary: AppColors.accent,
      onPrimary: AppColors.navy900,
      surface: AppColors.navy800,
      onSurface: AppColors.textPrimary,
      error: AppColors.danger,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.navy900,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        centerTitle: false,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: AppColors.navy700,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }
}
