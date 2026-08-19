/// Validation result for a candidate PIN.
enum PinValidation {
  /// PIN satisfies the policy.
  valid,

  /// PIN has fewer digits than allowed.
  tooShort,

  /// PIN has more digits than allowed.
  tooLong,

  /// PIN contains characters other than digits 0-9.
  invalidCharacter,
}

/// Configurable PIN strength rules used by the pin-setup phase.
class PinPolicy {
  const PinPolicy({required this.minLength, required this.maxLength});

  /// Sensible default: 4-6 digit PIN.
  static const PinPolicy defaults = PinPolicy(minLength: 4, maxLength: 6);

  final int minLength;
  final int maxLength;

  /// Validates a candidate PIN against this policy.
  PinValidation validate(String pin) {
    if (pin.length < minLength) {
      return PinValidation.tooShort;
    }
    if (pin.length > maxLength) {
      return PinValidation.tooLong;
    }
    if (!RegExp(r'^\d+$').hasMatch(pin)) {
      return PinValidation.invalidCharacter;
    }
    return PinValidation.valid;
  }

  /// Human-readable message for each validation outcome.
  String messageFor(PinValidation result) => switch (result) {
        PinValidation.valid => 'OK',
        PinValidation.tooShort => 'PIN must be at least $minLength digits',
        PinValidation.tooLong => 'PIN must be at most $maxLength digits',
        PinValidation.invalidCharacter => 'PIN may contain digits only',
      };
}
