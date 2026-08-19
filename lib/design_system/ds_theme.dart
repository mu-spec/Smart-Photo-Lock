import 'package:flutter/material.dart';

import 'ds_palette.dart';
import 'ds_radii.dart';
import 'ds_typography.dart';

/// Theme builders — the light/dark foundations of the app.
///
/// Both themes are generated from the same token set ([DsPalette]), so
/// light and dark can never drift apart. `AppTheme` in `app/theme/` is a
/// thin wrapper around these builders.
abstract final class DsThemes {
  static ThemeData build(Brightness brightness) {
    final DsPalette palette =
        brightness == Brightness.dark ? DsPalette.dark : DsPalette.light;
    final ColorScheme scheme = palette.toColorScheme();

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: palette.background,
      textTheme: DsTypography.buildTextTheme(palette),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        centerTitle: false,
        elevation: 0,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: palette.textPrimary,
        ),
      ),
      cardTheme: CardThemeData(
        color: palette.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DsRadii.lg),
          side: BorderSide(color: palette.border.withValues(alpha: 0.6)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: palette.surface,
        indicatorColor: palette.primary.withValues(alpha: 0.16),
        height: 68,
        iconTheme: WidgetStateProperty.resolveWith<IconThemeData>(
          (Set<WidgetState> states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? palette.primary
                : palette.textSecondary,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>(
          (Set<WidgetState> states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w400,
            color: states.contains(WidgetState.selected)
                ? palette.primary
                : palette.textSecondary,
          ),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: palette.border.withValues(alpha: 0.5),
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: palette.surfaceElevated,
        contentTextStyle: TextStyle(color: palette.textPrimary, fontSize: 14),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DsRadii.md),
        ),
      ),
    );
  }
}
