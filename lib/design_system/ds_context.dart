import 'package:flutter/material.dart';

import 'ds_palette.dart';

/// Convenience accessors for design-system tokens on any [BuildContext].
///
/// Note: `Theme` (and `Theme.of`) live in the material library — a plain
/// `widgets.dart` import is not enough.
extension DsContextX on BuildContext {
  /// The semantic palette matching the current brightness.
  DsPalette get dsColors =>
      Theme.of(this).brightness == Brightness.dark ? DsPalette.dark : DsPalette.light;
}
