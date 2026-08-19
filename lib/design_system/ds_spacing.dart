import 'package:flutter/material.dart';

/// Spacing scale — the only allowed gap/padding values in screens.
///
/// 4pt base grid: 2 · 4 · 8 · 12 · 16 · 24 · 32 · 48
abstract final class DsSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

/// Reusable [EdgeInsets] presets built from the spacing scale.
abstract final class DsInsets {
  /// Standard padding for full-screen scroll views.
  static const EdgeInsets screen = EdgeInsets.fromLTRB(16, 8, 16, 24);

  /// Default card content padding.
  static const EdgeInsets card = EdgeInsets.all(DsSpacing.lg);

  /// Compact card padding (tiles, list rows).
  static const EdgeInsets cardCompact = EdgeInsets.all(DsSpacing.md);

  /// Vertical padding of a single list row.
  static const EdgeInsets row = EdgeInsets.symmetric(vertical: DsSpacing.sm);
}
