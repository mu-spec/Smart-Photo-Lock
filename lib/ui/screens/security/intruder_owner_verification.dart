// Phase 12 / Milestone 3 — fresh owner verification for intruder settings
// and evidence management.
//
// Same rule as the M2 intruder switches: a one-shot primary PIN/pattern
// verification (biometric refused, no device-credential fallback, normal
// attempt counting and lockout), followed by a FRESH credential status
// re-check — the primary must be unchanged and enrolled and the account
// must not be locked out. Returns the verified method, or null.

import 'package:flutter/widgets.dart';

import '../../../security/credentials/auth_type.dart';
import '../../../security/credentials/credential_manager.dart';
import '../../../security/credentials/credential_state.dart';
import 'app_credential_verification.dart';

Future<AuthType?> verifyIntruderOwner(
  NavigatorState navigator,
  CredentialManager auth, {
  DateTime Function()? now,
}) async {
  final AppCredentialVerificationResult verification =
      await verifyPrimaryAppCredential(navigator, auth);
  if (!verification.isVerified || verification.method == null) return null;
  final AuthType method = verification.method!;
  final CredentialState? fresh = (await auth.status()).valueOrNull;
  final DateTime? lockedUntil = fresh?.lockedOutUntil;
  final DateTime t = (now ?? DateTime.now)();
  if (fresh == null ||
      fresh.primary != method ||
      !fresh.hasEnrolled(method) ||
      (lockedUntil != null && t.isBefore(lockedUntil))) {
    return null;
  }
  return method;
}

/// True while the credential that opened a viewing session is still the
/// enrolled primary and the account is not locked out (per-operation
/// re-check; fail closed on any read failure).
Future<bool> intruderOwnerStillCurrent(
  CredentialManager auth,
  AuthType method, {
  DateTime Function()? now,
}) async {
  final CredentialState? fresh = (await auth.status()).valueOrNull;
  final DateTime? lockedUntil = fresh?.lockedOutUntil;
  final DateTime t = (now ?? DateTime.now)();
  return fresh != null &&
      fresh.primary == method &&
      fresh.hasEnrolled(method) &&
      !(lockedUntil != null && t.isBefore(lockedUntil));
}
