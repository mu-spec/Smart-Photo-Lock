# Phase 1G — Regression Verification

This document is the official Phase 1 regression record: what was verified,
how, and what remains for on-device confirmation.

**Build environment note:** the development sandbox has no Flutter/Android
SDK (by design), so verification is split into two tiers:

| Tier | Where it runs | What it covers |
| ---- | ------------- | -------------- |
| 1 — Automated (static) | Anywhere with Python 3 | Structure, imports, manifests, icons, version consistency, test inventory |
| 1 — Automated (tests) | Your machine (`flutter test`) | Launch, navigation, persistence, security chain, theme, crash-free rendering |
| 2 — Manual | Your device | Install, launch, live navigation, visual theme check, sustained use |

---

## Tier 1a — structural verification (executed in the sandbox ✅)

Run anytime with: `python3 tool/verify_structure.py`

| Check | Result |
| ----- | ------ |
| 128 relative Dart imports resolve | ✅ |
| Brace/paren balance in all 84 Dart files | ✅ |
| pubspec name + version format + all 9 dependency entries | ✅ |
| Android manifests (main/debug/profile) parse as XML | ✅ |
| Main manifest: `allowBackup="false"` (Keystore vault protection) | ✅ |
| Launcher icons present in all 5 densities (10 PNGs) | ✅ |
| Version consistency: pubspec ↔ README ↔ Gradle | ✅ |
| No stale references to removed Phase 1B widgets | ✅ |
| Every feature module has test coverage (8/8) | ✅ |
| Design-system barrel exports every component | ✅ |

## Tier 1b — automated test suites (run on your machine)

```bash
flutter clean
flutter pub get
flutter analyze      # expect: No issues found!
flutter test         # expect: All tests passed!
```

| Suite | Covers |
| ----- | ------ |
| `test/regression/phase1_regression_test.dart` | **launch** (app pumps, MaterialApp carries both themes + system mode), **navigation** (5 tabs forward/back, quick-access tiles), **persistence** (all 5 domains via container), **security chain** (PIN → encrypted settings → verify → tamper rejection), **theme** (light/dark token application), **no crashes** (every tab under both themes, actions tapped) |
| `test/data/*` (5 suites) | preferences, protected apps, security settings, profiles & rules, container wiring |
| `test/security/*` (4 suites) | PIN hashing, secret store, AES-GCM cipher, encrypted settings at rest |
| `test/design_system/*` (6 suites) | buttons, inputs, cards, section titles, status components, themes & scales |
| `test/{rules,protection,utilities}/*` | rule engine, lock sessions, Result type |
| `test/widget_test.dart` | tab shell navigation + quick access |

## Tier 2 — on-device checklist

Run on a real device (Android 7.0+):

```bash
flutter clean
flutter pub get
flutter build apk --debug
flutter install         # with a device connected, or sideload the APK
flutter run             # or launch from the launcher
```

| # | Check | How to verify | Result |
| - | ----- | ------------- | ------ |
| 1 | **Clean build** | `flutter build apk --debug` ends with "✓ Built build/app/outputs/flutter-apk/app-debug.apk" | ☐ |
| 2 | **Install** | APK installs without errors; icon (navy padlock) appears in launcher | ☐ |
| 3 | **Launch** | App opens to Home tab: logo, "Smart App Lock", "Phase 1 Complete" chip, protection status card | ☐ |
| 4 | **Navigation** | Bottom bar switches between Home / Apps / Smart / Security / Settings; app-bar title follows; quick-access tiles on Home jump to their sections | ☐ |
| 5 | **Security tab** | Shows "Protection is not fully set up" banner + 5 control rows (PIN, intruder selfie, break-in alerts, stealth mode, uninstall protection), all "Not set"; "Set up PIN" shows the coming-soon snackbar | ☐ |
| 6 | **Theme** | Toggle device light/dark mode: app switches between white-ish surfaces (light) and brand navy (dark); text stays readable in both | ☐ |
| 7 | **Persistence** | (Verified by test suites in Tier 1b; on-device persistence becomes user-visible with Phase 2+ features) | ☐ n/a |
| 8 | **No crashes** | Rapid tab switching, light/dark toggling, and leaving the app open for several minutes produce no crashes/ANRs | ☐ |
| 9 | **Logs** | `adb logcat` shows no unhandled exceptions while exercising the app | ☐ |

### Defect log

| # | Defect | Severity | Status |
| - | ------ | -------- | ------ |
| — | None found at handoff | — | — |

Any defect you find on-device gets logged here (or in a GitHub issue) and
fixed before Phase 2 begins.

---

# Phase 2L — Authentication Regression

Executed by `test/regression/authentication_regression_test.dart` — one
suite, nine scenarios, over a shared encrypted store so successive manager
instances behave exactly like successive app processes.

| # | Scenario | What it proves |
| - | -------- | -------------- |
| 1 | Correct PIN | 4 & 6 digit auth; `AuthSuccess(type: pin)`; success resets the failure counter |
| 2 | Incorrect PIN | `AuthFailure(wrongCredential)` with decreasing remaining attempts; wrong-length rejected; missing credential → `noCredentialEnrolled` |
| 3 | Cooldown | threshold → `AuthLockedOut` (~30s, streak 1); correct PIN blocked during cooldown; escalation 30s → 60s; post-cooldown success resets attempts + streak |
| 4 | Correct pattern | auth succeeds; **direction-independent** (reversed drawing unlocks) |
| 5 | Incorrect pattern | `AuthFailure` counted; patterns share the PIN lockout state |
| 6 | Biometric success | `AuthSuccess(type: biometric)`; resets counters |
| 7 | Biometric failure | counted as a failed attempt; 3 failures → shared lockout |
| 8 | Biometric cancellation | **fails closed and counts** — local_auth returns `false` on user-cancel (indistinguishable from rejection), and counting prevents cancel-loop bypass; repeated cancels reach the lockout |
| 9 | Process recreation | fresh manager over the same store: credentials still verify, attempt counters/lockouts/streak survive, all settings (randomized keypad, pattern visibility, biometric options) survive, and the persisted document stays encrypted with no raw PIN bytes |

Design notes recorded for the record:

- Biometric capability checks (`isSupported`) are **not** authentication
  attempts — they never touch the counter.
- Opt-in gate: biometric authentication without configured
  `biometricOptions` returns `notConfigured`.
- The raw PIN is absent from the persisted store across restarts
  (`enc:v1:` ciphertext only).
