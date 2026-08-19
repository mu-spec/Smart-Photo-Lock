import 'package:flutter/foundation.dart';

/// Minimal leveled logger.
///
/// Debug builds print to the console; release builds stay silent until a
/// crash-reporting / telemetry backend is wired in a later phase.
abstract final class AppLogger {
  static void debug(String message, [String tag = 'App']) =>
      _log('DEBUG', tag, message);

  static void info(String message, [String tag = 'App']) =>
      _log('INFO', tag, message);

  static void warn(String message, [String tag = 'App']) =>
      _log('WARN', tag, message);

  static void error(
    String message, [
    String tag = 'App',
    Object? error,
    StackTrace? stackTrace,
  ]) {
    final String details =
        error == null ? '' : ' | ${error.toString()}';
    _log('ERROR', tag, '$message$details');
  }

  static void _log(String level, String tag, String message) {
    if (kDebugMode) {
      debugPrint('[$level/$tag] $message');
    }
  }
}
