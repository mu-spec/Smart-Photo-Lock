import 'auth_type.dart';

/// High-level posture of the credential configuration.
enum CredentialStatus {
  /// No credential has been enrolled yet.
  unset,

  /// At least one credential is enrolled and ready.
  enrolled,

  /// A credential exists but authentication is temporarily blocked.
  lockedOut,
}

/// Immutable snapshot of the authentication configuration: which
/// credential types are enrolled, which one is primary, and the current
/// attempt/lockout counters.
class CredentialState {
  const CredentialState({
    required this.enrolled,
    this.primary,
    this.failedAttempts = 0,
    this.lockedOutUntil,
  });

  /// Every enrolled credential type.
  final Set<AuthType> enrolled;

  /// The primary credential (always [AuthType.pin] or [AuthType.pattern] —
  /// biometric is an accelerator, never the primary secret).
  final AuthType? primary;

  /// Consecutive failed attempts since the last success.
  final int failedAttempts;

  /// When the current lockout expires (null = not locked out).
  final DateTime? lockedOutUntil;

  /// Status resolved against [now].
  CredentialStatus statusAt(DateTime now) {
    if (lockedOutUntil != null && now.isBefore(lockedOutUntil!)) {
      return CredentialStatus.lockedOut;
    }
    return enrolled.isEmpty ? CredentialStatus.unset : CredentialStatus.enrolled;
  }

  /// Status resolved against the current wall clock.
  CredentialStatus get status => statusAt(DateTime.now());

  bool hasEnrolled(AuthType type) => enrolled.contains(type);

  bool get hasAnyCredential => enrolled.isNotEmpty;

  bool get isLockedOutAtNow =>
      lockedOutUntil != null && DateTime.now().isBefore(lockedOutUntil!);

  CredentialState copyWith({
    Set<AuthType>? enrolled,
    AuthType? primary,
    int? failedAttempts,
    DateTime? lockedOutUntil,
    bool clearLockout = false,
  }) {
    return CredentialState(
      enrolled: enrolled ?? this.enrolled,
      primary: primary ?? this.primary,
      failedAttempts: failedAttempts ?? this.failedAttempts,
      lockedOutUntil: clearLockout ? null : (lockedOutUntil ?? this.lockedOutUntil),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'enrolled': enrolled.map((AuthType t) => t.storageName).toList(),
        'primary': primary?.storageName,
        'failedAttempts': failedAttempts,
        'lockedOutUntilEpochMs': lockedOutUntil?.millisecondsSinceEpoch,
      };

  factory CredentialState.fromJson(Map<String, dynamic> json) =>
      CredentialState(
        enrolled: ((json['enrolled'] as List<dynamic>?) ?? const <dynamic>[])
            .map((dynamic name) => AuthType.fromStorageName(name as String))
            .toSet(),
        primary: json['primary'] == null
            ? null
            : AuthType.fromStorageName(json['primary'] as String),
        failedAttempts: json['failedAttempts'] as int? ?? 0,
        lockedOutUntil: json['lockedOutUntilEpochMs'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                json['lockedOutUntilEpochMs'] as int,
              ),
      );

  @override
  String toString() =>
      'CredentialState(enrolled: ${enrolled.map((AuthType t) => t.name).join(',')}, '
      'primary: ${primary?.name ?? 'none'}, attempts: $failedAttempts, '
      'lockedOutUntil: ${lockedOutUntil?.toIso8601String() ?? 'none'})';
}
