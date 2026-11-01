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

---

# Phase 5E — PIN Integration

Automated suites: `test/services/installed_apps_service_test.dart`
(launchApp), `test/protection/default_access_controller_test.dart`
(lockout), `test/ui/lock_challenge_test.dart` (gate behavior).

| # | Scenario | Expected |
| - | -------- | -------- |
| 1 | launchApp native success/failure | Result maps; args carry the package |
| 2 | launchApp static recording | Calls + launchedPackages + failure flag |
| 3 | Active lockout + protected app | `deny` (Phase 5E) |
| 4 | Active lockout + unprotected app | `allow` (lockout is irrelevant) |
| 5 | Expired lockout | Back to `challenge` |
| 6 | Correct PIN on protected app | Session granted + app LAUNCHED |
| 7 | Wrong PIN | Challenge stays; no launch |
| 8 | Cancelled challenge | No launch, no session; re-challenge next time |

Device QA: protect WhatsApp, open it, enter the PIN — WhatsApp must
open automatically. Fail the PIN three times — the next open shows the
countdown and WhatsApp cannot be reached until it ends.

---

# Phase 5F — Pattern Integration

Automated suites: `test/ui/lock_challenge_test.dart` (pattern gate +
primary routing), `test/protection/default_access_controller_test.dart`
(pattern lockout).

| # | Scenario | Expected |
| - | -------- | -------- |
| 1 | Pattern-only user challenged | PatternUnlockScreen, no PIN screen |
| 2 | PIN then pattern enrolled (primary=pattern) | PatternUnlockScreen |
| 3 | Pattern then PIN enrolled (primary=PIN) | PinUnlockScreen |
| 4 | Correct pattern | Session + challenge dismissed + app launched |
| 5 | Wrong pattern | Challenge stays; no launch |
| 6 | Cancelled pattern challenge | No launch; next activation re-challenges |
| 7 | Three wrong drawings | Shared lockout trips; protected app denied |

Device QA: enroll ONLY a pattern, protect WhatsApp, open it — the
pattern grid must appear; draw it correctly and WhatsApp opens
automatically; draw it wrong and WhatsApp stays blocked.

---

# Phase 5G — Biometric Integration

Automated suites: `test/ui/pattern_unlock_screen_test.dart` (biometric
group), `test/ui/lock_challenge_test.dart` (biometric group).

| # | Scenario | Expected |
| - | -------- | -------- |
| 1 | Biometric not enrolled | No biometric key on either unlock screen |
| 2 | Enrolled (PIN challenge) | `pin_key_biometric` appears |
| 3 | Enrolled (pattern challenge) | `pattern_key_biometric` appears |
| 4 | Biometric success (PIN) | Challenge pops; session granted; app launched |
| 5 | Biometric success (pattern) | Same on the pattern surface |
| 6 | Biometric failure | Challenge stays; app blocked; error shown |
| 7 | Pattern screen biometric failure | Screen stays; "Biometric failed" shown |

Device QA: enroll biometric unlock in Security, protect WhatsApp, open
it — the challenge shows the fingerprint option; authenticate and
WhatsApp opens automatically; cancel the prompt and the app stays
locked.

---

# Phase 5H — Successful Unlock Session

Automated suites: `test/protection/lock_session_test.dart`,
`test/protection/default_access_controller_test.dart`,
`test/ui/lock_challenge_test.dart`.

| # | Scenario | Expected |
| - | -------- | -------- |
| 1 | `LockSession.refresh` | Expiry slides; original instance unchanged |
| 2 | Allowed re-entry refreshes the window | Session expiry moves to now+2min |
| 3 | Use past the ORIGINAL expiry (refreshed) | Still allowed — no re-prompt |
| 4 | 2+ min inactivity | Challenge again; session pruned from map |
| 5 | Real transition re-entry (widget, clocked) | No challenge within window |
| 6 | Clocked inactivity beyond window (widget) | Challenge returns |

Device QA: unlock WhatsApp, keep using it (switch away/back within
2 minutes) — no re-prompt. Leave it idle for 2+ minutes and return —
the challenge asks again.

---

# Phase 5I — Authentication Failure

Automated suites: `test/ui/lock_challenge_test.dart` (session proofs),
`test/ui/pin_unlock_screen_test.dart` (enroll-does-not-unlock).

| # | Scenario | Expected |
| - | -------- | -------- |
| 1 | Correct PIN | Session granted (positive control) |
| 2 | Wrong PIN | No session; app blocked; challenge stays |
| 3 | Wrong pattern | No session |
| 4 | Cancelled challenge (PIN) | No session; re-challenge next activation |
| 5 | Cancelled challenge (pattern) | No session |
| 6 | Biometric failure | No session |
| 7 | Enroll from recovery view | Unlock route never resolves; entry view appears; back pops false |
| 8 | Lockout (controller) | `deny`; sessions impossible while locked out |

Device QA: open a protected app, fail the credential, verify the app
stays blocked and re-opening it always asks again. From a no-credential
state (fresh install), set up the PIN from the challenge and confirm the
app does NOT open until the PIN is actually entered afterwards.

---

# Phase 5J — Immediate Re-lock

Automated suites: `test/protection/lock_trigger_test.dart` (5J group),
`test/protection/default_access_controller_test.dart` (revokeAccess),
`test/ui/lock_challenge_test.dart` (re-lock flows).

| # | Scenario | Expected |
| - | -------- | -------- |
| 1 | `revokeAccess` after grant | Session removed; evaluate challenges again; unknown package is a no-op |
| 2 | Transition away from a protected app | Session revoked instantly; launcher passes unchallenged |
| 3 | Return to the protected app | Challenge required again (immediate re-lock) |
| 4 | Trigger restart while inside the app | Previous-package seeding still revokes on leave |
| 5 | Widget: unlock -> leave -> return | Challenge appears; session was null after leaving |
| 6 | Widget: 30s after unlock (inside old window) | Leave + return challenges — no grace period |

NOTE: 5J supersedes the 5H re-entry expectations (5H rows 5/6): the
widget tests that asserted "no challenge on re-entry within the window"
were replaced by the immediate re-lock flows above. The controller-level
inactivity window remains as a fallback timeout.

---

# Phase 5K — Screen-Off Re-lock

Automated suites: `test/services/screen_state_service_test.dart`,
`test/protection/lock_trigger_test.dart` (5K group),
`test/protection/default_access_controller_test.dart` (revokeAllAccess),
`test/ui/lock_challenge_test.dart` (screen-off flows).

| # | Scenario | Expected |
| - | -------- | -------- |
| 1 | Native payload relay | screen_off/screen_on map to enum values |
| 2 | Unknown payload / channel error | `Result.failure` — never fabricated |
| 3 | Static service | Emits + counts screen states |
| 4 | Screen-off event | Every session revoked; pending marker set once |
| 5 | Screen-on event | Nothing revoked; no pending marker |
| 6 | `revokeAllAccess` | All windows cleared; both apps challenge again |
| 7 | Widget: screen-off then resume | Session gone; protected app challenged again |
| 8 | Widget: resume without screen-off | No challenge; session intact |

Device QA: unlock WhatsApp, press the power button to turn the screen
off, wake the phone, return to Smart App Lock — the challenge must
appear again for WhatsApp.

---

# Phase 5L — Grace Period

Automated suites: `test/protection/default_access_controller_test.dart`
(grace group), `test/data/lock_settings_repository_test.dart` (grace
group), `test/ui/security_screen_test.dart` (grace UI),
`test/ui/lock_challenge_test.dart` (grace flow).

| # | Scenario | Expected |
| - | -------- | -------- |
| 1 | Grace 30s: leave then re-enter within | Allowed; marker consumed |
| 2 | Grace 30s: leave then re-enter after | Challenge; session pruned |
| 3 | Grace zero | Immediate re-lock (5J default) |
| 4 | Screen-off with grace configured | Still immediate (never softened) |
| 5 | Repository default | Zero |
| 6 | Repository round-trip / negative clamp / corrupt value | 30s/1m round-trip; negative→0; corrupt→0 |
| 7 | Security tab: select 30 seconds | Persisted AND applied live (session survives a leave) |
| 8 | Widget: leave+return within grace | No challenge |
| 9 | Widget: leave+return after grace | Challenge appears |

NOTE (5H audit fix): the 5H controller tests previously time-travelled
across FRESH controller instances whose session maps were empty — the
refresh and expiry assertions now use ONE controller with a mutable
clock, testing what they claim.

---

# Phase 5L — Audit Hardening

Reconciliation audit after both implementations of 5L converged on
`origin/main` (the pushed implementation was adopted; these fixes close
the gaps found in review).

| # | Scenario | Expected |
| - | -------- | -------- |
| 1 | Shrink grace while a deadline is pending (5m → 30s) | Deadline clamps to now+30s; return past it challenges |
| 2 | Shrink grace to zero while away | The away session re-locks immediately (no lingering on the inactivity window) |
| 3 | clearSessions with a pending grace | Session AND deadline cleared; evaluate challenges |
| 4 | Trigger layer with grace | Leaving keeps the session; returning within grace emits no new requirement |

Notes:

- `setGracePeriod` previously only cleared pending deadlines when
  zeroed — a shrunk grace left stale deadlines alive. Now shrunk
  deadlines clamp, and zeroing also revokes the sessions that were
  "away" under those deadlines.
- `clearSessions` (manual lock) now clears grace deadlines as well —
  previously a stale deadline could survive it.
- A trigger-layer grace test was added (the full-app widget test covers
  the same path end to end; this one pins the controller assertions at
  the trigger layer).

---

# Phase 5M — Home-Button Hardening

Automated suites: `test/ui/lock_challenge_test.dart` (5M group).

| # | Scenario | Expected |
| - | -------- | -------- |
| 1 | Home press while the challenge is up | Challenge dismissed; no session; no launch |
| 2 | Re-open the protected app after Home | Challenge re-presents (requirement not dropped) |
| 3 | Return to the app | Challenge stays presented; correct PIN grants + launches exactly once |
| 4 | Requirement during a challenge (second app) | Re-queued; re-presents after the first closes |
| 5 | Cancel the re-presented challenge | No session/launch for the second app |

Device QA: unlock WhatsApp and let the challenge show, press Home —
the challenge disappears. Open WhatsApp again — Smart App Lock comes
back to the front with the challenge (never opens WhatsApp unlocked).
While a challenge is up, open another protected app, unlock the first —
the second app's challenge appears immediately.

---

# Phase 5N — Back-Navigation Hardening

Automated suites: `test/ui/lock_challenge_test.dart` (updated 5E/5F/5M
cancel tests + the re-present flows).

| # | Scenario | Expected |
| - | -------- | -------- |
| 1 | Back on the PIN challenge | Challenge re-presents; no session; no launch |
| 2 | Repeated back presses | Challenge persists across presses |
| 3 | Correct PIN after back | Loop ends; session granted; app launched |
| 4 | Back on the pattern challenge | Same behavior for the pattern surface |
| 5 | Back on a re-presented queued challenge (Maps) | Challenge stays; Maps never launched |
| 6 | Home press during challenge (regression) | Still dismisses; re-challenges on return |

NOTE: the 5E/5F "cancelling the challenge" tests were UPDATED — the old
behavior (challenge pops and the app UI is exposed) was the very bypass
5N closes; the tests now assert the hardened re-present behavior with
the same security invariants (no session, no launch).

---

# Phase 5O — Recents Hardening

Automated suites: `test/services/overlay_service_test.dart`
(setSecureWindow), `test/ui/lock_challenge_test.dart` (5O group).

| # | Scenario | Expected |
| - | -------- | -------- |
| 1 | setSecureWindow wire format | Flag relayed; native false → failure |
| 2 | Static secure toggle | State + call count recorded |
| 3 | Challenge up | secureWindow true |
| 4 | Lock loop ends (correct PIN) | secureWindow false; session granted |
| 5 | Tap OUR task in recents | Interrupted challenge re-presents; secure stays armed; PIN ends the loop |
| 6 | Tap PROTECTED app task while backgrounded | Challenge returns; no session; no launch; secure re-armed |

Device QA: open a protected app so the challenge shows, press Recents —
the Smart App Lock thumbnail is blank. Tap the protected app's task —
the challenge comes straight back. Tap Smart App Lock's own task — the
challenge is still there. Swipe Smart App Lock away from recents and
relaunch — everything is locked again (in-memory sessions die with the
process).

---

# Phase 5P — Gesture Navigation Hardening

Automated suites: `test/ui/lock_challenge_test.dart` (5P group).

| # | Scenario | Expected |
| - | -------- | -------- |
| 1 | Cancelled home-swipe (inactive→resumed) | Challenge stays; secure armed; no extra bring-to-front |
| 2 | Notification shade ×2 | Challenge untouched |
| 3 | Completed home-swipe (inactive→paused) | Dismissed; no session; re-challenges on resume |
| 4 | `hidden` lifecycle state | Counts as a real leave |
| 5 | Edge-back gesture | Re-presents (5N); secure armed; no session |
| 6 | Cancel-then-complete sequence | Re-presented; only the PIN ends the loop; single launch |

NOTE: the `pressHome` test helper now models the real Android sequence
(inactive → paused); the previous immediate `inactive` dismissal was the
flicker/race this phase removes.

Device QA: with a challenge up — swipe up for home and LET GO WITHOUT
LEAVING: the challenge must stay, no flash. Pull the notification shade:
no change. Complete the home-swipe: the challenge dismisses; return and
it re-presents. Edge-swipe from the left on the challenge: it bounces
back to the challenge, never exposing the app.

---

# Phase 5Q — Rapid Switching

Automated suites: `test/protection/default_access_controller_test.dart`
(5Q group), `test/protection/lock_trigger_test.dart` (5Q group),
`test/ui/lock_challenge_test.dart` (5Q group).

| # | Scenario | Expected |
| - | -------- | -------- |
| 1 | Controller: 3 rapid leave/re-enter cycles (immediate grace) | Every re-entry challenges |
| 2 | Controller: 3 rapid cycles inside grace (10s apart) | Every re-entry allowed; post-grace return challenges |
| 3 | Trigger: 5 rapid emissions (P→U→P→U→P) | Exactly 3 ordered requirements, launcher silent |
| 4 | Trigger: grace-window rapid cycles (clocked) | No new requirement inside grace; one after expiry |
| 5 | Widget: rapid storm while challenge up | One challenge screen at all times; no extra bring-to-fronts; unlock ends loop without double challenge; secure clears |
| 6 | Widget: 3 grace cycles + post-grace return | No challenges inside grace; exactly one after |

Device QA: with WhatsApp protected and a challenge up, spam the
recents/home gestures between WhatsApp and the launcher — the challenge
never doubles up. With a 30-second grace, hop WhatsApp → launcher →
WhatsApp repeatedly — no prompts within the window; the first return
past 30 seconds prompts once.

---

# Phase 5R — Screen Off/On

Automated suites: `test/protection/lock_trigger_test.dart` (5R group),
`test/ui/lock_challenge_test.dart` (5R group).

| # | Scenario | Expected |
| - | -------- | -------- |
| 1 | Wake into a protected app | Requirement fires immediately (no resume) |
| 2 | Wake into an unprotected foreground | Nothing |
| 3 | Screen-on without a prior screen-off | Nothing (existing 5K test extended) |
| 4 | Widget: unlock -> sleep -> wake | Session revoked; challenge presented on wake |
| 5 | Widget: sleep/wake while a challenge is up | Exactly one challenge; PIN ends it |
| 6 | Widget: three rapid sleep/wake cycles | One challenge; no grants; PIN ends the storm |

Device QA: unlock WhatsApp, turn the screen off, turn it back on —
WhatsApp must NOT appear unlocked: the challenge comes up right away
(or the instant Smart App Lock is reachable on devices restricting
background activity launches). Repeat the off/on cycle rapidly — the
challenge never doubles up.

---

# Phase 5S — Reboot Recovery

Automated suites: `test/regression/reboot_recovery_test.dart`,
`test/protection/lock_trigger_test.dart` (5S group).

| # | Scenario | Expected |
| - | -------- | -------- |
| 1 | Cold start with a protected foreground | Requirement at the baseline (no transition needed) |
| 2 | Warm restart with a valid session | Baseline stays quiet |
| 3 | Cold start with an unprotected foreground | Quiet |
| 4 | Protected list across a fresh stack over the same DB | Protected app challenges; others allow |
| 5 | Grace period across the same DB | Restored (30s) |
| 6 | ACTIVE lockout after reboot | Correct PIN still `AuthLockedOut` |
| 7 | EXPIRED lockout after reboot | Correct PIN authenticates |
| 8 | Credentials after reboot | Persisted; correct verifies, wrong fails |

NOTE: 5R test 3 ("wake enforcement without a screen-off stays quiet")
was updated: it now grants a session first (warm start), because the 5S
baseline enforcement correctly challenges a cold start with a protected
foreground.

Device QA: unlock WhatsApp, reboot the phone, open WhatsApp first —
it opens unlocked (Smart App Lock is not running yet; this is the
"where Android allows" boundary). Now open Smart App Lock — from this
moment WhatsApp is locked again: returning to it challenges.

---

# Phase 5T — Process Recreation

Automated suites: `test/regression/process_recreation_test.dart`.

| # | Scenario | Expected |
| - | -------- | -------- |
| 1 | Sessions + grace deadlines across recreation | Gone; fresh stack challenges (fail-closed) |
| 2 | Persisted grace setting | Restored; a fresh grace cycle works |
| 3 | Credentials + active lockout | Both survive; correct PIN still blocked while active |
| 4 | Widget: kill mid-challenge, recreate | Challenge re-presents; PIN grants + launches exactly once |
| 5 | Widget: kill after unlock (grace set) | First contact challenges — the dead grace window is never extended |
| 6 | Widget: queued Maps requirement, kill, recreate | Challenge targets MAPS (re-derived, not replayed) |
| 7 | Widget: window-flag reset + resume | FLAG_SECURE re-armed while the challenge is up |

Device QA: open WhatsApp so the challenge shows, force-stop Smart App
Lock from recents (or enable "Don't keep activities" and background
it), then reopen Smart App Lock — the challenge must be back (or the
instant WhatsApp is opened again), never an unlocked shell. With a
challenge up, background + return — the recents thumbnail stays blank.

---

# Phase 5U — Core Lock Regression (LOCK ENGINE COMPLETE)

The complete lock-engine QA gauntlet:
`test/regression/lock_engine_regression_test.dart` — 12 end-to-end
scenarios through the PRODUCTION wiring (monitor → matcher →
controller → trigger → host → router → unlock screens).

| # | Gauntlet scenario | Verdict |
| - | ----------------- | ------- |
| 1 | Protect → challenge → correct PIN → launch → leave re-locks → unlock again | ✅ full cycle |
| 2 | Wrong PIN | ✅ blocked (no session, no launch) |
| 3 | Back ×4 | ✅ challenge persists every time |
| 4 | Home + re-open | ✅ re-challenges; never opens unlocked |
| 5 | Recents task switch | ✅ challenge returns; no unlocked pass |
| 6 | Cancelled gestures ×2 | ✅ challenge untouched; no extra bring-to-front |
| 7 | Rapid P→U→P storm | ✅ one challenge; no stacking; no launch |
| 8 | Sleep/wake | ✅ wake re-challenges; no unlocked reveal |
| 9 | Grace window (30s) | ✅ quick returns pass; post-grace re-locks |
| 10 | Pattern gate | ✅ wrong blocked; correct grants + launches |
| 11 | Process death mid-challenge | ✅ recovers locked over persisted stores |
| 12 | No credential | ✅ fail-safe; nothing bricks; nothing grants |

**CRITICAL CHECKPOINT: PASSED** — ordinary protected-app access
cannot reproducibly bypass authentication. Every surface re-presents
or re-challenges; no bypass grants a session or launches a protected
app.

## Phase 5 device QA — the complete walk-through

| # | Test | Steps | Expected |
| - | ---- | ----- | -------- |
| 1 | Core cycle | Protect WhatsApp, set a PIN, open WhatsApp | Challenge appears; correct PIN opens WhatsApp automatically |
| 2 | Wrong credential | Fail the PIN 3 times | Countdown lockout; WhatsApp unreachable until it ends |
| 3 | Back | Press Back repeatedly on the challenge | Challenge stays every time |
| 4 | Home | Press Home on the challenge, re-open WhatsApp | Challenge returns; never opens unlocked |
| 5 | Recents | Challenge up → Recents | Smart App Lock thumbnail blank; tapping WhatsApp's task re-challenges |
| 6 | Gestures | Swipe-up and cancel; edge-back | Challenge stays / bounces back; never exposes the app UI |
| 7 | Rapid switching | Spam WhatsApp ↔ launcher | One challenge, never stacked |
| 8 | Screen off/on | Unlock, power off, power on | Challenge on wake (or the moment the app is reachable) |
| 9 | Grace | Set 30s delay; hop apps within it, then past it | No prompts inside grace; one prompt after |
| 10 | Reboot | Unlock, reboot, open WhatsApp, then Smart App Lock | Locked from the moment Smart App Lock runs again |
| 11 | Process kill | Challenge up → force-stop → reopen | Challenge back immediately |

| # | Defect | Severity | Status |
| - | ------ | -------- | ------ |
| — | None found at handoff | — | — |

Known boundaries (documented, not defects): until the overlay lock
window lands, the challenge appears inside Smart App Lock itself
(bring-to-front), and on devices restricting background activity
launches the challenge presents the instant Smart App Lock becomes
visible. The watcher foreground service (background detection while
Smart App Lock is not running) is a later phase.

> **Superseded by the final manual QA round (end of this file).** The
> 5U checkpoint above was established by simulated tests, not device
> evidence. Walk-through row 11 is not a valid process-death test:
> Android Force Stop leaves protection unavailable until recovery
> (documented platform limitation).

---

# Phase 5 — Deep Audit (5A–5U)

Full-stack audit of every Phase 5 layer: interfaces, implementers,
test fakes, the host state machine, the trigger queue, controller
semantics, Kotlin bridges, and every test's timing assumptions.

## Findings fixed

| # | Severity | Finding | Fix |
| - | -------- | ------- | --- |
| 1 | High | **Queue-wedge risk**: the 5Q processing chain (`_processing.then(...)`) had no error handling — one throwing transition would error the chain and silently skip ALL subsequent transitions (fail-open). | Every chain link now swallows its error (`.catchError`), so the pipeline always continues (fail-closed). |
| 2 | Medium | **Ordering gaps**: screen events (5K/5R) and the startup baseline (5S) ran OUTSIDE the ordered queue, so a departure could interleave with a screen-off or a startup transition. | Screen events and the baseline now flow through the same serialized queue. |
| 3 | High | **Compile break**: `process_recreation_test.dart` called `departureAtFor(...)`, which did not exist on the adopted controller. | Added the `departureAtFor` diagnostic getter (mirrors `sessionFor`). |
| 4 | Medium | **Stale grace deadline after grant**: `grantAccess` left a pending grace deadline for the package, which a later evaluation could consume. | A fresh grant now clears the package's grace deadline. |
| 5 | High | **Test-logic bug (3 suites)**: the "return past the grace" tests emitted the departure and the return in the same tick — the departure re-armed a FRESH grace, so the return was inside it and the challenge assertion could never hold. | Each test now flushes the departure at the earlier clock before advancing time (real semantics). |

## Verified correct (spot-checked layer by layer)

- Interface contracts: all 8 interfaces fully implemented by every
  production impl AND every test fake (including `launchApp`,
  `getForegroundPackage`, `setSecureWindow`, `events`).
- Host state machine: synchronous `_presenting` claim, re-queue vs
  re-present vs defer branches, double-pop guards, secure-window
  arming/clearing — traced through all 5M/5N/5O/5P/5Q/5R/5T paths.
- Trigger: FIFO queue, previous-package seeding, baseline enforcement,
  screen-off/wake handling, drain-on-stop.
- Controller: grace arming/consumption/shrink-clamp/zero-revoke,
  inactivity refresh, pruning, lockout deny, fail-closed unknown.
- Kotlin: ScreenStateChannel registration flags + unregister guard;
  OverlayStatusChannel FLAG_SECURE on the UI thread; usage-stats probe
  total/fail-closed; accessibility sink thread-safe.
- 5H tests: single controller with a mutable clock (verified).

---

# Phase 5 — Compile Repair #1

Fifty analyzer issues traced to six root causes, all repaired:

| # | Root cause | Fix |
| - | ---------- | --- |
| 1 | `AppContainer._` referenced `accessClock` (an `inMemory`-only parameter) from the private constructor body | The clock seam is now threaded through `AppContainer._({DateTime Function()? accessClock})` + a `_accessClock` field; production passes null (wall clock), tests inject the fake |
| 2 | The audit's queue-tail rewrite accidentally dropped `LockTrigger.isRunning` and `LockTrigger.dispose` | Both restored (real lifecycle: `dispose = stop + close stream`; `isRunning = _started`) |
| 3 | Automated test edits inserted `test(...)` blocks inside the `_FailingRepository` class in `default_access_controller_test.dart` | The 5L/5Q/audit tests moved back inside `main()`; the class stands alone after it |
| 4 | `MockStreamHandlerEventSink.error` is a NAMED-parameter API (`code:` required) in Flutter 3.47; two tests passed 3 positional args | Both call sites migrated to `events.error(code: ..., message: ...)` |
| 5 | `drawPattern` was declared after its call sites inside `main()` (Dart local functions are not hoisted) | The helper now sits at the top of `main()` in `lock_engine_regression_test.dart` and `lock_challenge_test.dart`; the scrambled test/class layout in the latter was rebuilt cleanly (37 tests in main, `_FakeBiometricService` after it) |
| 6 | Minor dead code | Removed the unused `access_controller.dart` import in `lock_trigger_test.dart`, the unused `returnToApp` helper in `lock_engine_regression_test.dart`, and the write-only `_tick` field in `detection_diagnostics_screen.dart` |

---

# Phase 5 — Fix #1 (analyzer/compilation)

Two root causes behind the analyzer cascade, repaired:

| # | Root cause | Fix |
| - | ---------- | --- |
| 1 | The previous rebuild of `lock_challenge_test.dart` dropped the shared harness (`pumpApp`, `openApp`, `protect`, `sessionFor`) from `main()` and left a stray copy inside `_FakeBiometricService` — every test's helper references were undefined | The helper block was moved back to the TOP of `main()` (before `drawPattern` and all 37 tests); the class now contains only its own members |
| 2 | One 5Q test passed a stale `gracePeriod:` named parameter to the `DefaultAccessController` constructor (the production API applies grace via `setGracePeriod`) | The stale parameter was removed; the test now constructs the controller then calls `setGracePeriod(const Duration(seconds: 30))` |

Verified after the fixes:

- Every helper called by the lock-challenge tests is defined in `main()`
  (called set == defined set).
- `gracePeriod:` appears nowhere as a production constructor argument
  (the remaining hits are the gauntlet's `pumpApp`/`boot` helper
  parameters, which route to `setGracePeriod`).
- No `test()`/`testWidgets()` sits inside a class anywhere in `test/`.

---

# Phase 5 — Fix #2 (ForegroundAppMonitor only)

Root cause: the accessibility/merged tests emitted fallback events
through the static service WITHOUT starting the monitor — the monitor
only subscribes to the accessibility stream inside `start()` (the
production trigger starts it at app boot), so unlistened broadcast
events were dropped: fallback tests saw 0 events, the merged chain lost
its accessibility event, and the accessibility counter under-counted.

Fixes:

- The four affected tests now call `monitor.start()` before emitting
  (matching production semantics; the baseline probe sees no foreground
  package and emits nothing).
- `dispose()` hardened: idempotent (`_disposed` guard), and the
  periodic timer is cancelled SYNCHRONOUSLY first — a dispose racing an
  in-flight stop can never leave the timer alive; the stream closes
  exactly once.
- `start()` after `dispose()` now fails loudly (StateError) instead of
  silently pretending to monitor.
- New lifecycle tests: repeated start/stop cycles keep detection
  working; double dispose is safe; start-after-dispose throws; and a
  testWidgets proof that disposing from the running state cancels the
  periodic timer (framework pending-timer check) with no further polls.

---

# Phase 5 — Fix #2B (foreground monitor hang)

Exact cause of the hang, finally pinned:

`pumpEventQueue()` in this file resolves to **test_api's** helper
(flutter_test re-exports it from `package:test_api/scaffolding.dart`),
whose loop awaits `Future<void>.delayed(Duration.zero)` — a REAL
timer-based await. Inside `testWidgets` the test body runs in the
FakeAsync zone, where real timers only fire when the fake clock is
advanced by the test framework. Nothing advanced it during that await,
so the lifecycle `testWidgets` hung until the test timeout (and the
aborted pump left the follow-on "Guarded function conflict").

Fix: inside the two `testWidgets` bodies the flush is now
`await tester.pump()` (zero-duration) — it flushes the microtasks that
deliver broadcast-stream events WITHOUT advancing the periodic poll
timer, keeping the probe-count assertions exact. The plain `test()`
bodies keep `pumpEventQueue()` (real event loop — safe there).

---

# Phase 5 — Mobile QA Fix #1 (protected apps opened unlocked)

Root cause: the entire detection/challenge pipeline runs in the Flutter
isolate; when Smart App Lock was backgrounded, Android froze or killed
the isolate — usage-stats polling stopped, the accessibility
EventChannel listener detached, and nothing presented a challenge.

Superseded by the C0 hybrid recovery fix. The watcher foreground service
(`specialUse`, per capabilities.md) is now an enforcement fallback, not only a
process anchor:

- Native `WatcherService` (START_STICKY, low-importance notification,
  usage polling and accessibility reports) + `WatcherChannel`
  (configuration, heartbeat, pending challenge, and health).
- Manifest: FOREGROUND_SERVICE + FOREGROUND_SERVICE_SPECIAL_USE +
  POST_NOTIFICATIONS, `<service android:foregroundServiceType=
  "specialUse">` with the Play special-use property.
- `ProtectionBootstrap` persists only enabled state and protected package
  names; `LockChallengeHost` heartbeats while Dart is healthy and hands back
  to native recovery on teardown without disabling desired protection.
- A native opaque overlay shield blocks touches before `MainActivity` is
  launched and remains until the Flutter challenge is ready.
- Notification permission is optional. Accessibility is the earliest native
  detector; Usage Access is a slower recovery fallback and cannot guarantee
  first-frame concealment by itself.
- Diagnostics: logcat tag `SmartAppLock` (native probes + a11y events);
  assert-based Dart prints (monitor/trigger) and kDebugMode prints
  (challenge host) — stripped in release.
- Verifier: watcher channel-wiring + manifest declarations guarded
  (25 checks).

Device verification (logcat):
  adb logcat -s SmartAppLock SmartAppLockWatcher flutter
Then: open Smart App Lock (watcher notification appears) -> Home ->
open a protected app -> expect `a11y foreground -> <pkg>` or
`usage stats foreground -> <pkg>` then `LockTrigger: <pkg> ->
challenge` and the challenge screen. Force-stop remains an Android platform
boundary: Android suppresses app components until the user launches the app
again. Ordinary process death and task removal are covered by native recovery
and must be device-tested.

---

# Phase 5 — QA Fix #2 (regressions from the mobile pipeline fix)

Genuine regressions/robustness issues found and repaired:

| # | Issue | Fix |
| - | ----- | --- |
| 1 | `DetectionDiagnosticsScreen` read `AppScope` during `dispose()` (walking a deactivated element) | The container is now captured in `initState` (`_container`); `dispose()` and the monitor-ownership check use the captured reference — no BuildContext/AppScope access during teardown |
| 2 | Lifecycle helpers emitted ILLEGAL transitions (`inactive -> paused`, `paused -> resumed`); the 3.47.0 state machine requires the `hidden` step (paused legal only from hidden/null; resumed legal only from inactive/hidden/null) | `pressHome` now walks inactive -> hidden -> paused; `returnToApp` climbs paused -> hidden -> inactive -> resumed (state-tracked, same-state steps skipped); the regression gauntlet's `pressHome` updated identically |
| 3 | The accessibility/screen-state channel-error tests used arbitrary 50 ms real-timer delays | Replaced with the deterministic `pumpEventQueue()` flush (no arbitrary delays) |

Verified clean:
- Every remaining raw `handleAppLifecycleStateChanged` sequence in the
  suite is legal (all others are `inactive -> resumed`).
- The host still stops the trigger + watcher on teardown (timer
  cancellation remains synchronous); the capability guard stops the
  capability monitor.

---

# Phase 5 — QA Fix #3A (lock challenge host dispose)

Root cause: the watcher stop added to `LockChallengeHost.dispose()`
read `AppScope.read(context)` during teardown — walking a deactivated
element ("Looking up a deactivated widget's ancestor is unsafe").

Fix: the host now captures the `AppContainer` ONCE in `initState`
(`_container`) and dispose() uses only that cached reference:
`_subscription.cancel()`, `_trigger.stop()` (which synchronously
cancels the monitor's 1-second timer), and `unawaited(container
.watcher.stop())`. Every other AppScope read remains in
mounted-guarded handlers. Ownership is unchanged: the host starts the
trigger + watcher, and stops exactly those resources.

---

# Phase 5 — QA Fix #3B (lock trigger timer teardown)

Root cause: `LockTrigger.stop()` cancelled the monitor LAST — after
awaiting the subscription cancels and the processing-queue drain. The
host's dispose calls `_trigger?.stop()` fire-and-forget, so those
awaits suspended the function before the monitor's 1-second periodic
timer was ever cancelled: every widget test ended with a pending timer.

Fix: `LockTrigger.stop()` now stops the MONITOR FIRST — and the
monitor's own stop body has no awaits (its timer cancel executes
synchronously during the call). An unawaited stop() from a dispose path
therefore kills the periodic timer immediately, before any suspension
point; the subscription cancels and the queue drain follow. Ownership
is unchanged: the host starts the trigger, stops it on dispose;
repeated stop/dispose stay idempotent.

Also cleaned the two analyzer infos in lock_challenge_test.dart:
`_lifecycle` -> `lifecycle`, `_transition` -> `transition` (local
identifiers must not carry leading underscores).

---

# Phase 5 — QA Fix #3C (real app-leave challenge dismissal)

Root cause: Flutter 3.47 disables frame rendering while the app
lifecycle is `hidden`/`paused` (SchedulerBinding sets framesEnabled
false, so `scheduleFrame()` becomes a no-op), and the automated test
binding's `pump()` only renders `if (hasScheduledFrame)`. When the host
dismissed the challenge on a REAL leave (hidden/paused), the pop's
route-removal could never visually complete in the frozen state — the
PinUnlockScreen stayed mounted and every dismissal assert failed.

The host behavior is production-correct: a real device's paused window
renders nothing, and the removal completes on the next rendered frame.
The fix is test-side only: the `pressHome` helpers (both suites) now
climb back UP to `inactive` — the first frames-enabled backgrounded
state — before settling, so the dismissal pop renders exactly like a
real device's next frame. The "hidden state counts as a real leave"
test uses the same climb-back via the shared `transition` helper.
Semantics preserved: the leave still happens on hidden/paused, the host
still considers the app backgrounded at inactive, no session is ever
granted, and returning re-presents the challenge.

---

# Phase 5 — QA Fix #3D (protected-app Recents return re-challenge)

Root cause: `ForegroundAppMonitor`'s cross-source dedupe drops any
report whose package equals the LAST-KNOWN foreground. When Smart App
Lock was covered by Recents, the intermediate foreground (task
switcher / launcher blip) could be invisible to BOTH detection paths —
a sub-second pass slips past the 1-second usage-stats poll and emits no
accessibility window event. The protected app returning through its
Recents task was then reported as the SAME package and silently
swallowed: no `ForegroundAppChange`, no `LockRequired`, no challenge —
the protected app was exposed (fail-open).

Fix (production, fail-closed): `ForegroundAppMonitor` gains
`invalidateCurrentPackage()`, which marks the last-known package
stale. The FIRST report after invalidation is emitted as a fresh
transition even when it carries the identical package; the flag is
consumed by that report (null probes never consume it — they are not
observations), and dedupe resumes afterwards. `LockChallengeHost` calls
it on EVERY real leave (`hidden`/`paused` — the one shared leave path):
any real leave breaks detection continuity, and re-evaluation can
never produce a false challenge because the access controller still
honors live sessions and grace periods. Transient `inactive` (shade,
cancelled gestures) never invalidates. No UI test was changed; four
monitor unit tests cover the new API. This also repairs the same
latent path in the regression gauntlet (Home + re-open / Recents task
switch).

---

# C0 physical QA fix #1 — protected-app flash-through

Observed sequence: protected app content became readable before the native
shield, followed by the PIN challenge.

Root cause:

1. `AccessibilityLockService` deliberately waited up to 100 ms before Android
   delivered a window-state event.
2. `WatcherService` discarded that native event whenever the Dart heartbeat
   was healthy.
3. The event then crossed into Dart, waited for asynchronous matching/session
   evaluation and widget scheduling, and only afterward requested the shield.
4. UsageEvents is a polled history query and necessarily observes the resumed
   activity after the transition; it cannot guarantee first-frame concealment.

Fail-closed repair:

- Accessibility notification batching is zero.
- The native accessibility callback evaluates the protected package before
  relaying the event to Dart and never waits for heartbeat expiry.
- A zero-sized, invisible, non-interactive overlay stays pre-attached while
  protection is configured and expands synchronously for a protected event.
- Pending challenge state remains latched through rendered/resumed Flutter
  handoff and is consumed only by exact successful authentication or a
  detector-confirmed safe transition away.
- Correct authentication is the sole source of a process-local native package
  authorization. Authorization occurs before shield removal and target launch;
  failure revokes both Dart and native sessions.
- Immediate/grace policy is synchronized to native enforcement. Screen-off
  revokes both layers, and native authorizations never survive process death or
  reboot.
- Recent Accessibility events remain authoritative over contradictory stale
  UsageEvents reports; duplicate events are throttled without delaying the
  first shield.

Deterministic coverage: watcher channel serialization, native authorization
ordering, pending-latch semantics, detector arbitration, immediate/grace
behavior, screen-off revocation, duplicate challenge suppression, and static
source-order guards. Actual compositor/event timing remains physical-device QA.

---

# C0 physical QA fix #2 — screen-off/wake deadlock

Reproduction before the fix: authenticate a protected app, turn the display
off, wake and unlock. The native shield remained indefinitely because the only
active launch attempt ran at `SCREEN_ON` behind keyguard; there was no
`USER_PRESENT` recovery, no independent retry, and an already-alive Flutter
host consumed native pending state only during initial bootstrap.

Regression coverage now includes:

- `WakeRecoveryGateTest`: distinct screen-on/user-present attempts, duplicate
  broadcast coalescing, retry cadence, and repeated screen cycles.
- `ProtectionAccessStateTest`: authorization revocation plus exact,
  single-consumption challenge handoffs and stale generation rejection.
- `lock_challenge_test.dart`: an existing MainActivity reconstructs a pending
  wake ticket without a new detector event, and screen-off replacement does
  not stack routes or accept the old handoff generation.
- watcher/overlay bridge tests: package + generation wire format and failure
  behavior.

JVM/widget tests cannot reproduce Android keyguard policy, OEM background-start
restrictions, or compositor ordering. The full screen-off/wake sequence and the
shield's `Return to Home` escape require the physical-device checklist.

---

# C0 physical QA fix #3 — exact task wake recovery

The previous recovery path retained a pending ticket in the reproduced case,
which is why the native shield appeared, but treated a non-throwing
`startActivity` call as if `MainActivity` had resumed. `MainActivity` has an
empty task affinity for task-hijacking hardening, so `NEW_TASK` plus
`REORDER_TO_FRONT` could not reliably identify and raise its existing task.
No lifecycle acknowledgement followed and Flutter never pulled the ticket.

Recovery now stores a separate non-secret wake package, reconstructs a missing
pending ticket on both `SCREEN_ON` and `USER_PRESENT`, and promotes the exact
live Activity task by task ID. A package/generation recovery intent covers cold
start and `onNewIntent`; Flutter still removes the shield only after a resumed,
rendered challenge acknowledges the exact ticket. `Return to Home` clears only
the active wake target/pending presentation after Home is detector-confirmed;
it does not authorize the package or alter protected-app configuration.

---

# C0 physical QA fix #4 — unresolved challenge survives wake

When screen-off occurred while the PIN route was already visible, screen-on
could resume `MainActivity` behind keyguard while Flutter still considered the
old route active. Flutter adopted the fresh screen-off generation and sent a
ready acknowledgement. Native checked only `activityResumed`, cleared pending,
and hid the shield. A trailing hidden/paused callback then removed the old
route, leaving the dashboard with no native ticket for `USER_PRESENT`.

Ready acknowledgement is now a visual shield handoff, not consumption of the
authentication requirement. Native keeps the exact package/generation pending
until successful authorization, rejects ready while keyguard is locked, and
skips duplicate recovery only when the exact route is both ready and resumed.
If the old route is removed during the wake lifecycle storm, resume/heartbeat
finds the still-pending ticket and reconstructs one route before the shield can
drop. A detector-confirmed transition to an unprotected Home/Recents target may
cancel the unresolved presentation, but never grants access or changes the
protected-app configuration.

---

# Phase 5 / M2 — Final manual QA round: CLOSED WITH LIMITATIONS

Build under test: `main` @ `505dafff8ca62139f1c521fdf92eb9d308d71ee6`
(OD6 + U1-R fix). Device: Oppo CPH2083, Android 9 (ColorOS), release
APK. Device results are as reported by the tester. Automated results
are simulated (JVM / flutter_test) and are not device evidence.

**Round status: CLOSED WITH LIMITATIONS.** Phase 5 is **not** fully
security-verified and **not** production-release-ready. Two release
gates remain open (below): the PRD has no clause permitting their
deferral (every milestone gate: "Implement or verify every
requirement in this milestone").

## Automated evidence @ 505daff (simulated)

| Check | Result |
|---|---|
| Kotlin JVM policy tests | 177 passed |
| Flutter test suite | 993 passed |
| Native type-check (android-all) | PASS |
| `flutter analyze` | PASS (no issues) |
| OD6 / U1-R mutation checks | 6 / 6 killed |

## Device evidence

| Area | Result | Category |
|---|---|---|
| PIN / pattern authentication | PASS | Verified |
| Wrong-credential lockout | PASS | Verified |
| Screen-off / wake | PASS | Verified |
| Home / Recents / Back protection | PASS | Verified |
| Grace expiry after leaving the app | PASS | Verified |
| Rapid app switching | PASS | Verified |
| Accessibility off: Usage Access fallback | PASS | Verified |
| OD6: expired session, Home and quick re-entry | PASS (challenges) | Verified |
| Expired session, observed new Activity | PASS (challenges), supported by logcat | Verified |
| H-2: same-Activity navigation after expiry | No challenge | **Conditionally accepted limitation**: expiry is event-driven, not a strict timer (`docs/architecture.md` §5H) |
| F3: process-death recovery | No verified process death occurred | **UNVERIFIED: release gate** |
| Fingerprint authentication | OS-level enrollment could not be completed | **UNVERIFIED: release gate** |
| Android Force Stop | Protection unavailable while force-stopped, until recovery | **Platform limitation** (`docs/capabilities.md`) |
| Gesture navigation (5P), reboot recovery (5S) | No device result supplied in this round | Not covered this round (device UNVERIFIED) |

Accepted limitation, precisely: after a session expires, a protected
app stays usable without a new challenge while the user stays inside
it, the screen stays on, and the app produces no Accessibility
window-state event (new Activity, dialog or popup) and no new Activity
resume. The first such event, any leave and return, or screen-off
challenges. It is not an entry bypass: entering the app always required
authentication.

F3 detail: `am kill` was denied on Android 9 / ColorOS, the release APK
is non-debuggable and ADB is non-root, so no non-force-stop process
death could be produced. Earlier user-reported restart results predate
the F3 commit and were not logcat-verified
(`docs/phase5_milestone3_process_death_security_audit.md` §16).

## Remaining release gates (before any production release)

1. **F3 process-death recovery on the current build**, logcat-verified:
   `ActivityManager: Process com.smartapplock.app (pid N) has died` (not
   `Force stopping …`), the WatcherService restart, `SmartAppLockWatcher:
   Restart recovery decision=…`, and the challenge shown before protected
   content is usable. This needs a build or device where a non-force-stop
   process death can be produced (for example a debuggable build with
   `run-as`, or a device that permits `am kill`).
2. **Successful biometric authentication** on a device with completed
   fingerprint enrollment: success completes the challenge and opens the
   app; repeated mismatch keeps the PIN/pattern required with no lockout
   reset; cancel or Back stays locked; after screen-off/wake a fresh
   challenge appears.

## Next PRD milestone

Phase 6 — Bypass Hardening, **Milestone 1 — Alternate Entry Paths**:
notification entry, deep links, share intents, widgets and shortcuts.
No open security-critical regression is known; the two Phase 5 release
gates above stay open until verified.

---

# Phase 6 / M1 — Alternate Entry Paths

PRD v2.1, Phase 6 — Bypass Hardening, Milestone 1. Scope, verbatim:
Notification Entry ("Open protected apps from notifications. Verify
authentication."), Deep Links ("Test protected applications launched using
deep links."), Share Intents ("Test protected apps entered through Android
Share."), Widgets & Shortcuts ("Test supported launcher shortcuts/widgets.").
Acceptance gate: implement or verify every requirement; run relevant
automated checks and targeted physical QA; record evidence and unresolved
risks; do not advance while a security-critical regression remains open.

**Status: implemented and verified by simulated tests only. Physical-device
QA for this milestone has not been run** (checklist below). The Phase 5
release gates (F3 process death, successful biometric) remain open and are
not affected by this milestone.

## How alternate entries are enforced

Android delivers every in-scope entry by resuming an Activity of the target
package, often inside the caller's task (share targets, deep links).
Smart App Lock does not and cannot intercept those intents. Enforcement is
entry-agnostic: the resulting window is a foreground report for the
protected package (Accessibility `TYPE_WINDOW_STATE_CHANGED`, or the
UsageEvents `ACTIVITY_RESUMED` fallback), and `WatcherService.reportForeground`
applies the unchanged native policy (`ProtectionAccessState.observeForeground`,
pending ticket, shield, challenge promotion). Only `authorizePackage`
(exact ticket + accepted ready hand-off, after a recorded credential success)
grants. No code path keys on how an app was launched, so no entry path can
create a grant. Code review found no missing enforcement for protected apps.

## Finding fixed: Smart App Lock's own exported Activity accepted external navigation

`MainActivity` is exported (launcher entry). The Flutter embedding, by
default, turns Intent data into a pushed route (deep linking defaults to
enabled) and reads the `route` extra as the initial route. Any installed app,
a shortcut-maker launcher shortcut or `am start` could therefore drive this
app's navigator. Reproduced in simulation before the fix: a deep link pushed
`/diagnostics/detection` above an on-screen lock challenge; a platform
initial route opened `/pin/setup` at cold start. No grant was possible
(credential writes are CR-3-gated; grants need the exact native ticket), so
this was a hardening issue, not an authorization bypass.

Fix: `MainActivity.shouldHandleDeeplinking() = false` and
`getInitialRoute() = "/"` (native boundary); `ExternalRouteGuard` consumes
platform route pushes and `AppRouter.onGenerateInitialRoutes` ignores the
platform initial route (Dart defense in depth). Back (`popRoute`) and
in-app `Navigator` use are unchanged. `ACTION_RECOVER_CHALLENGE` is still
matched against the pending ticket and can only re-raise the shield.

## Pre-commit review finding fixed: launch extras could crash the whole process

Found by source review (Flutter 3.47.7 embedding sources, the workspace
toolchain; the developer build's Flutter version is not pinned). During
`super.onCreate`, `FlutterFragmentActivity` reads caller-controlled extras
from `getIntent()`, and these malformed values throw on the main thread:

- an unknown `cached_engine_id` or `cached_engine_group_id`
  (`IllegalStateException`);
- a `background_mode` that is not an enum name (`IllegalArgumentException`);
- a non-List `dart_entrypoint_args` (`ClassCastException`);
- a disallowed `dart-flags` value (engine `FATAL`, release allowlist; only
  when the engine initializes).

The watcher and the Accessibility service run in the same process, so one
`am start` (or a crafted shortcut) from any app could kill all protection
until restart. Recovery from that restart is the unverified F3 path, and on
Android 10+ a crashed Accessibility service can be left disabled. This is
not an authorization bypass: no grant, route or content results. A physical
user can already Force Stop (a documented platform limitation), but a
crash-on-demand also reaches protection when Settings itself is protected,
and it is available to any installed app.

`background_mode=transparent` exposes nothing: the theme has no
`windowIsTranslucent`. Shell arguments other than `dart-flags`
(`start-paused`, `vm-service-port`, ...) target the Dart VM service, which
release builds do not include. None of this was reproduced on a device.

Fix: `MainActivity.onCreate` replaces `getIntent()` with a rebuilt Intent
before `super.onCreate`, and `onNewIntent` forwards only the rebuilt Intent.
The rebuilt Intent keeps only the action. For `ACTION_RECOVER_CHALLENGE` it
also keeps the two recovery extras, read defensively by `LaunchIntentPolicy`
and still matched exactly by `RecoveryIntentPolicy`; a hostile bundle drops
the hint. No caller data, `route` or embedding extras reach Flutter. The
deep-link and initial-route overrides stay as defense in depth.

## Automated evidence (simulated)

| Check | Result |
|---|---|
| Kotlin JVM policy tests | 194 passed (177 existing + 12 `AlternateEntryPathTest.kt` + 5 `LaunchIntentPolicyTest.kt`) |
| Flutter test suite (full, at implementation) | 1020 passed (993 existing + 27 new), 0 failed, 0 skipped. Not re-run after review |
| Flutter focused set after the pre-commit review | 334 passed, 0 failed (19 files: the M1 test, now 30 tests, plus every suite that pumps `SmartAppLockApp`, CR-3 enrollment, and PIN/pattern/security/permission UI) |
| New Flutter tests | 30 passed (`test/regression/alternate_entry_paths_test.dart`) |
| Native type-check (android-all + Flutter stubs) | PASS (60 classes) |
| `flutter analyze` | PASS (no issues) |
| RED before fix | 7 of 7 group C (own-Activity) tests failed on a7b177e; groups A/B passed (existing enforcement) |
| Mutation checks | 14 / 14 killed (implementation: 3 Dart guard + 3 Kotlin policy; review: 4 launch-sanitizer wiring/policy + 2 more policy + 2 Dart guard lifecycle) |

Covered paths (both the Dart native-contract model and the production Dart
wiring, plus the Kotlin policy): notification tap from Home and heads-up
inside another app, notification action without UI, deep link in the caller
task, ACTION_SEND via the framework chooser, ACTION_SEND_MULTIPLE via the
Android 14+ IntentResolver, launcher shortcut, widget click; rapid mixed
entry storms (one ticket, one challenge, no grant); a stale success after a
different protected entry; entry into protected B from authorized A; grace
is per package and is never extended by other entries; zero-grace shade
re-entry; H-2 same-package semantics unchanged; uncorroborated UsageEvents
cannot revive grace; spoofed recovery intents never match. The Kotlin tests
replay the policy calls of `reportForeground`; `WatcherService` itself is not
executed. None of this is device evidence.

## Known limitations and open items

- **No pre-delivery interception (OS limit).** The target Activity receives
  the intent and may act on it (open a chat, import shared content) before
  the shield covers it; exposure is bounded by detection latency.
- **No Activity, no lock (OS limit).** Notification content and actions that
  open no UI (inline reply, mark-read, media controls) and widget content
  rendered by the launcher are not covered by a foreground lock. Notification
  privacy is PRD Phase 14.
- **Destination after authentication (functional, unchanged).** After success
  the host calls `launchApp` (launcher intent + `NEW_TASK`). For entries that
  run in the caller's task (share, many deep links) this is expected to open
  the protected app's own task instead of returning to the entered screen;
  some notification/shortcut task layouts may also get the launcher Activity
  on top. Never a security issue (authorization is per package); not changed
  in this milestone because changing post-authentication navigation needs
  device validation. Device QA below records the actual behaviour.
- **UNVERIFIED surfaces:** bubbles (Android 11+), full-screen-intent /
  show-when-locked Activities over the keyguard, direct-share targets in the
  chooser, Recents thumbnails of a caller task that holds a protected share
  Activity (Phase 6 M2).
- **Observation for Phase 6 M2 (not changed in M1).** Our own package is
  never a foreground transition (5D design). Own reports are dropped in
  `AccessibilityLockService`, `WatcherService.reportForeground` and the
  UsageEvents selector. So while Smart App Lock's own UI is in front,
  `observeForeground` does not run: no leave is recorded, grace 0 does not
  revoke, and the away clock does not start. Back-navigation between the
  protected task and our task may produce a direct switch with no other
  report. That happens when `launchApp` started the protected app from our
  Activity: Back from its root shows our shell, and Back again may return
  to the protected task. Re-entry would then be allowed without a
  credential. The bound is the unextended session deadline (2 minutes from
  the last same-package observation, no slides while our UI is in front).
  This is not an entry bypass, because it needs a legitimate unlock first.
  Device reachability is UNVERIFIED. It belongs to M2 task-switching
  hardening. **Addressed in Phase 6 / M2 (M2-F1, below).**
- **Destination is never caller-chosen.** The launch-extra sanitizer drops
  data and extras from external intents, so Smart App Lock always opens at
  its shell (or the challenge).

## Physical-device QA required for milestone acceptance

Use a build that contains this change. Each step passes only if all of the
following hold:

- the protected app is challenged before its content is usable;
- wrong credentials do not open it;
- cancel/Back exits to Home;
- correct credentials open it.

Also record where the user lands after success (destination preserved or
not). Report each step separately even when steps are run in one session.
Grace is 0 unless a step says otherwise.

**S1 — Notification entry**
1. Device unlocked on Home: tap the protected app's notification in the
   shade. Enter a wrong PIN, then Back (expect Home). Tap again and enter
   the correct credential.
2. Inside an unprotected app, tap the heads-up notification. Then tap a
   notification repeatedly: expect exactly one challenge and no grant.
3. Use inline reply or mark-read: expect no challenge. Record this as an OS
   limitation (Phase 14).
4. Run this step separately, with a secure keyguard. Turn the screen off,
   tap the notification on the lock screen and unlock the device: expect
   the challenge before content.

**S2 — Caller-task entries (deep link, share)**
1. Deep link from a browser, or
   `adb shell am start -a android.intent.action.VIEW -d <url>`.
2. Gallery → Share (one item) → protected app.
3. Gallery → Share (several items) → protected app.

**S3 — Launcher shortcuts, widget and grace**
1. Use a long-press shortcut and a pinned shortcut, with rapid repeats.
2. Tap the widget. Record whether widget content is visible while locked.
3. Set grace > 0. Authorize via a shortcut and go Home. Re-enter by
   notification inside grace (expect allowed), then after grace (expect a
   challenge). Enter a different protected app inside A's grace (expect a
   challenge).

**S4 — Own-Activity external-intent negatives (mandatory, separate, adb)**

This scenario cannot be combined with S1–S3: it feeds hostile input to
Smart App Lock itself, and any failure is a process death that would
invalidate the other results. It is not F3 evidence.

Before starting, note `adb shell pidof com.smartapplock.app` and clear the
crash log with `adb logcat -b crash -c`. Run every command three times:

- cold: Smart App Lock's task swiped from Recents (do not force-stop);
- warm: app open;
- during a challenge: open a protected app, then run the command while the
  challenge is shown.

Commands (each prefixed with `adb shell am start -n com.smartapplock.app/.MainActivity`):
`-d /pin/setup`, `--es route /pin/setup`, `--es cached_engine_id x`,
`--es cached_engine_group_id x`, `--es background_mode bogus`,
`--es background_mode transparent`, `--es dart_entrypoint_args x`,
`--es dart-flags --bogus`.

Expected for every command:

- only the shell or the challenge is shown, and the window stays opaque;
- `adb logcat -b crash -d` is empty;
- the PID is unchanged, except after a cold swipe-away on OEMs that kill
  the process;
- opening a protected app afterwards is challenged immediately.

---

# Phase 6 / M2 — Task & Configuration Hardening

PRD v2.1, Phase 6 — Bypass Hardening, Milestone 2. Scope, verbatim: Recents
Edge Cases ("Stress-test task switching."), Split Screen ("Test
split-screen/multi-window where relevant."), Rotation ("Test
orientation/configuration changes where supported."). Acceptance gate:
implement or verify every requirement; run relevant automated checks and
targeted physical QA; record evidence and unresolved risks; do not advance
while a security-critical regression remains open.

**Status: implemented and verified by simulated tests only. Physical-device
QA for this milestone has not been run.** It is deferred to the combined
Phase 6 device round after M3 (scenarios S5–S8 below, run together with M1
S1–S4). The PRD gate is not waived: M2 is not accepted until that round
passes. The Phase 5 release gates (F3 process death, successful biometric)
remain open and are not affected by this milestone.

## Findings fixed

**M2-F1 — protected app → Smart App Lock's own UI was not a leave (M1
Concern 3).** The detectors drop our own package (5D: MainActivity also hosts
challenges). A direct switch from an authorized protected app to our UI
therefore never reached `ProtectionAccessState.observeForeground`: grace 0
did not revoke and the grace clock never started, so the return was a
same-package observation (ALLOW, plus an H-2 slide). Reachable in code via
Back from a task that `launchApp` started (our task is the return target),
a split-screen pane, and possibly quick-switch; Recents, the launcher and
System UI were not affected because they are reported. Impact: re-entry
without a credential after a legitimate unlock, bounded by the session
deadline. Device reachability is UNVERIFIED.

Fix: `MainActivity.onResume` → `WatcherService.onOwnUiResumed`
(`OwnUiForegroundPolicy`). With protection enabled and no ticket pending,
the resume is applied as an unprotected foreground change to our own
package: immediate re-lock at grace 0, or the configured grace. Two kinds of
resume are not a leave:

- a resume that hosts a challenge;
- a resume that returns to the fresh grant of the challenge it hosted. Here
  the package whose ticket was pending at the previous pause is the current
  foreground, which only that ticket's exact `authorizePackage` can have
  set. This covers, for example, a system credential screen, and the fresh
  grant survives until `launchApp`.

Final gate: the first version used a boolean "pending at pause" snapshot.
After an abandoned ticket and a grace re-entry into another app, a stale
`true` could suppress that app's leave. The package comparison closes this;
see `staleSnapshotNeverSuppressesTheLeaveOfAnotherApp`. Own-package Accessibility events are still ignored:
Flutter route changes emit window events and would revoke a fresh grant.

**M2-F2 — a challenge in multi-window could release the shield beside a
live protected app.** `markChallengeReady` accepted a hand-off while
MainActivity shared the screen. The `recoverProtected` duplicate guard
(`activityResumed && challengeReady`) also skipped re-covering a protected
app reported in another window. On Android 10+ multi-resume both activities
stay resumed, so the protected app could stay interactable next to the PIN
screen. Device reachability is UNVERIFIED.

Fix (additive, `MultiWindowChallengePolicy`; `ChallengeReadyPolicy` is
unchanged):

- `markChallengeReady` is refused while `Activity.isInMultiWindowMode`. The
  shield stays, showing "Unlock is not available in split screen or a
  floating window. Use full screen, or return to Home."
- Entering multi-window (`onMultiWindowModeChanged`), or resuming in it,
  with a protected ticket pending withdraws the hand-off and re-raises the
  shield.
- The duplicate guard applies only outside multi-window.
- After leaving multi-window the challenge route re-acknowledges the same
  ticket on the metrics change (`didChangeMetrics`), with the existing 1 s
  retry as fallback.

**Rotation / configuration: verified, no change needed.** MainActivity
declares `orientation|screenSize|smallestScreenSize|screenLayout|density|
uiMode|fontScale|locale|...` in `configChanges`. Rotation and multi-window
resizes therefore do not recreate the Activity. The route, ticket, hand-off
and attempt counters stay. An unlisted change recreates the Activity: the
ticket is persisted, the intent is re-sanitized (M1), the host re-presents
the same generation, and a grant still needs the credential plus the exact
ticket.

## Automated evidence (simulated)

| Check | Result |
|---|---|
| Kotlin JVM policy tests | 214 passed (194 existing + 20 `TaskConfigurationHardeningTest.kt`) |
| New Flutter tests | 17 passed (`test/regression/task_configuration_hardening_test.dart`) |
| Existing native-model users (focused) | 175 passed, 0 failed, after the model change (11 files) |
| Flutter test suite (full) | 1040 passed (1023 existing + 17 new), 0 failed, 0 skipped |
| Native type-check (android-all + Flutter stubs) | PASS (62 classes) |
| `flutter analyze` | PASS (no issues) |
| Mutation checks | 13 / 13 killed (Kotlin: 4 policy + 3 wiring; Dart: metrics re-ack, own-UI leave, challenge-return gate, stale snapshot, duplicate guard, multi-window blocker) |

Covered: protected → own UI → protected at grace 0 and grace > 0; pending and
challenge-host resumes are not leaves; Recents/launcher revocation
unchanged; X → Y → X; rapid switching (25×); a multi-window challenge is
refused, keeps the ticket and can never authorize; entering multi-window
withdraws a hand-off; the duplicate guard re-covers in multi-window; metrics
re-ack after leaving multi-window; rotation storm (one route, one generation,
one grant, wrong attempts kept); lockout across rotation; Activity
recreation with the process alive (same ticket, single grant). Kotlin tests
replay policy calls and pin the wiring by static source contracts. Dart tests
drive the production host against the native model. **None of this is
device evidence; real multi-window placement, multi-resume focus and OEM
window modes are not simulated.**

## Known limitations and open items

- **Pane focus changes are invisible (OS limit, Android 10+).** In
  multi-resume, switching focus between panes produces no `onResume` /
  `onPause`. Window events are not guaranteed either. Enforcement relies on
  the multi-window flag and on detector reports of the protected app.
  Window enumeration would need an Accessibility configuration change
  (`canRetrieveWindowContent`, `typeWindowsChanged`), which needs approval.
- **Shield liveness in multi-window.** The shield is a full-display overlay
  (it also covers the divider), so the challenge cannot be completed in
  multi-window. The user leaves split screen (Recents / nav buttons /
  long-press Recents) or taps the shield's existing "Return to Home" (safe
  exit). If the Flutter route closes under the shield, recovery waits for
  the next Activity resume. This is fail-closed and simulated only.
- **Safe exit in multi-window (UNVERIFIED, unchanged mechanism).** Android
  decides where Home goes in split screen (secondary pane on Android 7–11;
  split dismissed on newer versions). If the protected app remains visible
  in a pane after "Return to Home", its authorization is still revoked and
  its next report is challenged. On Android 10+ multi-resume a pane focus
  change may produce no report (see above). S6.4 records this.
- **Leaving multi-window: ordering is unverified.** If Android delivers
  `onMultiWindowModeChanged(false)` and a frame while MainActivity is still
  resumed but already losing its pane to the protected app, the
  re-acknowledgement could release the shield before `onPause`. The next
  protected report re-covers (the duplicate guard needs `activityResumed`).
  This is a platform-timing limitation; S6.1 checks it.
- **Own UI next to an unlocked app.** Opening Smart App Lock beside an
  unlocked protected app revokes that app's authorization. Its pane stays as
  it is until the app is reported again (no lifecycle event); the next
  report is challenged.
- **Not refused at the manifest.** `resizeableActivity="false"` was not set:
  it needs approval, and Android ignores it on large screens (sw ≥ 600 dp)
  for apps targeting SDK 36 (Android 16).
- **UNVERIFIED surfaces:** picture-in-picture of a revoked protected app;
  OEM freeform / pop-up / flexible windows; foldables; Recents thumbnails of
  protected apps (their own content, an OS limitation unless they set
  FLAG_SECURE); quick-switch gestures.
- **Duplicate ticket after an own-UI leave.** A leftover pending ticket is
  re-covered through `foregroundForRecovery` → the host's resume path
  (simulated).

## Physical-device QA required (combined Phase 6 round)

Run after M3 together with M1 S1–S4, on the same build. Grace is 0 unless a
step says otherwise. Each step passes only if all of the following hold:

- the protected app is never usable without a challenge;
- wrong credentials never open it;
- there is no stacked or looping challenge;
- the correct credential opens it once.

Record the device, Android version, OEM skin, navigation mode, and any step
the device does not support.

**S5 — Recents and task switching**
1. Unlock A. Recents → A's card: expect a challenge. Record A's thumbnail
   (OS) and Smart App Lock's thumbnail during a challenge (expected blank:
   FLAG_SECURE).
2. A → Recents → unprotected U → Recents → A: expect a challenge.
3. A → Recents → protected B: expect B challenged; cancel. Recents → A:
   expect a challenge.
4. **(Essential, M2-F1.)** Unlock A from its challenge. Press Back in A
   until Smart App Lock's shell shows, then return to A (Recents, or Back
   again if Android goes back to A): expect a challenge. Repeat with grace
   30 s: expect a return within 30 s allowed, and a challenge after it.
5. Quick-switch gesture or double-tap Recents between A and Smart App Lock,
   and between A and U, 10× fast: expect A never opens without a challenge,
   and no challenge loop after a correct PIN.
6. During a challenge, open Recents and come back. Then swipe Smart App
   Lock's task away during a challenge and reopen A: expect a challenge.
7. If a device credential or biometric is enabled, unlock A with it and
   expect exactly one challenge. This is a record only; biometric stays an
   open Phase 5 gate.

**S6 — Split screen / multi-window (where supported)**
1. **(Essential, M2-F2.)** With A's challenge shown, enter split screen.
   Expect the shield with the split-screen notice in both panes, and A not
   usable. Leave split screen: expect the challenge usable and a correct PIN
   opening A once. Repeat, but leave split screen by dismissing Smart App
   Lock's pane so that A goes full screen: A must be shielded or challenged
   before it responds.
2. **(Essential, Android 10+.)** Split screen with U + Smart App Lock, then
   open A in U's pane: expect the shield and notice. Tap between the panes
   repeatedly and record whether A ever responds.
3. With A unlocked, put A and Smart App Lock side by side. Record whether
   A's pane responds before A is reported again; the next A report must be
   challenged.
4. **(Essential.)** While the multi-window shield is shown, confirm the
   user can always get out (Home, Recents, exiting split). Record any stuck
   state. Then tap the shield's "Return to Home". Record where Home appears
   and whether A stays visible in a pane (including a minimized docked
   pane). Tap A's pane: it must be challenged before it responds. A
   response without a challenge is a security failure; report it.
5. Use OEM freeform / pop-up / flexible window, and picture-in-picture for a
   protected video app: record the behaviour. These are UNVERIFIED surfaces.

**S7 — Rotation and configuration**
1. **(Essential.)** With a challenge shown and auto-rotate on, rotate 5×.
   Expect one challenge, no flash of A's content, the wrong-attempt count
   kept, and a correct PIN opening A once.
2. Reach a lockout, then rotate: expect the lockout to persist.
3. Rotate while drawing a pattern (pattern credential).
4. Change dark mode, font size and display size while a challenge is
   pending: expect the challenge kept and no second challenge.
5. Rotate after unlocking: expect A to stay usable without a re-challenge.
6. Fold and unfold, if the device is foldable.

**S8 — Regression spot-check after M2:** Home and Back from a challenge,
screen off / on with wake re-lock, grace 0 and grace > 0, and M1 S1 step 1.

Essential steps that cannot be simulated: S5.1, S5.4, S6.1, S6.2, S6.4,
S7.1.

---

# Phase 6 / M3 — Background Resilience & Bypass Regression

PRD v2.1, Phase 6 / Milestone 3: Battery Saver ("test Android
battery-saving modes"), Background Restrictions ("test manufacturer /
background restrictions") and Bypass Regression Suite ("document all
supported bypass scenarios and expected behavior"). Detecting and surfacing
restrictions in the UI is PRD Phase 7 / M1 ("Background Restriction
Health"); battery-impact measurement and OEM stress testing are Phase 17.
Neither is implemented here.

Status: **code + SIMULATED evidence; physical-device QA pending (combined
Phase 6 round below). Not device-verified.**

## What background restrictions can stop

| Component | Hosted by | Stopped by | Effect on enforcement |
| --- | --- | --- | --- |
| Accessibility detection (`AccessibilityLockService` → `WatcherService.reportForeground`, process-scoped) | system binding | force stop (disables the service); OEM kill (system re-binds, unverified on ColorOS) | earliest detector gone; usage polling (if running) remains |
| Watcher (`WatcherService`, foreground service): UsageEvents poll, SCREEN_OFF/ON/USER_PRESENT receiver, recovery retry | the service instance | process death (`START_STICKY` restart, F3); AOSP 9+ "Restricted" background usage (FGS removed from the foreground and stopped once idle); OEM power managers (unverified) | screen-off re-lock and wake recovery are native only while it runs; Dart's lock trigger repeats them while the Flutter engine is alive |
| Authorization mirror (`ProtectionAccessState`) | process memory | process death | erased → fail closed |
| Overlay shield | process (WindowManager) | process death, overlay permission revoked | recovery re-arms; challenge still required |
| Boot restart (`ProtectionBootReceiver`) | manifest | force stop; OEM auto-launch denial (ColorOS, unverified) | protection starts when Accessibility binds or the app opens |

Battery Saver (AOSP): defers jobs/alarms, applies background-execution
limits to all apps, cuts background network and may disable location with
the screen off. Smart App Lock uses none of those; foreground services and
bound Accessibility services are not stopped by stock Battery Saver. Doze
only applies with the screen off; SCREEN_ON leaves it. OEM power-saving modes
(ColorOS "Power saving" / "Super power saving") are not documented and are
**UNVERIFIED**.

No battery-optimisation exemption is requested (no
`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, no exemption flow): the PRD does not
require one, and on AOSP an exemption is not documented to lift the
"Restricted" state for foreground services. No wake locks, alarms, WorkManager jobs or extra
keep-alive were added. The pre-existing restart attempt at the end of
`reportForeground` (`if (!isRunning()) start(context)`) is unchanged.

## Finding fixed

**M3-F1 — native sessions outlived a watcher interruption.**
`WatcherService.onDestroy` unregistered the screen receiver and stopped the
poll and retry, but left `ProtectionAccessState` intact. Dart stops the
watcher only after configuring protection off, and the poll calls
`stopSelf()` only when protection is off. So a teardown while protection is
still configured was not requested by the app. Android can stop the
foreground service while the process survives: the bound Accessibility
service keeps it alive. From then until the watcher restarts, a screen-off
no longer revoked native authorizations natively. If the Flutter engine was
also gone, an authorized app (or one in its grace window) was allowed again
on wake. Process death already failed closed (the mirror is not persisted);
this interruption did not.

Fix: `WatcherTeardownPolicy` (pure). `onDestroy` while protection is
configured is `INTERRUPTED`: it revokes every native authorization and grace
window, records `WatcherTeardownPolicy.INTERRUPTED_MESSAGE` as `lastError`
(shown by the Security screen while the engine is unavailable), and keeps
the pending ticket, the ready hand-off and the armed overlay. Accessibility
reports still raise the shield, and only a credential bound to the exact
ticket authorizes again. `onDestroy` with protection off is unchanged
(disarm only). `onStartCommand` clears only that message. Nothing grants,
renews or extends anything.

Reachability is code-level only: whether, and how often, a given device
stops the service while the process lives is **UNVERIFIED** (S10.2). The
cost of fail-closed is that an interrupted session re-challenges on the next
report of the protected app (for example, the next screen inside it).

## Reviewed and unchanged (already implemented)

- **Process death / sticky restart / a11y rebind / boot / Dart start:**
  authorization mirror erased; F3 makes one fail-closed restart decision per
  process (`RestartRecoveryPolicy`, `OneShotLatch`); a persisted ticket
  re-raises the shield. Tests: `RestartRecoveryPolicyTest`,
  `RestartEvidenceAndBootScopeTest`, `process_death_recovery_test.dart`,
  `reboot_recovery_test.dart`.
- **Stale foreground reports:** UsageEvents are subordinate to an
  Accessibility report for 5 s; an uncorroborated protected UsageEvents
  report cannot renew grace or slide H-2 (U1-R); an uncorroborated
  unprotected one cannot prove a leave (U1-C); stale reports cannot complete
  a safe exit. Tests: `UsageLeaveCorroborationTest`,
  `GraceRenewalClosureTest`.
- **Duplicate start / callbacks:** `onStartCommand` removes the poll before
  posting it; tickets keep their generation for repeated reports; the
  restart decision is one per process.
- **Watcher start failure** (for example Android 12+ background FGS start
  refused): caught, `lastError` set, `start()` returns false; Accessibility
  enforcement does not depend on the service. Health reports
  `serviceRunning=false` → Security screen "Protection engine unavailable".
- **Heartbeat loss:** the 6 s lease only selects the health label and
  notification text; it never authorizes.
- **Boot while locked:** the app is not direct-boot aware; BOOT_COMPLETED
  arrives after the first unlock.
- **Permission unavailable** (Usage access, Accessibility, overlay,
  notifications revoked): covered by `permission_regression_test.dart` and the
  health evaluation; no state authorizes.

## Automated evidence (simulated)

| Suite | Tests | Covers |
| --- | --- | --- |
| `android/app/src/test/.../BackgroundResilienceRegressionTest.kt` | 19 | `WatcherTeardownPolicy`; interruption × session, grace, stale UsageEvents, duplicate teardown, rapid transitions; M1 × M3 (deep-link / hostile / stale recovery intent); M2 × M3 (own-UI fresh-grant exception, multi-window, exact hand-off); source contracts (onDestroy/onStartCommand wiring, no exemption/keep-alive/a11y scope change, start-failure reporting); R-M3-2 vulnerable sequence (pre-fix ALLOW), fix (CHALLENGE), watcher-running control, `MainActivity.onDestroy` contract |
| `test/regression/background_resilience_test.dart` | 10 | native model `serviceDestroyed` / `activityDestroyed` (Group A, 7, incl. R-M3-2 and its control) and the production Dart host / lock trigger / Security screen against it (Group B, 3): a still-valid Dart session never substitutes for the credential; Dart's screen-off still revokes both layers while the native receiver is gone; a stopped watcher is restarted from the foreground during a challenge, before any credential |

Mutation checks on the new gates: 16/16 killed (10 Kotlin, 5 Dart incl. the
reachability check on SecurityScreen's `resumed` reload).
These tests run policies, wiring contracts and a Dart model. They do not run
Android, Battery Saver, Doze, App Standby, the Restricted state, ColorOS or a
service stop, and prove none of them.

## Known limitations and open items

- **While the watcher is stopped** (process alive): there is no native
  SCREEN_OFF revocation and no wake ticket. The Dart lock trigger covers
  screen cycles while the Flutter engine is alive. Opening Smart App Lock's
  UI (including every challenge) restarts the watcher from the foreground:
  SecurityScreen reloads on `resumed` and calls `ProtectionBootstrap`.
  **R-M3-2 (closed):** a grant made while the watcher stayed down could
  outlive the engine. The sequence was:
  1. the foreground restart did not take effect;
  2. grace > 0;
  3. the user Backed out of the shell, or the task was removed;
  4. a screen cycle occurred;
  5. the user returned to the app inside grace, and it was ALLOWED.

  `MainActivity.onDestroy` now applies
  `WatcherTeardownPolicy.revokesOnEngineDetach`: with protection on and no
  watcher running, every native session and grace window is revoked when the
  engine goes away. With both rules, no native authorization survives a
  moment in which neither screen-off observer exists.
- **Restricted / OEM-killed background:** enforcement can be delayed or
  missing until Android allows the service again. Detection and UI guidance
  ("Background Restriction Health", `ActivityManager.isBackgroundRestricted`):
  detection is implemented in Phase 7 / M1 (health signal); the dashboard
  and repair guidance are Phase 7 / M2.
- **Force stop** disables protection until the app is opened (see
  `docs/capabilities.md`).
- **Battery Saver / ColorOS power modes:** no code path depends on them; real
  behaviour is UNVERIFIED (S9).
- Phase 5 F3 (process death on device) and biometric remain **UNVERIFIED**.

## Combined Phase 6 physical-device QA matrix (M1 + M2 + M3)

One round, one build containing M1–M3. Step details for S1–S8 are in the M1
and M2 sections above and are not repeated. Grace 0 unless stated. A step
FAILS if the protected app (A) is ever usable without a challenge, a wrong
credential opens it, a challenge stacks or loops, or the user is stuck with
no way out. Evidence is a screen recording unless "logcat" is stated.
Record device, Android version, OEM skin and navigation mode once; mark
unsupported steps N/A with the reason.

**Common pass criterion (✓):** challenge before A's content is usable;
wrong PIN refused; Back/cancel exits to Home; correct PIN opens A once.

### Group 1 — Oppo A9, Android 9 / ColorOS (required)

| ID | Setup | Minimal actions | Expected secure behaviour | PASS / FAIL |
| --- | --- | --- | --- | --- |
| S1.1, S1.2, S1.4 | A has a notification; S1.4 with secure keyguard | tap from shade / heads-up / lock screen; repeat taps | challenge before content, one challenge | ✓; FAIL on any content without challenge |
| S2.1, S2.2 | browser link or `am start -a VIEW -d`; gallery share | open A via link / share | challenge before A acts visibly | ✓ (record if A acted before the shield: M1 limitation) |
| S3.1, S3.3 | launcher shortcut; grace 30 s for S3.3 | shortcut ×5 fast; grace in/out | one challenge; inside grace allowed, after grace challenged, other app challenged | ✓ |
| S4 | adb; note PID; `logcat -b crash -c` | 8 hostile `am start` commands × cold / warm / during challenge | shell or challenge only; opaque | crash log empty, PID unchanged (logcat + `pidof`) |
| S5.1, S5.2, S5.4, S5.5, S5.6 | A unlocked | Recents return; via U; Back to shell then return (also grace 30 s); 10× quick switch; swipe our task during challenge | challenge every return; grace honoured; no loop | ✓; S5.4 essential |
| S6.1, S6.4 | ColorOS split screen if offered | challenge in split; leave split; Return to Home | shield + notice in split; no unlock in split; A pane challenged before responding | FAIL if A responds without challenge; N/A if no split screen |
| S7.1, S7.2, S7.4 | challenge shown | rotate 5×; lockout + rotate; font/dark mode | one challenge, attempts kept, lockout kept | ✓ |
| S8 | — | Home/Back from challenge, screen off/on, grace 0 / 30 s | unchanged Phase 5 behaviour | ✓ |
| S9.1 | Battery Saver ON (ColorOS power saving) | open A; wrong then correct PIN; screen off 30 s, on | challenge; wake re-challenges | ✓ |
| S9.2 | Battery Saver ON, A unlocked in front | screen off ≥ 15 min still (Doze), wake, unlock keyguard | challenge before A content; record seconds to shield | ✓; FAIL if A usable |
| S9.3 | Battery Saver ON | 10 min in other apps, then open A from Recents and from a notification | challenge; record whether the Smart App Lock notification is still shown | ✓ |
| S9.4 | A's challenge shown | toggle Battery Saver on/off | challenge kept, no grant, no second challenge | ✓ |
| S10.1 | protection on, A locked | swipe Smart App Lock from Recents (do not force stop); open A | challenge; record whether the notification returns and Accessibility stays on | ✓; FAIL if A opens unlocked while Accessibility is still enabled |
| S10.2 | Settings → Battery → Smart App Lock: background restriction ON / "Allow background activity" OFF | unlock A; use A ≥ 3 min with screen changes; screen off/on; then open Smart App Lock | A re-challenged (never silently open) after the service stops; wake challenges; Security screen shows unavailable/limited or the service restarts | ✓; logcat: `Stopping service due to app idle` / `WatcherService destroyed` |
| S10.2c (R-M3-2) | as S10.2, grace 30 s | after the service stopped: unlock A; Back to the shell; Back again (shell closes); screen off/on within 30 s; open A | A challenged (grace does not survive) | FAIL if A opens without a challenge; logcat `WatcherService destroyed` before the unlock, and no `Native protection watcher started` before the screen cycle |
| S10.4 | ColorOS auto-launch allowed, then denied | reboot, unlock keyguard, open A (before opening Smart App Lock) | challenge in both cases, or record "unprotected until app opened" when denied | FAIL only if Accessibility is on and A opens unlocked |
| S10.6 | A unlocked | revoke Usage access; then revoke overlay; reopen A | Usage off: Accessibility still enforces. Overlay off: no grant, Security screen unavailable | FAIL if any revocation opens A |
| S11 | Battery Saver ON, after one S10.1 swipe | once each: S1.1, S2.1, S3.1, S5.4, S6.1, S7.1 | as each step | ✓ for all |

### Group 2 — Android 10+ (multi-resume; second device)

| ID | Setup | Minimal actions | Expected | PASS / FAIL |
| --- | --- | --- | --- | --- |
| S6.1, S6.2, S6.3 | split screen U + Smart App Lock / A + Smart App Lock | open A in a pane; tap between panes; side by side after unlock | shield + notice; A never responds unchallenged; next A report challenged | FAIL if A responds |
| S1.4, S9.2 | secure keyguard; Battery Saver ON | lock-screen notification; long idle wake | challenge before content | ✓ |
| S10.2b | Android 12+: battery "Restricted" | as S10.2; also reboot | as S10.2; record any `ForegroundServiceStartNotAllowedException` (logcat) and the Security screen message | as S10.2 |
| S10.5 | Android 13+: notification permission denied | open A, screen cycle | still enforced; Security shows reduced resilience | ✓ |

### Group 3 — App-dependent (record N/A when the app lacks the surface)

| ID | Surface | Expected |
| --- | --- | --- |
| S1.3 | inline reply / mark-read | no challenge; OS limitation (Phase 14) — record |
| S2.3 | multi-item share | challenge before A's content |
| S3.1 pinned, S3.2 | pinned shortcut, widget | challenge on entry; record widget content visibility (launcher-rendered, not covered) |
| S2.1 variants | app links of the specific protected app | challenge before content |

### Group 4 — Unsupported / OEM-dependent (record only; not a release blocker unless content is exposed while protection reports healthy)

| ID | Surface | Record |
| --- | --- | --- |
| S6.5 | PiP, OEM freeform / pop-up windows | whether A is usable unchallenged |
| S7.6 | foldables | challenge kept across fold |
| S10.3 | Force stop (Settings or phone manager) | protection off until reopened; Accessibility disabled by Android — expected platform limitation |
| S10.4 denied | ColorOS auto-launch denied | unprotected until Accessibility binds or the app opens |
| ColorOS super power saving | restricted launcher mode | whether protected apps are reachable at all; behaviour |

### Group 5 — Phase 5 open gates (stay UNVERIFIED unless run and passed)

| ID | Setup | Minimal actions | Expected | PASS / FAIL |
| --- | --- | --- | --- | --- |
| F3 | debuggable build (`run-as`) or a device that permits `am kill`; A unlocked in front | non-force-stop process death (release gate 1 above); force stop and S10.1 swipe are not F3 | challenge before A is usable again | logcat: `has died` (not `Force stopping`), watcher restart, `Restart recovery decision=…` |
| Biometric / S5.7 | fingerprint enrolled and enabled | release gate 2 above: success, repeated mismatch, cancel, screen-off/wake | success opens A once; mismatch keeps PIN/pattern, no lockout reset; cancel stays locked | as release gate 2; stays open until passed |

Minimum to accept M3 code on device: S9.1, S9.2, S10.1, S10.2, S10.2c, S11 on the
Oppo, plus S10.2b on Android 12+ if available. Minimum for Phase 6 overall:
those plus the M2 essentials (S5.1, S5.4, S6.1, S6.2, S6.4, S7.1) and S4.

# Phase 7 / M1 — Protection Health engine & signals

PRD v2.1, Phase 7 / Milestone 1: Health Engine Foundation (Secure /
Attention Required / Protection Offline), Required Capability Health,
Protection Engine Health, Background Restriction Health, Biometric Health.
Design: `docs/architecture.md` (Phase 7 / M1). Signals:
`docs/capabilities.md` (Protection Health signals). Dashboard and repair UI
are M2; refresh on return from Settings and the health regression round are
M3. Not implemented here.

## Automated evidence

| Suite | Tests | Evidence level | Covers |
| --- | --- | --- | --- |
| `test/protection/health/protection_health_engine_test.dart` | 30 | production code (pure Dart) | three states and stable ids; precedence and deterministic ordering; revoked vs not set up vs user choice; detection paths (Accessibility bound, usage needs watcher); watcher interruption with reason; shield pre-arm; notifications; background restriction incl. API < 28 unsupported; Battery Saver advisory; biometric never affects state; UNKNOWN per core signal; staleness boundary, future-dated snapshot, stale never upgrades OFFLINE; setup vs no-protected-apps vs interrupted categories; detection-offline cause (not granted / revoked / not running); native enforcement disabled → OFFLINE, unreadable → UNKNOWN; exhaustive 3^9 combinations: SECURE iff all core signals positive, OFFLINE only from a definite negative; recovery to SECURE |
| `test/protection/health/protection_health_monitor_test.dart` | 17 | production Dart over simulated services | SECURE on a healthy simulated device; observational (no start/stop/configure/heartbeat/authorize/revoke, ticket kept, no shield call, no biometric prompt, no grant-history write); setup vs no-protected-apps causes; saved configuration with native enforcement disabled → OFFLINE; watcher interruption → restart; capability revoked → regranted; Accessibility enabled but unbound; native bridge failure; failed probe; hung probe timeout; coalesced refresh; `latest()` staleness without probing; restriction + Battery Saver; biometric enrollment removal as a change event; wire format (legacy map → UNKNOWN; method-channel parse); container wiring has no side effect |
| `android/app/src/test/.../ProtectionHealthSignalsTest.kt` | 11 | production Kotlin + source contracts | API-28 gate (API never touched below P); failing reads → UNKNOWN; exact wire keys and Dart parser coverage; Accessibility bind lifecycle; `onServiceConnected`/`onUnbind`/`onDestroy` wiring; health read forbids authorize/revoke/ticket/shield/start/stop/configure/heartbeat/exemption calls; `isArmed()` pure read; no new permission, exemption or enrollment intent |

Mutation checks: 14/14 killed (10 Dart: staleness, Accessibility bound
state, usage-needs-watcher, UNKNOWN severity, biometric severity,
restriction UNKNOWN, grant-history write, fabricated probe value, watcher
start from health, change dedupe; 4 Kotlin: API gate, failure-as-false,
`onUnbind` clear, health re-arming the shield). Final-review corrections: 5/5
killed (native-enforcement check removed, native-enforcement UNKNOWN
accepted, detection-offline cause hard-coded, setup cause hard-coded,
not-granted category; the last is caught at compile time by the exhaustive
switch).

These tests do not run Android. Accessibility binding, `isBackgroundRestricted`,
Battery Saver, ColorOS controls and biometric hardware are simulated inputs.

## Known limitations

- OEM background controls (ColorOS auto-launch, app freezing, "super power
  saving") have no public API: always UNKNOWN, listed in every report's
  `limitations`, never claimed unrestricted.
- `isBackgroundRestricted` is API 28+; Android 7–8 report *unsupported*.
  Some OEM toggles are not reflected by it.
- The Accessibility bound flag is process-local; a cold start before the
  system rebinds may briefly show `accessibility_not_running` (fails toward
  attention, never toward SECURE).
- Notifications denied keeps ATTENTION REQUIRED (the documented degraded
  state), even though the service can run.
- No production caller refreshes health yet: the M2 dashboard and M3
  refresh triggers will. Until refreshed, `latest()` turns stale after 30 s.

## Phase 7 / M1 device QA (combined Phase 6 + Phase 7 round)

Run after M2 so the dashboard can show the state and issue ids; until then,
the evidence is the dashboard or a debug readout of the report, not logcat
guesses. Reuse the Phase 6 setups noted. A step FAILS if SECURE is shown
while the stated fault is present, if biometric changes make protection
OFFLINE or ATTENTION, or if a health read changes enforcement (a challenge
disappears, a ticket clears, the watcher starts by itself).

| ID | Device group | Setup (reuse) | Minimal actions | Expected | PASS / FAIL |
| --- | --- | --- | --- | --- | --- |
| H1 | Oppo A9 (Android 9) | all capabilities granted, one protected app | open health | SECURE, no issues; limitations list OEM controls | SECURE shown; FAIL if any issue is invented |
| H2 | Oppo A9 | as H1 (Phase 4G revoke) | revoke Draw over other apps → return → re-grant → return | PROTECTION_OFFLINE `overlay_unavailable` (revoked) → SECURE | both states as listed |
| H3 | Oppo A9 | as H1 | turn Accessibility off; then also revoke Usage Access; restore both | ATTENTION `accessibility_unavailable` → OFFLINE `detection_offline` → SECURE | as listed |
| H4 | Oppo A9 | Restricted background (S9.1/S10.1 setup) | let Android stop the service (S10.1), then open Smart App Lock health | ATTENTION with `background_restricted`, plus `watcher_not_running` if observed before the app's foreground restart takes effect (record which) | FAIL if SECURE while restricted |
| H5 | Oppo A9 | as H1 | Settings → Battery → Smart App Lock → restrict background; then remove | ATTENTION `background_restricted` → cleared | as listed |
| H6 | Oppo A9 | as H1 | Battery Saver on | state unchanged, advisory `battery_saver_on` | FAIL if the state changes |
| H7 | **compatible device required** (UNVERIFIED; not an Oppo test: fingerprint enrollment could not be completed on the Oppo A9 despite the sensor) | biometric unlock enabled with an enrolled biometric | delete all enrolled biometrics in Android Settings → return; re-enroll | advisory `biometric_unavailable` (not_enrolled), state unchanged, PIN still unlocks; cleared after re-enroll | FAIL if OFFLINE/ATTENTION; biometric success stays UNVERIFIED |
| H8 | Android 13+ | as H1 | deny notifications for Smart App Lock | ATTENTION `notifications_disabled` | as listed |
| H9 | OEM-dependent | as H1 | Force stop / ColorOS app freeze, then open the app | `accessibility_unavailable` or `accessibility_not_running` (record which), or recovered SECURE once rebound | FAIL only if SECURE while a protected app opens unchallenged |

Minimum to accept Phase 7 / M1 on device: H1–H6 on the Oppo, H8 where
supported (Android 13+), H9 recorded. H7 stays UNVERIFIED until a device
with completed biometric enrollment is available; it is not a mandatory
Oppo acceptance test. Phase 5 F3 and biometric
success remain UNVERIFIED release gates.
