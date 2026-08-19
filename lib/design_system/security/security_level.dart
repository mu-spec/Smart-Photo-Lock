import 'package:flutter/material.dart';

import '../ds_tone.dart';

/// Security posture levels used by every status component.
enum SecurityLevel {
  /// Everything the user configured is active.
  secured('Protected', DsTone.success, Icons.verified_user_outlined),

  /// At least one protection is missing or misconfigured.
  atRisk('Needs attention', DsTone.warning, Icons.warning_amber_rounded),

  /// Core protection is missing — locking is effectively off.
  vulnerable('At risk', DsTone.danger, Icons.gpp_bad_outlined),

  /// Feature not configured at all.
  notSet('Not set', DsTone.neutral, Icons.remove_circle_outline);

  const SecurityLevel(this.label, this.tone, this.icon);

  /// Default human-readable label.
  final String label;

  /// Color tone this level maps to.
  final DsTone tone;

  /// Icon representing the level.
  final IconData icon;
}
