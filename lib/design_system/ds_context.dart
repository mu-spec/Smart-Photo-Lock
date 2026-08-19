import 'package:flutter/widgets.dart';

import 'ds_palette.dart';

/// Convenience accessors for design-system tokens on any [BuildContext].
extension DsContextX on BuildContext {
  /// The semantic palette matching the current brightness.
  DsPalette get dsColors =>
      Theme.of(this).brightness == Brightness.dark ? DsPalette.dark : DsPalette.light;
}
