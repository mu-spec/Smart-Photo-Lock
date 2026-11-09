// Phase 12 / Milestone 1 — Intruder Defense foundation.
//
// The persisted failed-attempt record and its versioned, bounded document.
// Pure data + strict codecs: any malformed field makes the WHOLE document
// invalid (FormatException), which the store reports as corrupt.
//
// Privacy: no PIN, no pattern, no input length, no hash, no biometric data,
// no image. Only method, surface, challenge attribution and counters.
import '../credentials/verified_attempt.dart';

/// Credential method of a failed verification (biometric never produces a
/// failed-attempt event — see the M1 design gate §D.2).
enum FailedAttemptMethod { pin, pattern }

/// One failed PIN / pattern verification, as decided by the credential
/// manager.
final class FailedAttemptEvent {
  const FailedAttemptEvent({
    required this.seq,
    required this.verificationId,
    required this.at,
    required this.method,
    required this.surface,
    required this.consecutiveFailures,
    required this.lockoutTriggered,
    required this.lockoutStreak,
    required this.counterPersisted,
    this.packageName,
    this.generation,
    this.challengeSerial,
  });

  /// Monotonic event identity and order (never the wall clock).
  final int seq;

  /// The manager's unique verification id (dedup key).
  final String verificationId;

  /// Wall clock at the verdict — display / retention only.
  final DateTime at;

  final FailedAttemptMethod method;
  final AuthAttemptSurface surface;

  /// Protected package of the challenge (challenge surface only).
  final String? packageName;

  /// Native challenge ticket generation (challenge surface only).
  final int? generation;

  /// Host challenge serial (challenge surface only).
  final int? challengeSerial;

  /// Consecutive failed PIN / pattern verifications, including this one.
  final int consecutiveFailures;

  /// Whether this verification started a cooldown.
  final bool lockoutTriggered;

  /// Lockout streak after this verification.
  final int lockoutStreak;

  /// Whether the attempt-counter write for this verification succeeded.
  final bool counterPersisted;

  static const int maxPackageNameLength = 256;
  static const int maxVerificationIdLength = 64;

  Map<String, Object?> toJson() => <String, Object?>{
        'seq': seq,
        'vid': verificationId,
        'at': at.millisecondsSinceEpoch,
        'method': method.name,
        'surface': surface.name,
        if (packageName != null) 'pkg': packageName,
        if (generation != null) 'gen': generation,
        if (challengeSerial != null) 'chal': challengeSerial,
        'run': consecutiveFailures,
        'lockout': lockoutTriggered,
        'streak': lockoutStreak,
        'persisted': counterPersisted,
      };

  /// Strict decoder: throws [FormatException] on any invalid field.
  static FailedAttemptEvent fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('event is not an object');
    }
    final Map<Object?, Object?> json = raw;
    T field<T>(String key) {
      final Object? v = json[key];
      if (v is! T) {
        throw FormatException('event field "$key" is invalid');
      }
      return v;
    }

    T? optional<T>(String key) {
      final Object? v = json[key];
      if (v == null) {
        return null;
      }
      if (v is! T) {
        throw FormatException('event field "$key" is invalid');
      }
      return v as T;
    }

    E byName<E extends Enum>(List<E> values, String key) {
      final String name = field<String>(key);
      for (final E v in values) {
        if (v.name == name) {
          return v;
        }
      }
      throw FormatException('event field "$key" is invalid');
    }

    final int seq = field<int>('seq');
    final String vid = field<String>('vid');
    final int atMs = field<int>('at');
    final FailedAttemptMethod method =
        byName(FailedAttemptMethod.values, 'method');
    final AuthAttemptSurface surface =
        byName(AuthAttemptSurface.values, 'surface');
    final String? pkg = optional<String>('pkg');
    final int? gen = optional<int>('gen');
    final int? chal = optional<int>('chal');
    final int run = field<int>('run');
    final bool lockout = field<bool>('lockout');
    final int streak = field<int>('streak');
    final bool persisted = field<bool>('persisted');

    if (seq < 0 ||
        vid.isEmpty ||
        vid.length > maxVerificationIdLength ||
        run < 1 ||
        streak < 0 ||
        atMs.abs() > 8640000000000000) {
      throw const FormatException('event value out of range');
    }
    final bool isChallenge =
        surface == AuthAttemptSurface.protectedAppChallenge;
    if (isChallenge) {
      if (pkg == null ||
          pkg.isEmpty ||
          pkg.length > maxPackageNameLength ||
          gen == null ||
          chal == null) {
        throw const FormatException('challenge event without attribution');
      }
    } else if (pkg != null || gen != null || chal != null) {
      throw const FormatException('app event with challenge attribution');
    }
    return FailedAttemptEvent(
      seq: seq,
      verificationId: vid,
      at: DateTime.fromMillisecondsSinceEpoch(atMs),
      method: method,
      surface: surface,
      packageName: pkg,
      generation: gen,
      challengeSerial: chal,
      consecutiveFailures: run,
      lockoutTriggered: lockout,
      lockoutStreak: streak,
      counterPersisted: persisted,
    );
  }

  @override
  String toString() => 'FailedAttemptEvent(seq=$seq, method=${method.name}, '
      'surface=${surface.name}, pkg=${packageName == null ? '-' : '<redacted>'}, '
      'run=$consecutiveFailures, lockout=$lockoutTriggered, '
      'streak=$lockoutStreak, persisted=$counterPersisted)';
}

/// The versioned failed-attempt log document (schema v1).
final class IntruderFailureLog {
  const IntruderFailureLog({
    required this.nextSeq,
    required this.consecutiveFailures,
    required this.events,
  });

  static const IntruderFailureLog empty = IntruderFailureLog(
    nextSeq: 0,
    consecutiveFailures: 0,
    events: <FailedAttemptEvent>[],
  );

  static const String schema = 'sal.intruder_log';
  static const int version = 1;

  /// Decoder hard limit (well above the retention cap) so a hostile or
  /// damaged document can never make decoding unbounded.
  static const int maxDecodableEvents = 1000;

  /// Saturation bound for the consecutive-failure run (never overflows).
  static const int maxRun = 0x7fffffff;

  /// Sequence the next event receives.
  final int nextSeq;

  /// Consecutive failed PIN / pattern verifications since the last verified
  /// success (persisted; survives restarts and lockout expiry).
  final int consecutiveFailures;

  /// Events, oldest first, strictly increasing [FailedAttemptEvent.seq].
  final List<FailedAttemptEvent> events;

  Map<String, Object?> toJson() => <String, Object?>{
        'schema': schema,
        'v': version,
        'nextSeq': nextSeq,
        'run': consecutiveFailures,
        'events': <Object?>[
          for (final FailedAttemptEvent e in events) e.toJson(),
        ],
      };

  /// Reads only the declared version (null when absent or not an int).
  static int? declaredVersion(Object? raw) {
    if (raw is Map && raw['v'] is int) {
      return raw['v'] as int;
    }
    return null;
  }

  /// Strict v1 decoder: throws [FormatException] on any invalid content.
  static IntruderFailureLog fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('log is not an object');
    }
    if (raw['schema'] != schema || raw['v'] != version) {
      throw const FormatException('log schema/version mismatch');
    }
    final Object? nextSeq = raw['nextSeq'];
    final Object? run = raw['run'];
    final Object? list = raw['events'];
    if (nextSeq is! int ||
        nextSeq < 0 ||
        run is! int ||
        run < 0 ||
        run > maxRun ||
        list is! List ||
        list.length > maxDecodableEvents) {
      throw const FormatException('log header invalid');
    }
    final List<FailedAttemptEvent> events = <FailedAttemptEvent>[];
    int lastSeq = -1;
    for (final Object? item in list) {
      final FailedAttemptEvent e = FailedAttemptEvent.fromJson(item);
      if (e.seq <= lastSeq || e.seq >= nextSeq) {
        throw const FormatException('log sequence invalid');
      }
      lastSeq = e.seq;
      events.add(e);
    }
    return IntruderFailureLog(
      nextSeq: nextSeq,
      consecutiveFailures: run,
      events: List<FailedAttemptEvent>.unmodifiable(events),
    );
  }
}
