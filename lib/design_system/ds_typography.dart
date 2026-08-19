import 'package:flutter/material.dart';

import 'ds_palette.dart';

/// Typography foundation.
///
/// Builds the full Material [TextTheme] from a [DsPalette] so text color
/// automatically matches the active light/dark foundation.
abstract final class DsTypography {
  /// Builds the app's text theme with palette-aware colors.
  static TextTheme buildTextTheme(DsPalette palette) {
    return TextTheme(
      displayLarge: const TextStyle(
        fontSize: 44,
        fontWeight: FontWeight.w800,
        height: 1.1,
        letterSpacing: -0.5,
      ),
      displaySmall: const TextStyle(
        fontSize: 36,
        fontWeight: FontWeight.w800,
        height: 1.15,
        letterSpacing: -0.3,
      ),
      headlineLarge: const TextStyle(
        fontSize: 30,
        fontWeight: FontWeight.w700,
        height: 1.2,
      ),
      headlineMedium: const TextStyle(
        fontSize: 26,
        fontWeight: FontWeight.w700,
        height: 1.25,
      ),
      headlineSmall: const TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        height: 1.3,
      ),
      titleLarge: const TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
      titleMedium: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.35,
      ),
      titleSmall: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        height: 1.35,
      ),
      bodyLarge: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        height: 1.5,
      ),
      bodyMedium: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.45,
      ),
      bodySmall: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        height: 1.4,
      ),
      labelLarge: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
      labelMedium: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        height: 1.3,
      ),
      labelSmall: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        height: 1.3,
        letterSpacing: 0.4,
      ),
    ).apply(
      bodyColor: palette.textPrimary,
      displayColor: palette.textPrimary,
    );
  }

  /// Fixed-width style for PINs, codes and technical values.
  static const TextStyle mono = TextStyle(
    fontFamily: 'monospace',
    fontSize: 13,
    letterSpacing: 0.5,
  );
}
