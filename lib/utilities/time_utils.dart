/// Small time helpers shared by the rules engine and lock sessions.
abstract final class TimeUtils {
  /// Minutes since midnight, e.g. 09:30 -> 570.
  /// This is the unit [LockRule] time windows use.
  static int minutesOfDay(DateTime time) => time.hour * 60 + time.minute;

  /// True when [minuteOfDay] falls in `[start, end)`, including windows that
  /// wrap past midnight (e.g. 22:00 -> 06:00).
  static bool isWithinWindow(int minuteOfDay, int start, int end) {
    if (start == end) {
      return false; // degenerate window — never matches
    }
    if (start < end) {
      return minuteOfDay >= start && minuteOfDay < end;
    }
    return minuteOfDay >= start || minuteOfDay < end;
  }

  /// Human-friendly duration, e.g. `2m 30s`, `1h 05m`.
  static String formatDuration(Duration duration) {
    if (duration.inHours >= 1) {
      return '${duration.inHours}h ${duration.inMinutes % 60}m';
    }
    final int minutes = duration.inMinutes;
    if (minutes >= 1) {
      return '${minutes}m ${duration.inSeconds % 60}s';
    }
    return '${duration.inSeconds}s';
  }
}
