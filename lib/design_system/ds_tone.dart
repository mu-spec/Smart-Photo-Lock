import 'package:flutter/material.dart';

import 'ds_palette.dart';

/// Status/semantic tones used across pills, banners and status items.
enum DsTone {
  /// Neutral grey — "not set", "coming soon".
  neutral,

  /// Green — everything protected.
  success,

  /// Amber — needs attention.
  warning,

  /// Red — at risk / blocked.
  danger,

  /// Blue — informational.
  info,
}

/// Resolves a tone against a palette (pure extension — no Flutter imports
/// needed beyond [DsPalette]).
extension DsToneX on DsTone {
  /// The tone's main color in the given palette.
  Color colorOf(DsPalette palette) => switch (this) {
        DsTone.neutral => palette.textSecondary,
        DsTone.success => palette.success,
        DsTone.warning => palette.warning,
        DsTone.danger => palette.danger,
        DsTone.info => palette.info,
      };

  /// A soft container fill for the tone (icons, banners, pills).
  Color containerOf(DsPalette palette) => colorOf(palette).withValues(alpha: 0.12);
}
