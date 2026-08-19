import 'package:flutter/material.dart';

import '../widgets/ds_status_pill.dart';
import 'security_level.dart';

/// Compact pill showing a [SecurityLevel] (e.g. "Not set" / "Protected").
class SecurityStatusPill extends StatelessWidget {
  const SecurityStatusPill({super.key, required this.level, this.label});

  final SecurityLevel level;

  /// Overrides the level's default label (e.g. "0 apps").
  final String? label;

  @override
  Widget build(BuildContext context) {
    return DsStatusPill(label: label ?? level.label, tone: level.tone);
  }
}
