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
