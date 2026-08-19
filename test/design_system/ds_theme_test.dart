import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_lock/app/theme/app_colors.dart';
import 'package:smart_app_lock/app/theme/app_theme.dart';
import 'package:smart_app_lock/design_system/design_system.dart';

void main() {
  group('Light/dark foundations', () {
    test('themes report the right brightness', () {
      expect(AppTheme.light.brightness, Brightness.light);
      expect(AppTheme.dark.brightness, Brightness.dark);
    });

    test('light and dark palettes use distinct semantic tokens', () {
      expect(DsPalette.light.background, isNot(DsPalette.dark.background));
      expect(DsPalette.light.surface, isNot(DsPalette.dark.surface));
      expect(DsPalette.light.textPrimary, isNot(DsPalette.dark.textPrimary));
    });

    test('dark palette is the brand navy + teal', () {
      expect(DsPalette.dark.background, AppColors.navy900);
      expect(DsPalette.dark.primary, AppColors.accent);
      expect(DsPalette.dark.surface, AppColors.navy800);
    });

    test('palettes convert to complete color schemes', () {
      final ColorScheme lightScheme = DsPalette.light.toColorScheme();
      final ColorScheme darkScheme = DsPalette.dark.toColorScheme();
      expect(lightScheme.brightness, Brightness.light);
      expect(darkScheme.brightness, Brightness.dark);
      expect(lightScheme.error, DsPalette.light.danger);
      expect(darkScheme.outline, DsPalette.dark.border);
    });
  });

  group('Typography', () {
    test('covers all material text roles', () {
      final TextTheme t = DsTypography.buildTextTheme(DsPalette.dark);
      expect(t.displayLarge, isNotNull);
      expect(t.displaySmall, isNotNull);
      expect(t.headlineLarge, isNotNull);
      expect(t.headlineMedium, isNotNull);
      expect(t.headlineSmall, isNotNull);
      expect(t.titleLarge, isNotNull);
      expect(t.titleMedium, isNotNull);
      expect(t.titleSmall, isNotNull);
      expect(t.bodyLarge, isNotNull);
      expect(t.bodyMedium, isNotNull);
      expect(t.bodySmall, isNotNull);
      expect(t.labelLarge, isNotNull);
      expect(t.labelMedium, isNotNull);
      expect(t.labelSmall, isNotNull);
    });

    test('text colors follow the palette', () {
      final TextTheme t = DsTypography.buildTextTheme(DsPalette.light);
      expect(t.bodyMedium?.color, DsPalette.light.textPrimary);
    });
  });

  group('Scales', () {
    test('spacing scale is strictly monotonic', () {
      expect(DsSpacing.xxs, lessThan(DsSpacing.xs));
      expect(DsSpacing.xs, lessThan(DsSpacing.sm));
      expect(DsSpacing.sm, lessThan(DsSpacing.md));
      expect(DsSpacing.md, lessThan(DsSpacing.lg));
      expect(DsSpacing.lg, lessThan(DsSpacing.xl));
      expect(DsSpacing.xl, lessThan(DsSpacing.xxl));
      expect(DsSpacing.xxl, lessThan(DsSpacing.xxxl));
    });

    test('radii scale is strictly monotonic', () {
      expect(DsRadii.sm, lessThan(DsRadii.md));
      expect(DsRadii.md, lessThan(DsRadii.lg));
      expect(DsRadii.lg, lessThan(DsRadii.xl));
      expect(DsRadii.xl, lessThan(DsRadii.pill));
    });
  });
}
