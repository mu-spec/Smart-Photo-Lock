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
| 4 | Correct pattern | auth succeeds with the **exact ordered sequence**; reverse and reordered drawings are rejected |
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

---

# Phase 2J QA — Physical Device Biometric Verification

Automated tests (unit/regression) are green; this milestone additionally
requires manual verification on a real Android phone with biometrics
enrolled.

| # | Test | Steps | Expected |
| - | ---- | ----- | -------- |
| 1 | Biometric success | Enable biometric unlock → trigger authentication → authenticate | Smart App Lock reports success |
| 2 | Wrong biometric | Use an unrecognized fingerprint where retry is allowed | Remains locked |
| 3 | Cancel | Open the system prompt, cancel it | No authentication success |
| 4 | Reopen prompt | Cancel once, then authenticate again | Prompt opens normally; success works |
| 5 | Disable biometrics | Remove enrolled biometrics in Android settings, reopen the app | App reports biometric unavailable gracefully, no crash |
| 6 | PIN/Pattern fallback | With biometrics configured, use the PIN/pattern path | PIN/Pattern still authenticates normally |

How to run: `flutter build apk --debug --target-platform=android-arm64`,
install on the device, then walk the table and log any deviation here.

| # | Defect | Severity | Status |
| - | ------ | -------- | ------ |
| — | None found at handoff | — | — |

---

# Phase 3H — Apps Management Device QA

After installing the APK on a real device:

| # | Test | Steps | Expected |
| - | ---- | ----- | -------- |
| 1 | Large list load | Open the Apps tab on a device with many packages | List appears promptly; scrolling is smooth with no jank |
| 2 | Fast scroll | Fling through the whole catalog repeatedly | No exceptions in logcat; rows render correctly at the bottom |
| 3 | Search latency | Type progressively ("wha" → "whats") | Results update per keystroke without visible lag |
| 4 | Filter scale | Switch All → Protected → Unprotected with 100+ protected apps | Instant switch; counts correct |
| 5 | Bulk at scale | Select all across the full catalog, bulk Protect, restart the app | No ANR; all selections persist after restart |
| 6 | Icons under load | Scroll quickly; icons for off-screen rows load lazily | No stutter from icon decoding; placeholders flash briefly at worst |

| # | Defect | Severity | Status |
| - | ------ | -------- | ------ |
| — | None found at handoff | — | — |

---

# Phase 4G — Permission Regression (grant / deny / revoke)

Automated suite: `test/regression/permission_regression_test.dart` —
the permission lifecycle exercised end-to-end through the production
app wiring (router + AppScope + capability monitor + real screens).
The system settings screen is simulated via the mutable static
services; `inactive → resumed` lifecycle transitions simulate returning
to the app. Run with `flutter test`.

## Automated scenarios

| # | Path | Scenario | Expected |
| - | ---- | -------- | -------- |
| 1 | Deny | All three capabilities off at launch | Security rows show `Needed` ×3; no revocation banner |
| 2 | Deny | All three off on the setup screen | `0 of 3 ready`; three `Action Required` rows; no `Enabled` labels |
| 3 | Deny | Usage access flow: explain → settings → return without granting | Explanation shown; settings request fired once; still `not granted` after return; row stays `Action Required` |
| 4 | Deny | Accessibility flow: disclosure → settings → return without enabling | Prominent disclosure + "not used elsewhere" shown; settings request fired; row stays `Action Required` |
| 5 | Deny | Overlay flow: disclosure → settings → return without granting | Single-use disclosure shown; settings request fired; row stays `Action Required` |
| 6 | Grant | Enable all three in system settings, return | Setup screen `3 of 3 ready`, all `Enabled`; Security rows `Granted`/`Enabled`/`Enabled`; no banner |
| 7 | Grant | Grant usage access inside its flow | Screen flips to the granted state; `Done` returns → row `Enabled`, `1 of 3 ready` |
| 8 | Grant | Grant accessibility inside its flow | Same for the accessibility row |
| 9 | Grant | Grant overlay inside its flow | Same for the overlay row |
| 10 | Revoke | Revoke usage access | Banner + attention dot; usage row back to `Needed`; other rows untouched |
| 11 | Revoke | Revoke accessibility | Detected and flagged; row back to `Needed` |
| 12 | Revoke | Revoke overlay | Detected and flagged; row back to `Needed` |
| 13 | Revoke | One revocation among three | Setup screen `2 of 3 ready`; only the revoked row `Action Required` |
| 14 | Revoke | Revoke then re-grant | No duplicate alert; setup screen recovers to `3 of 3 ready`, all `Enabled` |
| 15 | Revoke | Revocation made while backgrounded | Guard's resume probe detects it; banner appears on return |

## Phase 4G QA — Physical Device Permission Walk-through

After installing the APK on a real device:

| # | Test | Steps | Expected |
| - | ---- | ----- | -------- |
| 1 | Deny everything | Fresh install → Security → App lock permissions | All three rows `Needed`; no alert banner |
| 2 | Deny summary | Open "Set up" | `0 of 3 ready`; three `Action Required` rows |
| 3 | Deny usage flow | Tap Usage access → Open Settings → deny/back | Explanation screen; system settings open; returning keeps `Action Required` |
| 4 | Deny accessibility flow | Tap Accessibility → disclosure → Open Settings → leave off | Disclosure screen; settings open; returning keeps `Action Required` |
| 5 | Deny overlay flow | Tap Draw over apps → disclosure → Open Settings → leave off | Same as above |
| 6 | Grant usage access | Enable "Smart App Lock" in Usage access settings → return | Flow shows "Usage access enabled"; row flips to `Enabled`; `1 of 3 ready` |
| 7 | Grant accessibility | Enable the service in Accessibility settings → return | "Accessibility enabled"; row `Enabled`; `2 of 3 ready` |
| 8 | Grant overlay | Enable "Allow display over other apps" → return | "Draw over apps enabled"; row `Enabled`; `3 of 3 ready` |
| 9 | Full green | Security tab after all grants | Rows show `Granted`/`Enabled`/`Enabled`; no banner |
| 10 | Revoke usage access | System settings → revoke usage access → return to app | Alert banner "A permission was revoked"; row back to `Needed`; dot on the section |
| 11 | Revoke accessibility | Revoke the service → return | Banner; accessibility row `Needed` |
| 12 | Revoke overlay | Revoke draw-over-apps → return | Banner; overlay row `Needed` |
| 13 | Review action | Tap "Review permissions" | Opens the setup screen showing the revoked row as `Action Required` |
| 14 | Re-grant recovery | Re-enable the revoked capability → return | Setup screen recovers to `3 of 3 ready`; no duplicate banner |

| # | Defect | Severity | Status |
| - | ------ | -------- | ------ |
| — | None found at handoff | — | — |

---

# Phase 5A — Foreground App Detection

Automated suites: `test/protection/foreground_app_monitor_test.dart`,
`test/services/installed_apps_service_test.dart`,
`test/services/accessibility_service_test.dart`.

| # | Path | Scenario | Expected |
| - | ---- | -------- | -------- |
| 1 | Usage stats | Foreground package resolved by the backend | One `ForegroundAppChange` (source: usageStats); `currentPackage` updated |
| 2 | Usage stats | Same package polled repeatedly | No duplicate transitions |
| 3 | Usage stats | Switch chat -> maps -> chat | Three transitions in order |
| 4 | Usage stats | Probe returns null (usage access missing) | No transition, fail-closed |
| 5 | Accessibility | Window-state events relayed via EventChannel | Results carry the reported package names |
| 6 | Accessibility | Same package reported twice | Deduplicated to one transition |
| 7 | Accessibility | Channel errors / no native handler | `Result.failure` events; monitor ignores them |
| 8 | Merged | usage-stats then accessibility then usage-stats | One chain, sources attributed per transition |
| 9 | Merged | Same package via the OTHER source | Not a new transition |
| 10 | Lifecycle | start() polls periodically | Baseline probe + one probe per interval tick |
| 11 | Lifecycle | start() twice | Idempotent — no second poll cycle |
| 12 | Lifecycle | stop() cancels the timer | No further polls; no pending-timer failure |

How to run: `flutter test`, then `flutter build apk --debug --target-platform=android-arm64`
for on-device checks (5A has no UI surface yet — detection is exercised
through the next phase's lock engine).

---

# Phase 5B — Detection Diagnostics

Automated suites: `test/ui/detection_diagnostics_test.dart`,
`test/protection/foreground_app_monitor_test.dart` (diagnostic-counter
group).

| # | Scenario | Expected |
| - | -------- | -------- |
| 1 | Usage-stats detection while the screen is open | Package shown as current + one log entry per switch |
| 2 | Accessibility events | Package logged with the `a11y` source pill |
| 3 | Many apps in sequence | Log accumulates newest-first; header count matches |
| 4 | Clear action | Log empties and shows the empty state |
| 5 | Stop/Start toggle | Status pill flips; monitor `isRunning` follows |
| 6 | Counter readout | Probe/null/event/failure counters reflect the monitor |
| 7 | No container in scope | Graceful degradation message |
| 8 | Monitor counters | Probes, nulls, a11y events, failures counted; failed probes never detect |
| 9 | Timer hygiene | Screen dispose stops the monitor — no pending timers |

Device QA (Phase 5B is explicitly a device exercise):

| # | Test | Steps | Expected |
| - | ---- | ----- | -------- |
| 1 | Primary path | Grant Usage Access → open diagnostics → open 5+ different apps, returning each time | Each app logged as `usage` |
| 2 | Null-probe state | Revoke Usage Access → watch the counters | Null-probe counter climbs; nothing fabricated |
| 3 | Fallback path | Enable Accessibility → repeat the app-hopping | Events logged as `a11y` |
| 4 | Both paths | Both capabilities on | Transitions from either path, deduplicated |

---

# Phase 5C — Protected-App Matching

Automated suites: `test/protection/protected_app_matcher_test.dart`,
`test/ui/detection_diagnostics_test.dart` (match-pill scenarios).

| # | Scenario | Expected |
| - | -------- | -------- |
| 1 | Protected package matched | `protected`, `isProtected == true` |
| 2 | Unknown package matched | `notProtected` |
| 3 | Protection removed mid-session | Decision flips protected → notProtected live |
| 4 | Empty / blank package | `notProtected` (never protected) |
| 5 | Repository failure | `unknown` — the matcher never guesses |
| 6 | `matchChange` | Consumes a `ForegroundAppChange` directly |
| 7 | Diagnostics pill (protected) | Current package shows `Protected` |
| 8 | Diagnostics pill (unprotected) | Current package shows `Not protected` |

Device QA: on the diagnostics screen, protect an app on the Apps tab,
then switch to it and back — the pill must read `Protected`; switch to
an unprotected app — `Not protected`.

---

# Phase 5D — Basic Lock Trigger

Automated suites: `test/protection/default_access_controller_test.dart`,
`test/protection/lock_trigger_test.dart`, `test/ui/lock_challenge_test.dart`,
`test/services/overlay_service_test.dart` (updated).

| # | Scenario | Expected |
| - | -------- | -------- |
| 1 | Unprotected app evaluated | `allow` |
| 2 | Protected app, no session | `challenge` |
| 3 | `grantAccess` then re-evaluate | `allow` for that package only |
| 4 | Session expiry (2 min window) | `challenge` again |
| 5 | `clearSessions` | Every window revoked |
| 6 | Repository failure | `challenge` (fail-closed) |
| 7 | Protected app becomes active (monitor) | One `LockRequired` |
| 8 | Unprotected app becomes active | Nothing emitted |
| 9 | Session open | Requirement suppressed |
| 10 | Accessibility path | Also drives the trigger |
| 11 | Switch away + back | New requirement per transition |
| 12 | start/stop/idempotence | Pipeline halts on stop |
| 13 | Full app: protected app active | PIN unlock challenge presented |
| 14 | Correct PIN | Screen pops; session granted; no immediate re-lock |
| 15 | Wrong PIN | Challenge stays; error shown |
| 16 | Pattern-only user | Pattern unlock screen |
| 17 | No credential enrolled | No challenge (fail-safe) |
| 18 | Failed bring-to-front | No challenge presented |
| 19 | Overlay bridge | show/hide report native results; static counters |

Device QA: protect WhatsApp on the Apps tab, enroll a PIN, then open
WhatsApp — Smart App Lock must come to the front and ask for the PIN.
A correct PIN lets WhatsApp open without re-prompting for 2 minutes.
