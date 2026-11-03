import '../data/models/app_security_level.dart';

/// Phase 8 / M2 (PRD 8C/8D/8E): the re-lock policy of each security level.
///
/// Pure Dart. Mirrors native `SecurityLevelPolicy.kt` exactly; the native
/// engine stays the final gate and applies the same numbers from its own
/// persisted copy of the levels.
///
/// A level only ever adds strictness on top of the user's Security
/// settings: it can shorten or remove the re-lock grace and shorten the H-2
/// inactivity window. It never grants access, never extends grace beyond
/// the configured value and never touches tickets or lockout.
///
/// | | Standard | Sensitive | Critical |
/// | --- | --- | --- | --- |
/// | grace after leaving | configured | min(configured, 15 s) | none |
/// | inactivity window | requested (2 min) | 1 min | 1 min |
abstract final class SecurityLevelPolicy {
  /// Sensitive never keeps more than this much grace after a leave.
  static const Duration sensitiveGraceCap = Duration(seconds: 15);

  /// H-2 inactivity window cap for Sensitive and Critical.
  static const Duration strictSessionWindow = Duration(minutes: 1);

  /// Grace applied when leaving an app of [level]. Never above [configured].
  static Duration graceFor(AppSecurityLevel level, Duration configured) {
    final Duration safe = configured.isNegative ? Duration.zero : configured;
    switch (level) {
      case AppSecurityLevel.standard:
        return safe;
      case AppSecurityLevel.sensitive:
        return safe < sensitiveGraceCap ? safe : sensitiveGraceCap;
      case AppSecurityLevel.critical:
        return Duration.zero;
    }
  }

  /// Inactivity window for a new unlock of an app of [level]: Standard keeps
  /// [requested] unchanged; Sensitive and Critical cap it at
  /// [strictSessionWindow]. Never longer than [requested].
  static Duration sessionWindowFor(AppSecurityLevel level, Duration requested) {
    final Duration safe = requested.isNegative ? Duration.zero : requested;
    if (level == AppSecurityLevel.standard) return safe;
    return safe < strictSessionWindow ? safe : strictSessionWindow;
  }

  /// The stricter of two levels (equal → [a]).
  static AppSecurityLevel stricter(AppSecurityLevel a, AppSecurityLevel b) =>
      b.isStricterThan(a) ? b : a;
}
