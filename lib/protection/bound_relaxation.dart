/// Phase 11 / M2: the bound relaxation protocol ("probe-then-flag").
///
/// Native accepts one broad boolean, `authorizedRuleRelaxation`, which lets
/// it move from WHATEVER rules it holds to the candidate. On its own that
/// flag could release an unrelated, still-held reduction (a rule PIN
/// carrying a profile reduction, or the reverse). The protection bootstrap,
/// the single serialized caller of `configureProtection`, therefore sets the
/// flag ONLY through `ProtectionBootstrap.applyBoundRelaxation`, which:
///
///  1. re-reads storage and requires the operation's captured state;
///  2. recomputes the relaxed packages over the full weekly schedule;
///  3. consumes the operation's proof for exactly those packages;
///  4. probes: sends the expected-before transport WITHOUT the flag and
///     continues only on `applied` (native then holds exactly that state);
///  5. sends the requested-after transport WITH the flag, so native relaxes
///     precisely the authorized difference and nothing else;
///  6. commits (profiles) or recovers by re-sending expected-before without
///     the flag. Never reports success without an `applied` ack.
library;

/// Which kind of operation a native relaxation flag belongs to. A proof
/// for one intent never authorizes another (see
/// `consumeBoundRelaxation` in the CR-2 gate).
enum BoundRelaxationIntent {
  /// A Smart Rule change that reduces rule protection (Phase 10 / M2).
  ruleReduction,

  /// A profile switch, an edit of the active profile, or its deletion.
  profileChange,

  /// Apply the saved rules and profile while native holds stricter ones.
  /// Bound to the exact saved configuration that was displayed.
  confirmSaved,
}

/// The outcome of a bound relaxation.
enum BoundRelaxationStatus {
  /// Native acknowledged the requested state (`applied`), and a profile
  /// document was committed. The relaxation is in force.
  applied,

  /// Nothing needed relaxing after all (a concurrent change); the state
  /// was sent without the flag and native kept stricter rules (`held`).
  held,

  /// Nothing needed relaxing after all; the unflagged send was not
  /// acknowledged. Saved, not confirmed.
  unconfirmed,

  /// Storage no longer matches the operation. Nothing sent with the flag.
  conflict,

  /// The proof was refused (intent, scope, expiry, reuse). Nothing sent
  /// with the flag.
  denied,

  /// Credentials, protected apps, rules or profiles could not be read.
  /// Nothing sent.
  unavailable,

  /// The probe was not `applied`: native holds other, stricter protection
  /// (or refused the state). The flag was NOT sent; nothing was relaxed.
  blocked,

  /// The flagged send or the document commit failed; the stricter
  /// expected-before state was re-sent without the flag and acknowledged.
  notApplied,

  /// A failure whose recovery could not be confirmed. Never weaker than
  /// unflagged sends allow, but not acknowledged either.
  unknown,
}

/// The result of `ProtectionBootstrap.applyBoundRelaxation`.
final class BoundRelaxationResult {
  const BoundRelaxationResult(this.status, {this.error});

  final BoundRelaxationStatus status;
  final Object? error;

  @override
  String toString() => 'BoundRelaxationResult(${status.name})';
}
