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

# Phase 7 / M2 — Protection Health dashboard & repair

PRD v2.1, Phase 7 / Milestone 2. Design: `docs/architecture.md` (Phase 7 /
M2); repair limits: `docs/capabilities.md` (Fix Protection limits). With M2
the Home screen and the details screen refresh health; the M1 note "no
production caller refreshes health yet" no longer applies. Automatic refresh
on return from Android Settings and the health regression round are M3.

## Automated evidence (Phase 7 / M2)

| Suite | Tests | Evidence level | Covers |
| --- | --- | --- | --- |
| `test/ui/health/health_presentation_test.dart` | 15 | production Dart (pure + controller over simulated services) | every issue code has wording, a category label and a repair plan; setup / user choice / revoked / stopped / restricted / uncertain wording; overlay never granted vs revoked; no forbidden claims; failed or missing report never SECURE; stale report → ATTENTION; repair outcome resolved / still present / unknown (stale counts as unknown); controller: failure hides the old report, late results after dispose ignored, overlapping refreshes coalesced |
| `test/ui/health/protection_health_dashboard_test.dart` | 28 | widgets over simulated services (`AppContainer.inMemory`) | MainShell keeps Home / Apps / Security State across tab switches and probes exactly once per return to Home; Home SECURE / ATTENTION REQUIRED / PROTECTION OFFLINE from the real M1 report; first-time setup and no-protected-apps worded neutrally; revoked worded as turned off; UNKNOWN never SECURE; no container → unavailable; loading state; refresh only on show / tab return / tap (no polling); disposed screen; details order by severity with advisories separate; repairs: Security tab, Apps tab, existing Overlay / Accessibility / Usage Access setup screens, allowlisted Settings links, false/failed open → manual-path notice, restart = one synchronization per tap, failed fresh check never reported as success, biometric guidance has no button; viewing and refreshing grants nothing; full app: a PIN challenge opens on top of the details screen and only the exact PIN creates a session; opening Android Settings from a repair creates no session and authorizes nothing; a pattern challenge over the details screen rejects a wrong pattern and grants only on the exact one; Restart protection and a Settings repair keep a pending ticket and never call authorize, mark-ready, show or hide challenge |
| `test/protection/health/protection_health_monitor_test.dart` | 18 (+1) | production Dart over simulated services | adds: biometric probes skipped when biometric unlock is off (report unchanged) |
| `test/services/watcher_service_test.dart` | 10 (+4) | method-channel contract (mocked channel) | `openProtectionSettings` sends only the allowlisted id; null → not opened; platform error / missing plugin → failure; opening Settings changes no protection state |
| `android/app/src/test/.../ProtectionSettingsTargetsTest.kt` | 5 | production Kotlin + source contract | allowlist of 3 targets; unknown target → nothing; notifications API 26 gate; App info fallback; no grant, exemption, enrollment or protection call in the opener |

Mutation checks (Dart): 8/8 killed: repair outcome always "resolved", stale
fresh check accepted as resolved, failed Settings open reported as opened,
failed refresh keeps showing the previous report, no refresh when Home tab
becomes visible, two synchronizations per restart tap, Settings repair
claiming success, plus one mutant killed only at compile time (replaced by a
valid one). The restart test gained a `configureCalls` assertion after the
two-synchronizations mutant first survived. Integration gate: 4/4 killed
(Home State recreated on tab switch, Security State recreated, Home probing
when hidden, Restart protection revoking authorizations); the "probing when
hidden" mutant was caught only by the new MainShell test.

Not covered automatically: real Android Settings intents per OEM, Talkback,
large font scaling on device, the real watcher restart on ColorOS.

## Phase 7 / M2 device QA (adds to the M1 H-cases; not executed)

Run with the M1 H-cases in the combined Phase 6 + Phase 7 round. Each case
reuses the H setup; tap **Check again** on Home or the details screen after
returning from Android Settings (automatic refresh on return is M3; with M3
these steps run through the consolidated plan below and no tap is needed).

| # | With | Steps | Expected |
| --- | --- | --- | --- |
| D1 | H1 | Healthy setup, open Home, open details | Home: SECURE (calm); details: no issues, scope note says it is not a guarantee |
| D2 | H2 | Revoke overlay, return, Check again; Fix protection → Allow display over apps → grant → back | PROTECTION OFFLINE, "Display over other apps was turned off"; after grant the notice says the fresh check no longer reports it; Home SECURE |
| D3 | H3 | Turn Accessibility off; then also Usage Access off; repair via the setup screens | Accessibility off: ATTENTION REQUIRED (usage path still detects); both off: PROTECTION OFFLINE "cannot see which app is open"; restore → SECURE after refresh |
| D4 | H4 / H5 | Android "Restricted" battery / service stopped by Android | ATTENTION REQUIRED, "Restricted by Android"; Open app settings opens App info; ColorOS guidance shown; "Restart protection" runs once per tap and the notice reflects the fresh check (record result, OEM-dependent) |
| D5 | H6 | Battery Saver on | status unchanged; shown only under Advisories; Battery Saver settings opens |
| D6 | H8 (Android 13+) | Deny notifications | ATTENTION REQUIRED; Open notification settings opens the app's notification page; allow → Check again → cleared |
| D7 | security | With protected app P: open details, open any Android Settings link, press Home, open P; then return to Smart App Lock | P shows the lock challenge; no unlock without PIN/pattern; Smart App Lock shows the dashboard, P is not unlocked |
| D8 | H7 (compatible device only) | Remove enrolled fingerprints | Advisory only, no button, status unchanged. UNVERIFIED on the Oppo (cannot enroll) |

Also record dark mode and the largest font size on Home and the details
screen (text readable, buttons ≥ 48 dp). Minimum to accept M2 on device:
D1–D5 and D7 on the Oppo, D6 where supported; D8 stays UNVERIFIED until a
compatible device is available. Phase 5 F3 and biometric success remain
UNVERIFIED release gates; Phase 6 is not device-verified.

# Phase 7 / M3 — Protection Health refresh & regression

PRD v2.1, Phase 7 / Milestone 3. Design: `docs/architecture.md` (Phase 7 /
M3); platform limits: `docs/capabilities.md` (Health refresh limits). All
results below are automated and SIMULATED (production Dart paths over
in-memory services and Flutter lifecycle events); none is device evidence.

## Automated evidence (Phase 7 / M3)

| Suite | Tests | Evidence level | Covers |
| --- | --- | --- | --- |
| `test/ui/health/protection_health_refresh_test.dart` (new) | 34 | widgets + production controller/monitor over simulated services | `HealthResumeTrigger`: real leave vs shade, duplicate resumed ignored, detach. Controller: old SECURE hidden during an after-change check, non-secure kept, rapid requests → newest wins with newest data. Return/resume: revoked while away shown without a tap, restored → SECURE; never the old SECURE while re-checking; shade pulls coalesce, repeated returns queue at most one more probe; hidden Home (other tab) and covered Home / covered details do not probe; Settings repair judged automatically on return; failed check on return → "could not check", never fixed; Settings not opened → no automatic judgement; timed-out native read → UNKNOWN / ATTENTION; dispose during a check → no late update, no observer left. Full app shell: revoke / restore round-trip next to the existing Security-tab and capability resume checks. Revocation table (11): overlay, Accessibility off, Accessibility unbound, Usage Access, both detection paths, notifications (setup wording), watcher stopped, background restriction, native enforcement not armed, native read failure, no protected apps; each revoke → state + code + category + repair action, restore → SECURE, no session. Battery Saver and fingerprint: advisories only. Watcher stop/restart: health never restarts it. Security: Settings round-trips and resume refreshes keep a pending ticket and never authorize, mark ready, show/hide a challenge or touch lifecycle; full app: an interrupted challenge re-presents on return with health details open and only the exact PIN grants |
| `test/protection/health/protection_health_monitor_test.dart` | 21 (+3) | production Dart | after-change request observes a change made during a running collection; later requests join the newer one; queued collection still runs after timeouts; one running + one queued bound |
| `test/ui/health/health_presentation_test.dart` | 16 (+1) | pure Dart | an issue that only became unobservable is "unknown", never "resolved" |

Defect found and fixed by this regression: M2's repair outcome reported
"A fresh check no longer reports …" when the native read failed on return
(the issue vanished as UNKNOWN). Now unknown.

Mutation checks (Dart, health suites): 12/12 killed:
- after-change ignored;
- queued follow-up not shared;
- plain request preferring the older running collection;
- old SECURE not hidden;
- generation guard removed;
- inactive treated as a leave;
- duplicate resumed not ignored;
- Home visibility ignored;
- Home trigger never attached;
- details auto-judge removed;
- details route check removed;
- unobservable outcome judged resolved.

The details-route mutant first SURVIVED; it was killed after the covered-details assertion was added.

Not covered automatically: real Android Settings pages per OEM (timing of
when a change becomes visible), ColorOS power managers, Talkback, real
screen-off timing.

## Consolidated Phase 6 + Phase 7 physical-device QA plan (NOT executed)

One round, one build containing Phase 6 M1–M3 and Phase 7 M1–M3. It merges
the Phase 6 S-series, the Phase 7 M1 H-series, the M2 D-series and the new M3
refresh checks (R). Each step lists the IDs it closes, so one action verifies
native blocking (S), the health classification (H), the guidance (D) and the
automatic refresh (R) together. The detailed S/H/D steps above stay the
reference. Nothing here has been run; automated results are simulated
evidence only.

**Ground rules.**
- A step FAILS if:
  - the protected app (A) is usable without a challenge while Accessibility is on;
  - a wrong credential opens A;
  - a challenge stacks or loops;
  - the user is stuck;
  - SECURE is shown while the fault in that step is present;
  - a health refresh changes enforcement: a challenge disappears, a ticket clears, the watcher starts by itself, or "fixed" is claimed without a fresh check.
- **R pass rule:** after returning to Smart App Lock, Home or the details screen updates **without tapping Check again**. "Checking protection…" may show briefly, but an old SECURE never shows while re-checking.
- Evidence: a screen recording, plus logcat where stated. Record the device, Android version, OEM skin and navigation mode once. Mark steps N/A with a reason.
- Use one protected app A (for example Gallery), PIN credential, grace 0 unless stated, Battery Saver off at start.

### Session 1 — Oppo A9, Android 9 / ColorOS (required)

| Step | Closes | Actions | Expected |
| --- | --- | --- | --- |
| 1 Baseline | H1, D1, R | All capabilities granted. Open Home, then the details screen. Press Home and reopen Smart App Lock. | Home shows SECURE (calm). Details: no issues, plus the scope note. Reopening refreshes with no tap and no "fixed" notice. |
| 2 Overlay | H2, D2, S10.6 (overlay), R-A | (a) Details → Fix → Allow display over apps → open Settings → revoke → Back. (b) Open A. (c) Smart App Lock → re-grant via the same repair → Back. | (a) PROTECTION OFFLINE `overlay_unavailable` with no tap. (b) A is not opened unlocked. (c) The notice "no longer reports" appears automatically; SECURE returns. |
| 3 Accessibility | H3, D3, S10.6, R-B | (a) Turn Accessibility off in Settings → return. (b) Open A. (c) Also revoke Usage Access → return. (d) Restore both via the setup screens. | (a) ATTENTION `accessibility_unavailable`, no tap. (b) A is still challenged (usage path). (c) OFFLINE `detection_offline`, "cannot see which app is open". (d) SECURE after the return refresh. |
| 4 Usage Access alone | S10.6 (usage), R-C | Revoke Usage Access only → return; open A; restore. | ATTENTION `usage_access_unavailable`; A is still challenged (Accessibility enforces); SECURE after restore. |
| 5 Battery Saver | H6, D5, S9.4, R-D | (a) Home visible, pull quick settings, toggle Battery Saver ON, close the shade. (b) With A's challenge shown, toggle the saver off and on. | (a) Status unchanged; `battery_saver_on` shows under Advisories only (the shade return is a plain refresh; if it is not shown yet, the next Check again shows it). (b) Challenge kept, no grant, no second challenge. |
| 6 Saver enforcement | S9.1, S9.2, S9.3 | Saver ON: run S9.1–S9.3 as written. | As written. |
| 7 Background restriction | H5, H4, D4, S10.2, S10.2c, R-C | (a) Details → Open app settings → Battery → restrict background → Back. (b) Run S10.2 and S10.2c. (c) Open Smart App Lock; on `watcher_not_running`, tap Restart protection once. (d) Remove the restriction → return. | (a) ATTENTION `background_restricted`, no tap; ColorOS guidance shown. (b) As written; A is never silently open; grace does not survive. (c) Record whether the watcher was observed stopped; the restart only happens on the tap, and the notice comes from a fresh check. (d) The issue clears. |
| 8 Watcher interruption | S10.1, H4 (record), R-G | Swipe Smart App Lock from Recents (not force stop); open A; then reopen Smart App Lock. | A is challenged. Record the Home state shown on reopening: health itself never restarts the watcher, though the existing app-start sync may. |
| 9 Pending challenge + Settings | D7, S5.4, R (security) | Open A → challenge → press Home. Open Smart App Lock → details → open any Settings link → Back → press Home → open A. | A's challenge re-presents; the details refresh grants nothing; only the exact PIN opens A, once. |
| 10 Lifecycle | S8, R-D, R-G | On Home: (a) pull the shade and release it ×3; (b) screen off/on; (c) press Home and return ×5 quickly; (d) go to the Apps tab, revoke overlay in Settings, return, then switch to Home; (e) leave Home visible 60 s. | (a)–(c) No loop, no stuck "Checking", no flicker storm, status correct. (d) No crash on Apps; Home shows OFFLINE on the switch; restore afterwards. (e) After 30 s Home shows ATTENTION "out of date … Check again" (no polling; never an old SECURE). |
| 11 Pattern + dashboard | D (pattern), S7.1 | Switch the credential to pattern. With details open, trigger A's challenge, rotate ×5, enter a wrong then the right pattern. | One challenge; attempts kept; only the exact pattern grants. |
| 12 P6 entry paths | S1.1, S2.1, S3.1, S4 | With the dashboard open behind: run S1.1 (notification), S2.1 (deep link), S3.1 (shortcut) and S4 (hostile `am start`). | As written; S4: crash log empty and PID unchanged. |
| 13 Recents / split | S5.1, S6.1, S6.2, S6.4 | As written (split screen N/A if ColorOS lacks it). | As written. |
| 14 Combined | S11 | Saver ON after one S10.1 swipe: once each S1.1, S2.1, S3.1, S5.4, S6.1, S7.1. | ✓ for all. |
| 15 Force stop / freeze | H9, S10.3 (record) | Force stop or ColorOS freeze; open A; open Smart App Lock. | Record `accessibility_unavailable` / `accessibility_not_running` or recovered SECURE. FAIL only if SECURE while A opens unchallenged. |
| 16 Display | D (display) | Dark mode and the largest font on Home and details. | Readable; buttons ≥ 48 dp. |

### Session 2 — Android 10+ second device (only where available)

| Step | Closes | Condition | Expected |
| --- | --- | --- | --- |
| 17 | S1.4, S9.2 | secure keyguard | challenge before content |
| 18 | S6.1–S6.3 | split screen | A never responds unchallenged |
| 19 | S10.2b | Android 12+, battery "Restricted" | as step 7; record `ForegroundServiceStartNotAllowedException` |
| 20 | H8, D6, S10.5, R-B | **Android 13+ only** (not on the Android 9 Oppo): deny notifications → return; allow via repair → return | ATTENTION `notifications_disabled` (worded "not allowed") with no tap; enforcement continues; cleared on return |
| 21 | H7, D8 | **compatible device with enrolled biometrics only** (not the Oppo) | advisory only, no button, status unchanged; PIN still works |

### Record-only and open gates
- Phase 6 Groups 3 and 4 (S1.3, S2.3, S3.2, S6.5, S7.6, S10.3, S10.4 denied, ColorOS super power saving): record as written.
- Phase 5 **F3** and **biometric success** remain **UNVERIFIED** release gates unless run and passed (Group 5). H-2 is not reopened.

### Minimum acceptance
- **Phase 6:** S9.1, S9.2, S10.1, S10.2, S10.2c, S11, S5.1, S5.4, S6.1, S6.2, S6.4, S7.1, S4 on the Oppo; S10.2b where available.
- **Phase 7:**
  - steps 1–5, 7, 9 and 10 on the Oppo (H1–H6, D1–D5, D7, R);
  - H9 recorded;
  - step 20 where Android 13+ is available;
  - H7/D8 UNVERIFIED until a compatible device is available.

# Phase 8 / M1 — Security Levels & Per-App Selection

PRD v2.1, Phase 8 / Milestone 1 (8A model, 8B per-app selection). Design and
the M2 integration contract: `docs/architecture.md` (Phase 8 / M1); platform
notes: `docs/capabilities.md` (Security levels). M1 stores and shows a level
per protected app. **It does not change enforcement**: every protected app
is challenged, granted and re-locked exactly as before, whatever its level.
All results below are automated and SIMULATED (production model, repository,
in-memory store and Apps screen; the SQL is checked as text and against a
host SQLite); none is device evidence.

## Automated evidence (Phase 8 / M1)

| Suite | Tests | Evidence level | Covers |
| --- | --- | --- | --- |
| `test/data/app_security_level_test.dart` (new) | 20 | production Dart (model, repository, in-memory store, sqflite SQL statics and row mapper) | **Model:** exactly three levels with stable explicit ids `standard` / `sensitive` / `critical`, ranks and ordering; descriptions state intent, never active enforcement; missing → Standard, unreadable/unknown → Critical (never weaker); `ProtectedApp` defaults to Standard, JSON round-trip and legacy JSON. **Persistence:** new app → Standard; Standard → Sensitive → Critical → Standard each persisted and re-read; per-app independence (other fields and the protected set unchanged); remove retires the level, re-protect → Standard; a level change never protects (unknown / removed / blank package fails, nothing stored); duplicate protect keeps one record and the level; explicit-level record creation; rapid/concurrent writes deterministic (last request wins); a protect racing a level change cannot downgrade it; a level change racing removal: removal wins, nothing re-created, failure reported; write failure reported, stored level unchanged. **SQLite:** schema v2 in both stores; fresh-install column `NOT NULL DEFAULT 'standard'`; v1 → v2 is one `ADD COLUMN` with no row rewrite and no UPSERT/RETURNING (SQLite 3.22); PRAGMA guard alters only a table without the column; row mapper: legacy → Standard, malformed → Critical, app never dropped |
| `test/ui/apps_security_level_test.dart` (new) | 14 | widgets + production repository/screen over simulated services | Protected row shows its level (Standard by default), unprotected row none; the sheet explains the levels, marks the current one, merged radio semantics, ≥ 48 dp options, and says stricter locking is not active yet; Sensitive → Critical → Standard shown only after the write and survive a screen restart; independent apps; dismiss / choose current → no write; rapid taps → "Saving…", one write; a failed write is reported and the old level stays; app unprotected while the sheet is open → nothing saved, nothing re-protected; protect → Standard, CR-2 unprotect retires, re-protect → Standard; search, switch and selection mode keep working (selection-mode tap selects, never opens the sheet). **Security isolation:** with a pending native challenge, a level change keeps the ticket and never authorizes, syncs native, changes grace, touches the challenge or the lockout; full app: a shown challenge stays enforced across a level change, a wrong PIN is refused and only the exact PIN grants; a protection sync after level changes sends the same package set and enabled flag; source contract: no code in `lib/protection`, `lib/services`, the lock host or Kotlin reads the level |
| Existing Apps / data / protection suites | unchanged (4 fakes gained the new store method) | production Dart | the separate "Locked" status text keeps every existing finder working |
| Host SQLite script (`Phase8_M1/sql_migration_check.py`, outside the repo) | 16 checks | real SQLite 3.46 on the host, not Android | v1 database with rows → v2 keeps rows as Standard; re-upgrade after a downgrade is a no-op; repeat protect keeps the level; level update of a missing row changes 0 rows; downgrade-build `INSERT OR REPLACE` resets that row to Standard (documented risk) |

Mutation checks (Dart): 14/15 killed. The killed mutants were:
- wrong default;
- unreadable → Standard;
- repeat protect overwrites the level;
- refresh SQL touches the level;
- migration default Critical;
- guard always alters;
- level write creates a row;
- success reported on 0 rows;
- row mapper ignores the level;
- optimistic UI level;
- saving guard removed;
- no refresh after protect;
- no protected re-check after the sheet;
- a level change re-syncs native.

The one survivor is an **equivalent mutant**: it removes the selection-mode guard in `_changeLevel`. In selection mode the row's tap selects the row instead (tested), and the open sheet's barrier blocks entering selection mode, so the guard cannot be reached. It is kept as defence in depth.

Not covered automatically: a real Android SQLite migration of an installed
P7 database (device step L6), Talkback reading the picker, OEM font scaling.

## Phase 8 / M1 device QA (adds to the consolidated plan; not executed)

Use two protected apps: A (for example Gallery) and B (for example a notes
app). PIN credential. A step FAILS if a level change unlocks anything,
removes a challenge, skips a challenge, or changes how either app locks.

| Step | Actions | Expected |
| --- | --- | --- |
| L1 Default | Protect a new app C from the Apps tab. | Row shows "Locked · Standard". |
| L2 Select | Tap A → choose Sensitive; tap B → choose Critical. Read the picker. | Each row shows its own level after the save confirmation; the picker marks the current level and states stricter locking is not active yet. |
| L3 Persist | Swipe Smart App Lock from Recents, reopen; then reboot and reopen. | A Sensitive, B Critical, C Standard; all still protected. |
| L4 Remove / re-add | Unprotect B (CR-2 PIN), then protect B again. | B shows Standard. |
| L5 Challenge unchanged | Grace 0: open A, B and C; wrong PIN then right PIN on each. Then grace 30 s: unlock B, leave, return within 30 s; repeat with C. Change B's level while its challenge is pending (open B, Home, Smart App Lock → Apps → change B, open B). | All three challenge identically; wrong PIN refused; only the exact PIN opens; the same grace for B and C; the pending challenge re-presents after the level change. Any difference between levels is a FAIL (enforcement is M2). |
| L6 Upgrade | On a P7 build with ≥ 2 protected apps, install the M1 build over it (no uninstall). | All apps kept and still challenged; each shows Standard. |

Minimum acceptance (Phase 8 / M1): L1–L6 on the Oppo, run inside the
consolidated round (Session 1b). L5 is a release blocker: any difference in
locking between levels is a FAIL until Phase 8 / M2.

*Phase 8 / M2 update:* L2's picker text and L5's "any difference between
levels is a FAIL" no longer apply to the M2 build. Run L2/L5 with the M2
expectations in the consolidated plan and verify level differences with the
E-series below.

# Phase 8 / M2 — Security Level Enforcement & Recommendations

PRD v2.1, Phase 8 / Milestone 2 (8C Standard, 8D Sensitive, 8E Critical, 8F
recommendations). Design, policy table, transport and migration:
`docs/architecture.md` (Phase 8 / M2); platform limits:
`docs/capabilities.md` (Security level enforcement). Every result below is
automated and **SIMULATED** (production Dart and Kotlin logic driven by
simulated inputs: in-memory stores, a static native fake mirroring the
Kotlin resolver, a mocked method channel, fake `SharedPreferences` on the
JVM). None of it is device evidence.

## Automated evidence (Phase 8 / M2)

| Suite | Tests | Evidence level | Covers |
| --- | --- | --- | --- |
| `android/.../SecurityLevelEnforcementTest.kt` (new, JVM) | 47 (33 + 14 gate) | production Kotlin (`SecurityLevelPolicy`, `PolicySnapshotResolver`, `SecurityLevelStoreCodec`, `SnapshotOrderGate`, `ProtectionAccessState`, `ProtectionStateStore` over a fake `Context`) | grace/window tables (never above configured, Standard uncapped); Standard unchanged; Sensitive capped where Standard still allows; Critical challenges every re-entry at any grace, Home/task switch/system window/own UI are departures, same-interaction stays usable, window capped natively; mixed levels independent; legacy (no map) → known/Standard, valid → applied, malformed/missing keys/unknown id/version → Critical with an error, a malformed update never wipes a stricter level; unacknowledged downgrade held, acknowledged applied, a restarted Dart session cannot downgrade without it; stale/out-of-order snapshots rejected per session; codec: legacy store → Standard, damaged entry or unknown version → Critical; raised package loses its authorization, the pending ticket is kept; no policy outside the protected set; durable write, failed write reported as not persisted |
| `test/protection/security_level_enforcement_test.dart` (new) | 28 (25 + 3 gate) | production Dart (policy, controller, matcher, bootstrap, method channel with a mocked platform) + simulated native | items 1–12, 17, 18: Standard unchanged; Sensitive 15 s cap (never above configured) and 1-min window; Critical re-entry, no challenge loop within the interaction, Home/blind start/screen off; unreadable state → challenge and strictest window; native floor; `revokeImmediately` scoped; snapshot wire format; ack parsing (unreadable level → Critical); legacy call sends no level keys; stale/unapplied/unpersisted/false/null replies are failures; simulated native legacy/applied/held/invalid/stale; configure never clears a ticket or grants; upgrade revokes only that package; bootstrap revision/session/serialization; failed sync keeps the last confirmed level; restart keeps a held downgrade; a sync never stops the watcher or changes grace |
| `test/ui/apps_security_level_m2_test.dart` (new) | 12 | widgets + production screen/sheet/CR-2/repository/bootstrap over simulated services | items 13–20: upgrade (no PIN) ends Dart and native authorization at once; downgrade asks for the PIN first, then saves and sends a confirmed downgrade; cancel/wrong PIN → saved and enforced level unchanged, nothing sent; failed write after the PIN → stricter kept; native sync failure on upgrade (honest message, Dart enforces) and on downgrade ("still enforced" row and message, Dart floor, survives a screen restart, retry through CR-2 applies); pending challenge survives changes; rapid changes on two apps serialize in order. CR-2 proof for downgrades: package-scoped, single-use, expiring. Items 21–24 (UI): hints only on protected catalog apps below the suggestion, accepting is an explicit upgrade, "Don't suggest again" changes no level and persists across restart |
| Final native gate (findings 1 and 2), inside the two files above plus `test/regression/host_auth_binding_test.dart` (+2) | 14 Kotlin, 3 + 2 Dart | production Kotlin over a fake `SharedPreferences` with AOSP commit semantics (memory first, separate disk map, restart = disk only); production Dart host with the simulated native contract. SIMULATED disk failure and process start, not device evidence | failed Critical→Standard and Sensitive→Standard writes keep the confirmed level in memory and on disk, report it held and `persisted=false`; strict grace, the existing authorization and the pending ticket unchanged; later unrelated writes and a restart cannot make the downgrade durable, a retry without acknowledgement stays held; failed upgrade enforced in this process and revoking, restart → last durable level (documented); M1 store → Standard, versionless map → Critical; no authorization after process start; a pre-sync grant is revoked by the raising sync; the Dart floor keeps Critical/Sensitive grace and window while the store is still legacy and never loosens; floor transport (missing → none, malformed → Critical); restart keeps known stricter levels; native wiring pinned by a source contract; the host sends the grant's level; 13/13 gate mutations killed (`Phase8_M2/run_gate_mutations.py`) |
| `test/data/security_recommendation_test.dart` (new) | 4 | production catalog + `PreferencesStoreImpl` over the in-memory store | items 21–24: every 8F category with a reason; exact names only (no keyword/prefix/case matching); only stricter suggestions; dismissal per `package@level`, idempotent, survives restart, local storage only |
| `test/ui/apps_security_level_test.dart` (M1, **intentionally updated**) | 14 | as M1 | see "Changed M1 tests" below |
| `test/data/app_security_level_test.dart` (M1, title only) | 20 | as M1 | descriptions still never overclaim (same banned phrases) |
| Existing suites (items 25–28: Phase 6, Phase 7, lock/CR-2, M1) | unchanged, all pass | production Dart / Kotlin | Phase 6 hardening, Phase 7 health, H-2, CR-2/CR-3, tickets, the existing 249 Kotlin tests (two of them caught and forced the fix of an early Standard window cap) |

**Changed M1 tests (intentional, M2 changes the M1-only contract):**
1. Sheet test: asserts the new `levelNotice` instead of the removed "not active yet" notice.
2. Sensitive → Critical → Standard: the downgrade to Standard now enters the PIN (CR-2).
3. Security isolation: uses upgrades only, and expects exactly one protection snapshot and one heartbeat per change (was 0). Every other counter, the ticket, grace and lockout assertions are unchanged.
4. Full-app Critical test: same assertions, reason text updated (the current interaction stays usable).
5. "Native contract unchanged (levels not transported)" → "M2 transport": the same package set and enabled flag, plus the levels of exactly those packages.
6. "Source contract: no enforcement code reads the level" → "Dart and Kotlin policies use the same numbers".
7. `app_security_level_test`: description test title only.

**Mutation checks: 27/27 killed** (`Phase8_M2/run_mutations.py`, outside the repo; every mutant killed by an assertion, not a compile error).
- Policy: Sensitive grace not capped; Critical keeps grace; strict window not capped; leave ignores the level; native floor ignored; unknown state → Standard; native Critical grace; native Sensitive cap; native window cap; re-entry grace ignores the level.
- Downgrade gate: CR-2 skipped; downgrade judged against the saved, not enforced, level; upgrade keeps the old window; success claimed without native confirmation; lowering proof not checked (survived the first run; a direct proof test was added).
- Fail-closed transport: stale reply treated as success; confirmed downgrades never sent; revision not incremented; failed sync forgets the native level; unpersisted reply treated as success; unconfirmed downgrade applied natively; malformed snapshot → Standard; stale snapshot accepted; raised packages keep authorization; damaged store entry → Standard; unknown store version → Standard; failed native write reported as persisted.

Not covered automatically: real Android `SharedPreferences` durability,
OEM foreground-event behaviour (IME, System UI, Recents), real Accessibility
and Usage Access delivery, Talkback reading the suggestion card.

## Phase 8 / M2 device QA (adds to the consolidated plan; not executed)

Run as Session 1c of the consolidated round (Oppo A9, after Session 1b).

Setup: PIN credential, **grace 30 s**, Accessibility on. Protected apps:
A = Standard (for example Gallery), B = Sensitive (a notes app), C =
Critical (a banking or test app). A step FAILS if: a Critical app opens
without a challenge after an observed departure; a challenge loops or
re-appears while the user stays in the authenticated app; a lower level
takes effect without the PIN/pattern; a level change unlocks anything,
clears a pending challenge or resets lockout; SECURE is shown while a fault
is present (Phase 7 rules). Reuses the Phase 6 S-series setups where
named.

| Step | Closes | Actions | Expected |
| --- | --- | --- | --- |
| E1 Standard unchanged | 8C, S5 grace | Unlock A, Home, reopen at ~10 s; leave again, reopen after ~40 s. | Opens at 10 s; challenge after 40 s (same as before M2). |
| E2 Sensitive grace | 8D | Unlock B, Home, reopen at ~10 s; leave, reopen at ~20 s. Then set grace 5 s and repeat at ~8 s. | Opens at 10 s; challenge at 20 s; with grace 5 s challenge at 8 s (never more grace than configured). |
| E3 Sensitive idle | 8D, H-2 | Unlock B, leave the phone untouched inside B for ~70 s, then tap/scroll so B changes screen. | Challenge on the next reported event after 1 minute idle (event-driven, H-2). Record if no event is produced. |
| E4 Critical re-entry | 8E | Unlock C, Home, reopen immediately (< 2 s). Repeat via the launcher icon and via Recents. | Challenge every time. |
| E5 Critical same interaction | 8E | Unlock C, navigate inside C actively for 2 minutes (menus, back, rotate if supported). | No challenge while staying in C; no loop; no flicker of the shield. |
| E6 Critical task switch / own UI | 8E, S5 | Unlock C → Recents → C; unlock C → another app → C; unlock C → Smart App Lock → C. | Challenge on each return. |
| E7 Critical screen off/on | 8E, S9.1 | Unlock C, screen off, screen on (with and without secure keyguard). | Challenge before content (as S9.1). |
| E8 Critical transient windows (record) | 8E limitation | Inside C: open the keyboard, pull the notification shade, show a toast/heads-up, volume panel. | Record which ones trigger a challenge on return (strict by design). It must never loop, never open C without the PIN. |
| E9 Upgrade revokes | 8C–8E, §4 | Grace 5 min: unlock A, Home; Smart App Lock → Apps → A → Critical; reopen A. | Challenge (old grace not kept). No PIN asked for the upgrade itself. |
| E10 Downgrade gate | §4, CR-2 | C Critical → choose Standard: confirm screen titled "Confirm to lower the security level". Back out. Reopen C after a leave. Then repeat and enter the PIN. | Cancel: row still Critical, C still challenges on re-entry. With PIN: row Standard; C now has the 30 s grace. |
| E11 Downgrade wrong PIN / lockout | §4, CR-2 | On the downgrade confirm, enter wrong PINs up to lockout. | Level unchanged; lockout shared with the lock screen; no unlock of any app. |
| E12 Restart / reboot | §2, §3 | With A/B/C set, swipe Smart App Lock from Recents; force-stop from Settings; reboot. **Before** opening Smart App Lock, unlock C (via the challenge), leave, return. | Levels survive; C still challenges on re-entry after reboot (native persisted levels). |
| E13 Upgrade install | §2 migration | Install M2 over an M1 build with levels set (A Sensitive, B Critical), no uninstall. Before opening Smart App Lock: open B, unlock it through the challenge, leave, return within the grace. Then open Smart App Lock once and repeat. | Before the first open, B still asks for the PIN on first access, and after the unlock every return re-challenges (Critical floor sent with the unlock). After opening Smart App Lock: same. Nothing unprotected; A's return after more than 15 s re-challenges. |
| E14 Pending challenge | §4, S5.4 | Open C (challenge shown), Home, Smart App Lock → Apps → change A's level; open C. | C's challenge re-presents; nothing unlocked. |
| E15 Recommendations | 8F | Protect a listed app if installed (WhatsApp, Easypaisa, JazzCash, Google Authenticator, Bitwarden). Airplane mode on. | Hint icon on the row; sheet shows "Suggested: …" with a reason; "Don't suggest again" hides it (also after restart) and changes no level; "Use …" changes the level only on tap; works offline. Unlisted apps show no hint. |
| E16 Health unchanged | Phase 7 | After E9–E11, open the health dashboard. | Same states as before M2; no new state; repair never unlocks. |
| E17 Usage fallback (record) | U1-R | Accessibility off (Usage Access on): repeat E4 and E1. | Record behaviour; Critical must never be more permissive than Standard. |

Minimum acceptance: E1, E2, E4–E7, E9–E12,
E14, E15 on the Oppo. Release blockers: E4, E6, E7, E10, E11, E12. Record
E3, E8, E13 and E17; run E16 with the Phase 7 set. F3 and biometric remain
UNVERIFIED; H-2 is not reopened.


# Phase 8 / M3 — Security Level QA & Regression

PRD v2.1, Phase 8 / Milestone 3 (8G). The user's brief cites "v2.0 / 8G";
the uploaded file is v2.1, and its M3 text is the reference. Baseline:
`75040cb` (Phase 8 M1 + M2). M3 adds **tests and documentation only**. No
production code changed and no defect was found. Every result below is
automated and **SIMULATED**: production Dart and Kotlin logic driven by a
controllable clock, in-memory stores, the static native fake and a fake
`SharedPreferences` with AOSP commit semantics. None of it is device
evidence.

## 8G coverage matrix (G = 30 s configured grace, W = 2 min requested window)

| Scenario | Standard | Sensitive | Critical | Automated evidence | Device step |
| --- | --- | --- | --- | --- | --- |
| Initial access | challenge | challenge | challenge | K1, D1 | E1, E2, E4 |
| Same foreground, observed every 20 s for 5 min | usable, no loop | usable, no loop | usable, no loop | K1, D1 | E5, E3 |
| Leave → return at 1 / 10 / 20 / 31 s | allow / allow / allow / challenge | allow / allow / challenge / challenge | challenge every time | K1, D1 | E1, E2, E4, Q1, Q4 |
| Recents / System UI / own UI / another protected app | as leaving | as leaving | challenge | K1, D1 (System UI) | E4, E6, Q4 |
| Screen off/on | challenge | challenge | challenge | K1 (the screen-off revoke-all), D1 | E7, S9.1, Q4 |
| Window expiry (W − 1 ms / W) | allow / challenge (2 min) | allow / challenge (1 min) | allow / challenge (1 min) | K1, D1 | E3 |
| Watcher interruption / restart | challenge | challenge | challenge | K1 (`WatcherTeardownPolicy`), D1 (new engine) | step 8, Q5 |
| Process death | challenge; level kept | challenge; level kept | challenge; level kept | K2, D1 (new container, same database) | E12 |
| Missing / unknown foreground or level | no re-admission, authorization not kept; unreadable level → Critical | same | same | K1, K3, M2 Dart suite | E17 (record) |

K = `SecurityLevelQaMatrixTest.kt`, D = Dart M3 tests (table below).
Critical keeps the current interaction usable. It never re-shows the
challenge over an authenticated session.

## Automated evidence (Phase 8 / M3)

| Suite | Tests | Evidence level | Covers |
| --- | --- | --- | --- |
| K: `android/.../SecurityLevelQaMatrixTest.kt` (new, JVM) | 10 | production Kotlin (`ProtectionAccessState`, `SecurityLevelPolicy`, `PolicySnapshotResolver`, `SecurityLevelStoreCodec`, `SnapshotOrderGate`, `ProtectionStateStore`, `WatcherTeardownPolicy`) over a fake `Context` / `SharedPreferences`; `WatcherService.authorizePackage` order pinned by a source contract | K1: level × scenario matrix. K2: process death → fail-closed, each persisted level kept. K3: damaged or unknown level state → Critical. All six transitions: upgrades apply at once; downgrades are held without acknowledgement. Reordered, replayed or new-session snapshots cannot weaken or authorize, and never clear a protected ticket. Unlock-level binding: stricter of store and floor; a missing field cannot grant; malformed → Critical; the floor is used only after the exact-ticket gate. Store integrity table: legacy → Standard; versionless map, missing entry or unknown version → Critical. Failed upgrade + process death: last durable (weaker) level, no surviving authorization; a fresh unlock that carries the Dart level gets no grace and a 1-minute window; the next sync makes the upgrade durable |
| D1: `test/protection/security_level_qa_matrix_test.dart` (new) | 36 (12 per level) | production controller, matcher, policy, repository and bootstrap over an in-memory database, simulated native and a controllable clock | the matrix rows above per level; a still-held stricter native level stays effective after a lower save without confirmation; a credential lockout denies at every level |
| D2: `test/ui/security_level_qa_m3_test.dart` (new) | 13 | widgets + production Apps screen, level sheet, CR-2 gate, credential manager (real attempts and lockout), repository and bootstrap over simulated services | all six transitions. Upgrades: no PIN, old grace and session end, nothing acknowledged. Downgrades: the PIN screen titled "Confirm to lower the security level", acknowledged only for that app. In every transition: the pending ticket and generation are kept, no native authorization or grace change, and Dart's re-lock level equals native's. Each downgrade cancelled: nothing written or sent. Lockout during a downgrade: unchanged, and the lockout is shared (evaluate denies). Proof: single-use across lowering and unprotecting, package-scoped, a backwards clock refused. Recommendations: no hint at or above the suggestion, for unlisted apps or for unprotected listed apps; no network path (self-contained catalog, exact dependency set, no INTERNET permission, no HTTP/socket client in `lib/`) |
| Existing suites (P5 PIN/pattern/lockout/H-2, P6 entry/recents/recovery, P7 health/dashboard/refresh, P8 M1/M2) | unchanged, all pass | as before | cross-phase regression (8G §5) |

**Totals:**
- Kotlin JVM: 306 (296 + 10).
- Full Flutter: +1312 (1263 + 36 + 13), passed with no reruns.
- Typecheck of the native sources: exit 0 (79 classes).
- `flutter analyze`: clean.

**Targeted mutation checks: 10/10 killed** (`Phase8_M3/run_m3_mutations.py`,
outside the repo; each mutant run against the new M3 tests only):
- Critical keeps grace;
- Sensitive grace not capped;
- strict window not capped;
- native floor ignored by the controller;
- lowering or unprotecting does not consume the proof (the unprotect mutant
  first survived because a repository check masked it; the test now asserts
  refusal by the proof itself);
- downgrade skips the PIN;
- a non-stricter suggestion is shown;
- the native unlock floor is ignored;
- a malformed unlock level is permissive.

**Observational limits (documented, not regressions):**
- Levels act only on transitions Android reports.
- Native authorizations are revoked on screen off, watcher teardown, stop
  and emergency exit. The Accessibility service's unbind does **not**
  revoke, so transitions while Accessibility is disconnected are not
  observed (Q6 records it).
- Window expiry stays event-driven (H-2).
- After a failed upgrade write plus process death, native reads the last
  durable (weaker) level until the next successful sync. No authorization
  survives, and every unlock from this build sends the level Dart enforces
  (pinned by `host_auth_binding_test`). E13 stays a release gate.

Not covered automatically: real `SharedPreferences` durability, OEM
foreground events, real Accessibility / Usage Access delivery, the real
`WatcherService` and `AccessibilityLockService` (not JVM-compilable;
source-contract and typecheck only).

## Phase 8 / M3 device QA (adds to the consolidated plan; not executed)

Session 1d of the consolidated round (Oppo A9, after Session 1c). Same setup
as Session 1c: PIN credential, grace 30 s, Accessibility on, A = Standard,
B = Sensitive, C = Critical. Session 1c's FAIL rules apply, plus:
- a level lowers without the PIN or pattern in that attempt;
- an interrupted confirmation leaves the lower level saved;
- the row's level differs from the observed re-lock behaviour.

No fingerprint enrolment is needed (do not re-enrol on the Oppo).

| Step | Closes | Actions | Expected |
| --- | --- | --- | --- |
| Q1 Remaining transitions | 8G §2 (E9/E10 cover Standard ↔ Critical) | A: Standard → Sensitive, Sensitive → Critical, Critical → Sensitive, Sensitive → Standard; after each change, unlock, Home and reopen (at ~20 s, at once, at ~10 s then ~20 s, and at ~20 s). | Upgrades need no PIN and challenge on reopen. Downgrades show "Confirm to lower the security level" and apply only after the PIN. Re-lock follows the new level. |
| Q2 Rapid changes | 8G §2 | Choose and back out quickly, repeat with the PIN, change B and C back to back. | The final row matches the last confirmed change; nothing lowers without a PIN; nothing is stuck. |
| Q3 Interrupted downgrade | 8G §2, S7.1, S9.1 | C Critical → Standard; on the confirm screen: Home, screen off/on, rotate, incoming notification/call (record). | Stays Critical unless the PIN was entered in that attempt; counters kept; nothing unlocks. |
| Q4 Sensitive departures | 8G §1 | B via Recents at ~5 s and ~20 s; screen off/on; Smart App Lock → B at ~5 s. | Opens at 5 s; challenge at 20 s and after screen off. |
| Q5 Critical after watcher interruption | 8G §1, S10.1 | After step 8: open C, unlock, Home, reopen. | Challenge on first access and on return. |
| Q6 Accessibility disconnect (record) | observational limit | Unlock C, leave, Accessibility off, reopen C, Accessibility on, return to C. | Record; C never more permissive than A in the same sequence. |
| Q7 Suggestion → downgrade gate | 8G §4 | Listed app at Standard: "Use Sensitive", then choose Standard; repeat in airplane mode. | Accepting needs no PIN; going back needs the PIN; Critical apps show no suggestion; works offline. |
| Q8 Cross-phase rerun with C | 8G §5 | Rerun Session 1 steps 9, 11, 12, 13 and 1 with C as the protected app. | As written; C challenges on every return; health unchanged. |

Minimum acceptance: Q1–Q5, Q7 and Q8 on the Oppo. Release blockers:
Q1 (downgrades), Q2, Q3, Q7. Record Q6. F3 and biometric remain UNVERIFIED.

**Status:**
- Implementation is complete and simulated-tested.
- It is **not device verified**: the combined Phase 6–10 round is deferred,
  not waived.
- It is **not release ready** until that round passes, including E13, F3 and
  biometric.

## Automated evidence (Phase 9 / M1)

Security Center (PRD v2.1 Phase 9 / M1, 9A–9D). All results are
**SIMULATED**: production widgets, `MainShell`, router, the Phase 7 engine,
monitor and controller, and the real protected-app repository over an
in-memory database with static platform services. No device, Settings
screen, OEM behaviour or native enforcement is observed.

| Suite | Tests | Covers |
| --- | --- | --- |
| `test/ui/security/security_center_test.dart` (new) | 25 | 9A: light/dark at 320 dp with 2× text, no overflow, semantic labels. Brief items 1–20: real values per level; empty state with an Apps link; one app; mixed levels; no duplicates and no unprotected installed apps; protect/unprotect and level changes reflected on return; Critical with SECURE / ATTENTION / OFFLINE; stale → ATTENTION (no new probe); checking hides an old SECURE; read failure → "unavailable" (never 0, earlier counts dropped) and Try again; loading state; native health unreadable → ATTENTION; health refresh failure or no source → "Status unavailable" / "Not confirmed"; Manage apps → Apps; View details → Health Details with exactly one re-check on return and no polling; repair → Apps tab; Settings and resume refresh; tab switches keep `SecurityScreen` / section State and a challenge stays on top (exact PIN only); disposal with a pending probe and read; no record or level write, authorization, grace, challenge, watcher start/stop or policy sync; a held stricter native level shown, never pushed (CR-2) |
| `test/ui/security/security_center_summary_test.dart` (new) | 15 | counting rules (first record wins, blank packages ignored, label fallback, held-stricter only when native is stricter, input not mutated); Critical status mapping over real engine reports (none, unconfirmed, SECURE, ATTENTION, OFFLINE, stale, future-dated, unknown native) |
| Legacy banner suites, **intentionally rewritten** for Phase 7 states (option A_replace): `protection_setup_banner_test` (9), `revocation_detection_test` (5 → 6), `permission_regression_test` (16) | 31 | same scenarios. Fresh install, one or both detectors, all granted without a credential: setup wording, never SECURE, never a failure. Configured: SECURE; Accessibility off or Usage Access off → ATTENTION; overlay off or both detectors off → OFFLINE "turned off". Restoring returns SECURE only after the refresh. Revocation dot rule unchanged (required capabilities only). New: a revocation before setup marks the dot while health stays setup |
| Other intentional updates | — | `phase1_regression_test`: PIN setup now via the Authentication row (CR-3 change flow), not the removed banner action. `protection_health_dashboard_test`: opening the Security tab is one extra probe (Home still never probes while hidden). `security_screen_test`: waits out the bounded biometric probe timeouts (6 s) so no timer is left pending |
| Existing suites (P5–P8) | unchanged, all pass | cross-phase regression |

**Totals:**
- Full Flutter: run 1 (before the last fix) +1352 −1. The failure was the
  pending biometric probe timer in `security_screen_test`, fixed as above.
  Run 2 (final tree): **+1353, all passed**, no reruns (1312 + 41 new).
- `flutter analyze`: clean.
- Native: no file under `android/` changed (`git diff HEAD -- android`
  empty), so Kotlin JVM and typecheck were not rerun (P8 M3 baseline: 306
  and exit 0).

**Targeted mutation checks: 12/12 killed** (`Phase9_M1/run_m1_mutations.py`,
outside the repo; each mutant run against the Phase 9 / M1 tests only):
- summary accuracy: duplicates counted, blank packages counted, Critical
  counted as Sensitive, held-stricter ignored;
- offline/unknown health: no report, OFFLINE, or ATTENTION/stale treated as
  "Checks passed";
- read failure: shown as zero/empty, or earlier counts kept;
- refresh: no refresh on tab activation, on return to the top route, or on
  a revocation event.

Not covered automatically: real devices and OEM skins, real Settings round
trips, TalkBack, real font scaling and display sizes, and the native
watcher and Accessibility service.

## Phase 9 / M1 device QA (adds to the consolidated plan; not executed)

Session 1e of the consolidated round (Oppo A9, after Session 1d). Same
setup: PIN, grace 30 s, Accessibility on, A = Standard, B = Sensitive,
C = Critical. Fail rules:
- a count differs from the Apps rows, or an unprotected app is counted;
- an unreadable list shows a number (including 0);
- SECURE or "Checks passed" is shown while a step 2–4 fault is present;
- absolute wording appears;
- the Security Center changes a level, unlocks an app, or clears a
  challenge.

| Step | Actions | Expected |
| --- | --- | --- |
| SC1 Counts | Security tab vs Apps tab. | Total 3: Standard 1, Sensitive 1, Critical 1; C named. |
| SC2 Changes + return | Manage apps: protect D, A → Critical, C → Standard (PIN), unprotect B (PIN); back to Security. | Counts and the Critical count match the Apps rows with no restart; nothing unlocks. |
| SC3 Empty (record) | Unprotect all at the end of the session. | "No apps are protected yet"; Choose apps opens the Apps tab. |
| SC4 No false SECURE | With C Critical, rerun step 2(a), then step 4, then restore. | OFFLINE + "Not working"; ATTENTION + "Needs attention"; SECURE + "Checks passed" only after the return refresh. |
| SC5 Return refresh | Details → Back; Settings tab + overlay revoke → Security; Home + Usage revoke → reopen; idle 60 s. | Updates without Check again; no loop or repeated checking. |
| SC6 Challenge on top | Step 9 with C and the Security tab. | C's challenge re-presents; only the exact PIN opens C. |
| SC7 Display (record) | Dark mode and the largest font. | Readable; nothing clipped. |

Minimum acceptance: SC1, SC2, SC4, SC5 and SC6 on the Oppo (release
blockers: SC2, SC4, SC6). SC3 and SC7 are recorded. The full plan copy is
`Phase9_M1/P6_P9_CONSOLIDATED_QA_PLAN.md` (outside the repo).

**Status:** implemented and simulated-tested. It is **not device verified**
(the combined Phase 6–10 round is deferred, not waived) and **not release
ready** until that round passes, including E13, F3 and biometric.

## Automated evidence (Phase 9 / M2)

Security Score (PRD Phase 9 / M2, 9E model and 9F UI). Baseline: the local
M1 commit `011053d` (not pushed). All results are **SIMULATED**:
- the pure model over real Phase 7 engine reports;
- the production widgets, `MainShell`, router, health monitor and
  controller;
- the real protected-app and lock-settings repositories over an in-memory
  database, with static platform services.

No device, Settings screen, OEM behaviour or native enforcement is
observed.

| Suite | Tests | Covers (brief §7 numbers) |
| --- | --- | --- |
| `test/ui/security/security_score_test.dart` (new) | 29 | 1–3: weights 60 + 40, tier bounds, `floor(10 × Σcredit / n)` with clamping. Credited-level matrix. Every documented example exact. Breakdown totals over all levels × grace options × health. 4–5: setup (no PIN / no apps / health not configured / health unknown). 6–9: SECURE available; ATTENTION provisional (health 0, ≤ 40, below every available score); OFFLINE withheld even with all apps Critical; stale and future-dated unavailable (the exact limit is still fresh). Checking / failed / never checked. 10: repository failure wins over setup. 16: loading → assessing. Settings failure. 11: per-level F2 at each grace. 12: held-stricter counted at the saved level. 13: unconfirmed and native-unknown counted lower. Malformed level. 14: monotonic in level and grace. App count not rewarded. Dedup equals M1. Negative grace. 15: biometric variants never change the score. Battery Saver not scored. Determinism; inputs not mutated |
| `test/ui/security/security_score_card_test.dart` (new) | 23 | 18/19: 320 dp at 2× text, light and dark, with details expanded and no overflow; semantics for the score, factors and heading; number in the normal text colour. Placement between health and apps, with existing tab controls below. 6/17: UI equals the model (90 = 60 + 30) with exact rows, tier lines and reductions; 100 explained as an assessment. 4–5: setup steps with no number or failure wording; Choose apps → Apps. 7: ATTENTION provisional tag, problem named once (in the health card), Fix → Health Details. 8: OFFLINE withheld, Fix → Details. 9: stale drops the number with no new probe; Check again restores it. Checking hides an earlier number. Health failure → Check again. 16: no number (no 0 / 100) while apps load. 10: read failure drops the earlier score; Try again → provisional until Check again (consistent with health). Settings read failure. 14: Grace period change updates at once (no probe); a failed save shows the saved value. 11/15: an unconfirmed upgrade gets no credit, a confirmed one does. 12/13: held downgrade noted, nothing synced. 20: an older read completing last never overwrites. Resume from Settings re-assesses. 21: a pending challenge stays on top; exact PIN only. 22: no level / setting / record write, sync, grace or authorization |
| **Intentional updates** | — | `security_center_test`: the M1 banned-wording helper now skips the score card (which legitimately says "score" and "not a guarantee against bypasses"; its wording is pinned in the new widget suite). `security_screen_test` (1 test) and `permission_regression_test` (viewport 1600 → 2400): taller viewports, because the card adds height above rows in the lazy ListView. No assertion was weakened |
| Existing suites (P5–P9/M1) | unchanged, all pass | 23–24: cross-phase regression |

**Totals:**
- **Full Flutter:** **+1405, all passed**, EXIT 0, no reruns (1353 M1
  baseline + 29 + 23).
- **Focused** (Security Center + Security tab + health UI + the M1-touched
  regression suites): +242, all passed.
- **During development** (not counted as evidence), first runs failed on:
  the M1 banned-wording helper; lazy-list viewports; a duplicated issue
  title (UI changed to name the problem once); a semantics boundary; a
  gate-ordering deadlock in a new test; and a wrong expectation (after a
  failed read, health is ATTENTION, so the score is provisional; the test
  now asserts this).
- **Static checks:** `flutter analyze` clean; `dart format` 0 changed (9
  files); `git diff --check` clean.
- **Native:** nothing under `android/`, `ios/` or `pubspec*` changed, so
  Kotlin JVM and typecheck were not rerun (P8 M3 baseline: 306, exit 0).

**Targeted mutation checks: 18/18 killed** (`Phase9_M2/run_m2_mutations.py`,
outside the repo; each mutant run against the M2 tests only; restoration
verified byte-identical):
- **availability:** stale scored; OFFLINE numbered; ATTENTION shown as
  available; repository failure falls to setup; settings failure ignored;
  no-apps not setup; checking shown as unavailable;
- **weighting:** ATTENTION keeps the health points; rounding up; 15 s tier
  bound moved;
- **native confirmation:** unknown native credited as saved; stricter level
  credited; held-stricter unreported;
- **UI/refresh:** Provisional tag hidden; stale read overwrites; failed read
  keeps old inputs; settings revision ignored; the Security tab never bumps
  it.

Not covered automatically: real devices and OEM skins, real Settings round
trips, TalkBack, real font scaling, and the native watcher and
Accessibility service.

**Review wording correction (text only):**
- **What changed:** the shared Phase 7 OFFLINE message ("protection stopped
  working") is now `HealthPresentation.offlineMessage`: "Protection is
  offline. App locking may not work until protection is restored."
  The Security Center Critical OFFLINE line uses the same constant instead
  of its own copy.
- **Tests:** the expectations that pinned the old wording were updated.
  `health_presentation_test`, `protection_health_dashboard_test` and
  `protection_setup_banner_test` now assert the exact new sentence. The
  "setup is never worded as a failure" checks and
  `permission_regression_test` now look for the new sentence.
- **Unchanged:** no state, classification, refresh, score or
  authorization change.
- **Not changed in this correction:** the separate "permission not allowed
  yet" setup message.

## Phase 9 / M2 device QA (adds to the consolidated plan; not executed)

Session 1f of the consolidated round (Oppo A9, after Session 1e). Same
setup as Session 1e: PIN, grace 30 s, A = Standard, B = Sensitive,
C = Critical. Baseline expectation: **90 / 100** (credits 2 + 3 + 4).

**Fail rules:**
- any number while OFFLINE, stale, checking, failed, unreadable or not set
  up;
- a 0 or 100 placeholder while loading;
- a number that does not match the formula;
- ATTENTION without **Provisional**;
- a green number, "%" or perfect / guaranteed wording;
- a score action that changes a level or setting, unlocks an app, or
  clears a challenge.

| Step | Actions | Expected |
| --- | --- | --- |
| SS1 Setup (record) | Before the PIN on a fresh install; and with no apps protected (SC3). | Setup steps only, with no number. |
| SS2 Distributions | Grace Immediate, then 5 min, then 30 s; then A → Critical. | 100 (maxed note), 86, 90; then 96. Updates at once. |
| SS3 Revoked | Overlay off; then Usage only; then restore. | Withheld; **30 Provisional**; 90 only after the return refresh. |
| SS4 Background restriction | Restrict, then remove. | 30 Provisional, consistent with ATTENTION; then a fresh 90. |
| SS5 Restore (record) | First value after each restore. | Matches the restored state. |
| SS6 Critical while OFFLINE | Overlay off, A and B → Critical, return; restore. | No number while offline; 100 after restore. |
| SS7 Rapid level change | A quickly through the levels back to Standard; C → Standard (PIN). | Only final values: 90, then 83. |
| SS8 Settings + idle | Settings round trip; idle 60 s; Check again. | Updates with no tap; the number disappears when out of date; returns on Check again. |
| SS9 Pending challenge | C challenge → Security tab, details, Check again → C. | The challenge stays on top; exact PIN only. |
| SS10 Display (record) | Dark mode, largest font, TalkBack. | Readable; "Security score: 90 out of 100 points." |

**Minimum acceptance:** SS2, SS3, SS4, SS6, SS7, SS8 and SS9 on the Oppo.
Release blockers: SS3, SS6, SS8(b) and SS9. SS1, SS5 and SS10 are recorded.
The full plan copy is `Phase9_M2/P6_P9_CONSOLIDATED_QA_PLAN.md` (outside
the repo).

**Status:** implemented and simulated-tested. It is **not device verified**
(the combined Phase 6–10 round is deferred, not waived) and **not release
ready** until that round passes, including E13, F3 and biometric.

## Automated evidence (Phase 9 / M3)

Recommended improvements and score integrity QA (PRD Phase 9 / M3, 9G and
9H). Baseline: the local M2 commit `7642470` (not pushed). All results are
**SIMULATED**:
- the pure recommendations model and the real M2 score over real Phase 7
  engine reports, the real Phase 8 catalog and real `ProtectedApp` records;
- the production widgets, `MainShell`, router, challenge host, health
  monitor and controller;
- the real protected-app, lock-settings and preference stores (in memory),
  with static platform services.

No device, Settings screen, OEM behaviour or native enforcement is
observed.

| Suite | Tests | Covers |
| --- | --- | --- |
| `test/ui/security/security_center_recommendations_test.dart` (new) | 23 | Status: failed / loading reads never yield items; healthy → calm. A: first-time setup (PIN + apps steps, setup wording, not dismissible); PIN set, no apps; apps protected without a PIN (only the PIN step, no optional items even with unreadable dismissals); never-granted overlay worded as setup. B: OFFLINE item with the Phase 7 title, explanation, tag and Health Details; ATTENTION items; unknown signal → Check again; a stale report lists only "Status is out of date"; advisories (biometric, Battery Saver) never items. C: exact-package catalog only (case, unknown, unprotected), current → suggested, held-stricter native respected, dismissal per `package@level`, unreadable dismissals withhold optional items. D: re-lock proposal (longest shorter option that changes something), Critical-only / Immediate → none, unconfirmed level counted conservatively, dismissal bound to the value, options equal `SecurityScreen.graceOptions`. Priority order; dismissal never changes the score; banned wording; purity and determinism. 9H: score-integrity checks (fresh SECURE, provisional ≤ 40, withheld states, exact sums, unconfirmed ≤ confirmed, biometric / Battery Saver / app count neutral) |
| `test/ui/security/security_recommendations_card_test.dart` (new) | 25 | Calm state (exact hedged text, no buttons) and placement after the score. 320 dp at 2× text, light and dark: no overflow, header and level-line semantics. Setup steps: "Show PIN and pattern" scrolls to Authentication, "Choose apps" opens Apps. Assessing while loading; failed health → unavailable with Check again; failed apps read → unavailable, Try again recovers. Card rendering of every state (optional-unavailable note, each unavailable reason and its button, callbacks). Permission issue → item, Health Details, restore removes it (resume, no tap). Critical + OFFLINE: problem first, no safety claims, restore keeps only optional items. Level suggestion opens Apps, no write, no auto-upgrade. Dismissal hides, writes the shared key, score unchanged, Apps tab hint gone on tab return; and the reverse (Apps tab dismissal removes the Security Center item). Re-lock values; "Show Grace period" builds and scrolls the lazy list to the selector (500 dp viewport, section not built beforehand); the user's own change updates the score (70 → 80) and the proposal. Re-lock dismissal bound to the value. Protect / level change / unprotect reflected on tab return. Rapid refresh: an older read completing last is ignored. Pending PIN challenge survives Health Details navigation and resume; wrong PIN refused, exact PIN grants. Read-only: no level, protection or setting write, sync, grace change or authorization. **Dismissal persistence (SIMULATED, 6, final gate):** saved → hidden with the confirmation and still hidden after a full container restart in both tabs; failed save → the item stays with the not-saved message (no "hidden" claim), score, levels, protected set, watcher sync and grace unchanged, tabs consistent, still shown after restart; Try again saves and hides; grouped level item failing part-way hides only the saved app; Apps tab failure keeps the hint with Try again; an Apps tab failure leaves the Security Center item listed |
| `test/data/dismissal_persistence_test.dart` (new, final gate) | 6 | Production `SharedPreferencesKeyValueStore` over a `SharedPreferences` fake: a write the platform reports as failed throws (never success); end to end over the real plugin with mock values: a saved dismissal reads back. `PreferencesStoreImpl` over a store that caches then fails (like Android): success saves sorted and a repeat is a no-op; a failed first dismissal rolls back to none; a failed later dismissal restores the previous set, and a failing rollback still surfaces the original error; invalid keys never write |
| **Intentional updates (existing suites)** | — | `permission_regression_test`, `protection_setup_banner_test`, `revocation_detection_test`: the top health issue's title now appears exactly twice on the Security tab (health card + Recommended improvements); a new `expectIssueNamed` helper asserts one match inside each card and two in total. `security_score_card_test` test 7: the same, scoped to the two cards. `security_screen_test`: viewport 800 × 2400 (the card adds height above rows in the lazy list). `health_presentation_test`: pins the exact new "not allowed yet" sentence and that it is not the OFFLINE message. No assertion was weakened |
| Existing suites (P5–P9/M2) | unchanged, all pass | cross-phase regression (PIN/pattern, biometric, CR-2, tickets, sessions, grace, lockout, Phase 6/7/8) |

**Totals:**
- **Full Flutter:** **+1447, all passed**, EXIT 0, no reruns (1405 M2
  baseline + 23 + 19).
- **Final gate (dismissal persistence correction):** full Flutter
  **+1459, all passed**, EXIT 0, no reruns (1447 + 6 new unit
  tests + 6 new card tests). Focused suites (the two new/extended suites, the M3 model
  suite, Apps level M2, preferences store, recommendation catalog, score
  card): first run **+103 −1** (test 22 assumed WhatsApp's line is saved
  first; the repository lists Bitwarden first, so the test now reads the
  on-screen order); then **+104, all passed**.
- **Focused existing suites** (Security Center, Security tab, health UI and
  the regression suites the card touches): first run **+218 −24** (lazy
  viewport, duplicated titles now expected twice, a banned word in the calm
  text, an obsolete "may not work" failure marker); after the intentional
  updates above, **+242, all passed**.
- **New suites during development** (not counted as evidence): the model
  suite first failed to compile (`graceOptions` was private; now a public
  alias of the same constant); the widget suite first failed on the Apps
  tab (WhatsApp was not an installed app in the fixture, so the hint
  assertion was vacuous; the fixture now installs it) and then found a real
  inconsistency: a suggestion dismissed in the Security Center stayed
  visible on the kept-alive Apps tab. Fixed in `apps_screen.dart` /
  `main_shell.dart` (dismissed set re-read on tab return).
- **Static checks:** `flutter analyze` clean; scoped `dart format` 0
  changed; `git diff --check` clean.
- **Native:** nothing under `android/`, `ios/` or `pubspec*` changed, so
  Kotlin JVM and typecheck were not rerun (P8 M3 baseline: 306, exit 0).

**Targeted mutation checks: 29/30 killed, 1 equivalent**
(`Phase9_M3/run_m3_mutations.py`, outside the repo; each mutant run against
the M3 suites only; compile errors reported separately (none); restoration
verified byte-identical):
- **eligibility (11/11):** advisories listed; stale issues repeated; setup
  as a failure; optional items during setup; unreadable dismissals treated
  as none; level / re-lock dismissals ignored; held native level ignored;
  unconfirmed level credited for re-lock; shortest instead of nearest
  proposal; proposal that changes nothing;
- **priority (4/4):** OFFLINE ranked as attention; order reversed; setup
  tagged optional; Check-again repair sent to Health Details;
- **score integrity (2/2):** a dismissal alters a score input; the level
  action auto-applies the suggestion;
- **unavailable states (6/7):** apps failure, failed health worded as never
  checked, running check, calm despite unreadable dismissals, card note
  hidden, calm shown whenever ready. **U5 (calm despite a stale check)
  survives and is equivalent:** a stale report always carries the
  `health_snapshot_stale` issue (the report constructor is private to the
  engine), so the item list is never empty when stale; the explicit check
  stays as defence in depth;
- **lifecycle (6/6):** stale-response guard; dismissal not persisted / a
  saved dismissal not hidden; wrong scroll target; no lazy-list scroll;
  Apps tab ignores Security Center dismissals.
- **dismissal persistence, final gate (4/4):** platform write failure
  treated as saved; no rollback of an unsaved dismissal; Security Center
  hides on a failed save; Apps tab hides on a failed save. S1, L2 and L3
  were re-anchored to the corrected code and rerun (3/3 killed); all 34
  anchors match exactly once.

The first mutation run killed 25/30. E4, L1, L4 and L5 survived because the
new tests did not yet cover them: apps without a PIN; an older read that
differs from the newer one; a viewport where the Re-lock section is not
built. Those tests were strengthened, not the mutants weakened.

Not covered automatically: real devices and OEM skins, real Settings round
trips, TalkBack, real font scaling, a real Android disk-write failure (the
failing-store path is simulated through `AppContainer.inMemory(keyValueStore:)`
and a `SharedPreferences` fake), and the native watcher and Accessibility
service.

## Phase 9 / M3 device QA (adds to the consolidated plan; not executed)

Session 1g of the consolidated round (Oppo A9, after Session 1f). Same
setup: PIN, grace 30 s, A = Standard, B = Sensitive, C = Critical (none on
the catalog). Baseline expectation: one optional item, "Now: 30 seconds ·
Suggested: Immediate".

**Fail rules:**
- a recommendation button changes a level, the grace period or protection,
  unlocks an app or touches a challenge;
- an optional item above a protection problem;
- the calm state while a problem is present, while out of date, failed or
  checking, or with unreadable data;
- a problem still listed after a restore and return;
- a dismissal that changes the score, a level or the grace period;
- "%", guaranteed, secure, urgent, premium or upgrade wording.

| Step | Actions | Expected |
| --- | --- | --- |
| RC1 Setup (record) | Fresh install before the PIN; no apps protected. | Setup-tagged steps only; buttons scroll to Authentication / open Apps. |
| RC2 Baseline | Tap "Show Grace period". | One optional re-lock item; scrolls to Re-lock; grace still 30 s, score 90. |
| RC3 Permission issue | Usage Access off → return → Health Details → Back; restore → return. | The health problem is the first item (no dismiss); removed after restore with no tap. |
| RC4 Critical + OFFLINE | Overlay off → return; restore → return. | Problem first; no safety claims; no number. Restore: removed, 90. |
| RC5 Level (record, catalog app only) | Protect catalog app D at Standard; Review in Apps; raise in Apps; lower (PIN). | "D: Standard → Sensitive"; nothing changes by itself; removed after the user raises; lowering asks for the PIN. |
| RC6 Dismissal | Dismiss the re-lock item; restart the app; (RC5) dismiss D. | "Suggestion hidden. No level or setting was changed."; hidden; score 90 and grace 30 s unchanged; still hidden after restart; the Apps tab hint is gone too. Never "Couldn't save your choice" on a healthy device (a save failure cannot be forced on device; simulated only). |
| RC7 Re-lock change | Immediate, 5 minutes, 30 seconds. | 100 / no item; 86 / "Now: 5 minutes · Suggested: 1 minute"; 90 / still dismissed. |
| RC8 Stale | Idle 60 s on Security; Check again. | No number; only "Status is out of date"; never the calm state; Check again restores. |
| RC9 Pending challenge | C challenge → Home → Security → recommendation buttons → C. | The challenge stays on top; exact PIN only. |
| RC10 Display (record) | Dark mode, largest font, TalkBack. | Readable; heading announced; level line read as one phrase. |

**Minimum acceptance:** RC2, RC3, RC4, RC6, RC7, RC8 and RC9 on the Oppo.
Release blockers: RC3, RC4, RC6, RC8 and RC9. RC1, RC5 (only with an
installed catalog app) and RC10 are recorded. The full plan copy is
`Phase9_M3/P6_P9_CONSOLIDATED_QA_PLAN.md` (outside the repo).

**Status:** implemented and simulated-tested. It is **not device verified**
(the combined Phase 6–10 round is deferred, not waived) and **not release
ready** until that round passes, including E13, F3 and biometric.

# Phase 10 / M1 — Smart Rules: rule model, evaluation engine & conditions

## Automated evidence (Phase 10 / M1)

All results are **SIMULATED**: production model, codec, evaluator and
repository code; storage faults injected at the `LocalDatabase` boundary;
the app suites run over the container's in-memory stores and static
platform services. No device, real SQLite file, native watcher or OEM
behaviour is observed.

| Suite | Tests | Covers (brief items) |
| --- | --- | --- |
| `test/rules/smart_rule_model_test.dart` (new) | 26 | 1 valid construction (fields, default enabled, unmodifiable lists, trimmed name, id grammar, equality/hashCode on every field, copyWith keeps the id and re-validates); 2 invalid names (blank, whitespace, > 80, control characters; Unicode allowed); 3 empty target set rejected (never "all apps"), 15 malformed package forms rejected and never rewritten; 4 exact de-duplication, sorting, case-distinct ids never merged; 5 invalid weekdays and the Monday = 1 … Sunday = 7 mapping (`previous(1) == 7`); 6 empty days rejected, duplicates normalized; 7 minutes outside 0..1439 and zero-length windows rejected, all day explicit; 8 deterministic rule and document round trips, exact v1 document text, duplicate ids refused; 9 newer version → unsupported (version kept), never-written versions → corrupt; 10 broken JSON and wrong shapes, 23 invalid or non-canonical rules each making the whole document corrupt, duplicate stored ids |
| `test/rules/smart_rule_evaluator_test.dart` (new) | 33 | 11 match with full diagnostics; 12 disabled never matches and is reported first; 13 non-target, no substring/prefix/suffix/case matching, multiple targets; 14 malformed package and UTC instant → invalidInput with no condition evaluated, distinct from noMatch; 15–17 09:00–17:00 boundaries to the millisecond, midnight, windows at 00:00 and 23:59; 18–19 22:00–06:00 both sides of midnight, the PRD Monday example (Tue 02:00 owner Monday; Tue 06:00 and Tue 23:00 no match; Mon 02:00 owner Sunday); 20 Sunday → Monday rollover, month/year boundary; 21 weekdays, weekend, non-contiguous days, Friday-night carry into Saturday; 22 explicit all day; 23 zero-length windows impossible, a one-minute window; 24 repeated evaluation equal, plus an exhaustive 7 × 1440-minute sweep of three rules against an independent reference implementation; 25 inputs unchanged, no clock read (1999/2099 dates) |
| `test/data/smart_rule_repository_test.dart` (new) | 21 | Settings stored in a real temp file, so a restart is a new database plus a new repository. 26 save/read in order, v1 document under one key; 27 upsert in place, identical save writes nothing, concurrent operations serialized; 28 delete, unknown id → notFound with no write; 29 enabled state survives restart, re-enable; 30 failure before storing, a write that lands then fails (rolled back), first-ever write rolled back by removing the key, success reported but not stored (read-back catches it), failing rollback still surfaces the original error, recovery on the next write; 31 storage unavailable: reads fail, every write refused with no write; 32 broken JSON, one invalid rule among valid ones, newer version: read fails (never an empty list), every write refused, bytes unchanged, also from a fresh instance; 33 every operation visible after restart; 34 through `AppContainer`: only the `smart_rules` key is written, watcher counters, policies and authorizations unchanged, level, grace and legacy rules unchanged |
| `test/regression/smart_rules_m1_regression_test.dart` (new) | 4 | 35 five-tab navigation, the Smart tab still the placeholder, a saved rule never shown, zero reads of the rule key at startup and on every tab; 36 Standard/Sensitive/Critical stored and simulated-native levels, watcher counters and a full re-sync unchanged by a saved, matching, enabled rule; 37 Phase 9 score and recommendation keys identical with saved rules, before and after a restart; 38 a pending PIN challenge stays on top through rule saves, disable, delete and evaluation; a wrong PIN is refused and only the exact PIN grants |
| Existing suites (P1–P9) | unchanged, all pass | including the Phase 1 `LockRule`/`RuleEngine` tests (scaffolding untouched) |

**Totals:**
- **Full Flutter:** **+1543, all passed**, EXIT 0, no skips or reruns
  (1459 Phase 9 / M3 baseline + 84 new: 26 + 33 + 21 + 4).
- **New suites, first run:** **+84, all passed**. The only earlier failure
  was a compile error caught by `flutter analyze` before any test ran (a
  test helper typed `Matcher` instead of `TypeMatcher`, so `.having` was
  undefined), fixed in the test.
- **Static checks:** `flutter analyze` clean; scoped `dart format` on the
  10 new or changed Dart files (4 reformatted before the full run, then 0
  changed); `git diff --check` clean.
- **Native:** nothing under `android/`, `ios/` or `pubspec*` changed, so
  Kotlin JVM and typecheck were not rerun (P8 M3 baseline: 306, exit 0).

**Targeted mutation checks: 30/30 killed** (`Phase10_M1/run_m1_mutations.py`,
outside the repo; each mutant is run against the M1 suites only; compile
errors are reported separately (none); restoration verified byte-identical):
- **off-by-one boundaries (7/7):** same-day start exclusive or end
  inclusive; overnight start exclusive or end inclusive; zero-length window
  allowed; seconds rounded up; minute 1440 accepted;
- **overnight owner day (2/2):** after-midnight part owned by the current
  day; day condition ignored;
- **weekday mapping (3/3):** Monday's previous day 0; day 0 accepted;
  Sunday = 0 convention;
- **exact targets (5/5):** prefix match; case-insensitive match; empty
  target set accepted; malformed evaluated package not rejected; package
  ids trimmed;
- **disabled bypass (2/2):** disabled rule matches; enabled state not
  persisted;
- **failed write rollback (4/4):** no rollback; failure reported as
  success; no read-back confirmation; operations not serialized;
- **corrupt serialization (6/6):** corrupt read as empty; invalid rules
  skipped; newer version reported as corrupt; non-canonical days accepted;
  unknown fields accepted; duplicate ids accepted;
- **time-zone policy (1/1):** UTC accepted.

Not covered automatically: the real SQLite file and plugin (the repository
test uses a file-backed fake of the `LocalDatabase` boundary), a real
process death, device clock and time-zone changes, and every device or OEM
behaviour.

## Phase 10 / M1 device QA (adds to the consolidated plan; not executed)

Session 1h of the consolidated round (Oppo A9, after Session 1g), updating
the Session 1g build in place (`adb install -r`). M1 has no rule UI, so on a
device it must be invisible:

| Step | Check | Expected |
| --- | --- | --- |
| RS1 In-place update | Note levels, score, recommendations, grace; update; reopen. | Everything identical (score **90**, A/B/C levels, grace 30 s, dismissals); no crash; schema unchanged. |
| RS2 Smart tab | Visit every tab, then Smart again. | Same placeholder; no rule, toggle, "active" or "enforcing" wording. |
| RS3 No enforcement change | A, B, C leave/return as in Session 1c. | A within 30 s no challenge; B after 15 s; C every return. |
| RS4 No challenge interruption | C challenge → Home → Smart tab → C. | Challenge re-presents; only the exact PIN opens C, once. |
| RS5–RS9 | Saved rule across a real restart; Wed 08:59/09:00/16:59/17:00; Sun 22:00–06:00 at Sun 23:00, Mon 01:00, Mon 06:00, Mon 23:00; target vs look-alike; rejected and corrupt rules. | **HARNESS: DEFERRED, not waived** until the M2 UI or an approved debug harness exists. Expected values are in the consolidated plan. |

Release blockers: RS1, RS3, RS4. RS5–RS9 must pass before Phase 10 is
called complete. F3, biometric, E13, Q6 and the combined Phase 6–10 round
remain open.

**Status:** implemented and simulated-tested. It is **not device verified**
and **not release ready**.

# Phase 10 / M2 — Smart Rules: security-level actions & rule management UI

## Automated evidence (Phase 10 / M2)

All results are **SIMULATED**:
- Dart: production policy, repository, bootstrap, access controller and UI
  code over the container's in-memory stores and the static watcher. The
  static watcher mirrors the native rule resolution (applied / held / kept)
  and its persistence.
- Kotlin: production `SmartRulePolicy`, `ProtectionStateStore` and
  `ProtectionAccessState` on the JVM, with a stub Android `Context`.

No device, real watcher, real clock change or OEM behaviour is observed.

| Suite | Tests | Covers |
| --- | --- | --- |
| `test/rules/smart_rule_policy_m2_test.dart` (new) | 16 | **Floor:** 1 effective = max(baseline, rule) for every baseline × action; 2 Standard and Unlocked never take part; 3 disabled, non-target and UTC instants never match. **Conditions:** 4 overnight window owned by its start day, end exclusive; 5 overlapping rules → strictest (M2 interim). **Change analysis:** 6 disable/delete/narrow/lower → relaxed (CR-2); 7 widen/raise/rename → nothing relaxed; 8 `raisedAt` only for apps stricter now. **Transport and cache:** 9 enabled raising rules only, canonical; 10 cache per instant, last good copy kept. **Schema:** 11 v1 → v2 keeps every field, action = Standard; 12 v1 with an action key, v2 without one, or an unknown action → corrupt (no Standard fallback); 13 v2 round trip incl. reserved Unlocked; 14 a v1 store reads migrated and is written as v2 only on a user write; 15 a future version fails closed, bytes unchanged. **Writes:** 16 compare-and-swap conflicts write nothing |
| `test/protection/smart_rule_enforcement_m2_test.dart` (new) | 10 | **Bootstrap ↔ native:** 17 the snapshot carries only enabled raising rules, with the per-call ack; 18 an unreadable document sends no rules (native keeps its own) and the Dart cache keeps the last good copy; 19 a reduction without the CR-2 flag is held as the stricter union, and is applied with it. **Access controller:** 20 a rule raise ends an older, laxer session; 21 a rule ending gives no grace or authorization; 22 the floor holds (Sensitive never lowers Critical); 23 a clock moved back or forward is evaluated at each decision; 24 no inherited grace when a rule starts during grace. **Ack parsing:** 25 only an exact `ruleStatus` is trusted; a failed configure is a failed sync |
| `test/ui/smart_rules_screen_m2_test.dart` (new) | 26 | **33 List:** empty, read error with Retry (never an empty list), corrupt and newer-version states, row content. **34–37 Create:** full flow saved and sent, "confirmed" only after the ack, with no relaxation flag on a raise; 34b no ack → "Saved, but…"; 35 validation; 36 only protected apps; 37 Unlocked not selectable. **38 Toggle:** disable needs the PIN, cancel changes nothing, the switch follows storage; enabling needs no PIN, sends no relaxation flag and ends a laxer session; a failed write keeps the switch; state survives restart. **39 Draft guard:** unchanged, dirty + Keep editing / Discard, edit revert, save success, save failure keeps the draft, routes on top (CR-2, lock challenge) never intercepted, stale form never overwrites. **Delete and held:** delete needs the PIN; held reduction notice confirmed with the PIN. **40 Accessibility:** 320 dp at 2× text in light and dark mode, semantics. **CR-2 proof scope:** empty set, unconfirmed package, expired and reused proofs refused; one valid use writes once. **Presentation:** day and time summaries |
| `test/regression/smart_rules_m2_regression_test.dart` (new) | 5 | M2-R1 Phase 8 levels not overwritten, native levels unchanged, rule level simulated; M2-R2 Phase 9 score and recommendations unchanged before/after a raising rule and after restart; M2-R3 a Standard app under a Critical rule is challenged and a wrong PIN never grants; M2-R4 a pending challenge survives a rule change, a raise ends the open session, a grant covers only its app; M2-R5 after restart rules are re-sent, the cache gives Critical, navigation intact |
| `SmartRuleEnforcementTest.kt` (new, JVM) | 24 | Same-day start inclusive / end exclusive; overnight owner day; Sunday → Monday; Calendar → ISO weekday; exact package match; floor; strictest of several; relaxation detection; transport validation; resolver kept/held/applied/invalid; codec round trip and damage; persisted rule inside/outside its window; overnight across the store and week; unauthorized removal held, authorized applied; omitted or malformed rules keep the stored ones; a failed commit never weakens and reports `persisted=false`; damaged store → Critical; legacy store without rules → baseline; clock moves switch only the extra strictness; time zone read at each decision; DST skipped and repeated hours; a rule start revokes a lower grant at the next decision; a rule end gives no authorization or grace; the same level keeps the H-2 slide |
| Updated M1 suites | 26 / 21 / 4 | Model and repository tests use schema v2 (v1 still read). M1 regression test 35 now expects the Smart tab to list a saved rule as "Standard · adds no protection", never "Active", with no rule writes when navigating |

**Totals:**
- **Full Flutter:** **+1600, all passed**, EXIT 0, no skips or reruns
  (1543 + 57 new: 16 + 10 + 26 + 5). Run 2 gave the same result. Two
  assertions (no relaxation flag on raises) were then added to the UI
  suite, and run 3 is the final result.
- **Kotlin JVM:** **OK (330)** = 306 + 24 new. **Typecheck:** exit 0, 87
  classes.
- **Static checks:** `flutter analyze` no issues; `dart format` 0 changed on
  the 24 new or changed Dart files (`unprotect_gate.dart` was unformatted at
  the baseline and is not reformatted; its new hunk is formatted);
  `git diff --check` clean.
- Run 1 (before fixes) failed with 273 timeouts. Their cause was a spinner on
  the inactive Smart tab inside the `IndexedStack`, which kept
  `pumpAndSettle` waiting in every full-app test. Fixed in production: an
  inactive tab never shows a spinner, and a missing container shows an error
  state.

**Targeted mutation checks: 27/27 killed, 0 invalid**
(`Phase10_M2/run_m2_mutations.py`, outside the repo; one production spot per
mutant; Dart mutants run the M2 suites and Kotlin mutants run
`SmartRuleEnforcementTest`; restoration verified byte-identical):
- **floor (2/2):** effective level ignores the baseline; controller takes
  the rule level over the saved one;
- **Unlocked / migration / schema (5/5):** Unlocked raises; Unlocked
  selectable; v1 migration activates rules; unknown action → Standard; a
  newer version read as current;
- **ack (1/1):** "confirmed" without an applied ack;
- **CR-2 / enable-disable (4/4):** reductions skip CR-2; relaxation flag
  on every change; empty package set accepted; partial coverage accepted;
- **stale state / rollback (4/4):** unreadable rules sent as empty; cache
  cleared on a failed read; compare-and-swap disabled; no rollback after a
  failed read-back;
- **challenge / grace isolation (3/3):** laxer session survives a raise;
  rule end turns a strict unlock into grace; change flow keeps sessions made
  stricter;
- **editor (2/2):** draft guard disabled; empty app selection not
  reported;
- **native (6/6):** floor ignored; overnight tail owned by the current day;
  end inclusive; unconfirmed relaxation accepted; damaged store → baseline;
  grant not revoked on a rise.

Not covered automatically:
- the real watcher on a device, and real clock, time-zone or DST changes;
- process death during a commit, and the OEM `SharedPreferences` behaviour;
- TalkBack output;
- every OEM behaviour.

### Persistence gate: failed-reduction rollback (Option A) and start-up floor (R-A)

SIMULATED (Flutter test environment, and the JVM for the native gate
harness kept outside the repository). No device.

| Suite | Tests | Covers |
| --- | --- | --- |
| `test/ui/smart_rules_reduction_rollback_m2_test.dart` (new) | 13 | **Option A:** A success; B/C a PIN-confirmed reduction that fails before or after reaching native storage → previous rules restored exactly (CAS), re-sent without the relaxation flag, "Couldn't apply the change. Your previous rule settings will be restored.", never saved, no session or authorization; D the restore also fails → its own message, never "Nothing was changed"; E exact list and order restored, editor open; the draft is kept for a retry that asks for the PIN again; H cancel writes nothing and sends no flagged snapshot; 3 `replaceRules` unit tests. **confirmHeldRuleRelaxation:** CH-1 a confirmation that lands but reports failure → unflagged re-sync, native re-holds the stricter rules, "still apply" only then; CH-2 confirmation and re-sync both fail → "Couldn't confirm…" (neither outcome claimed); CH-3 cancel sends nothing |
| `test/regression/smart_rules_startup_floor_m2_test.dart` (new) | 8 | **R-A:** RA-1 cold start before the first rule read → challenge, Critical grant (1-minute window, no grace), saved levels unchanged; RA-2 failed start-up read → Critical until a successful read, then actual levels and Standard grace; RA-3 a failed read after a good one revokes an open Standard session; RA-4 control after a successful sync; RA-5 unprotected apps unaffected, nothing newly protected or authorized; RA-6 restart after an ambiguous failed relaxation (native weaker, storage restored) → Critical before the sync, stricter rules re-applied by it; RA-7/RA-8 through the real lock host: a PIN unlock after a failed read or during the cold-start read sends the Critical floor to native `authorizePackage`, and returning inside the Standard grace challenges again |
| Updated Phase 5/8 suites | 10 tests | `security_level_enforcement_test` (1, 2, 5/6, native-gate grant), `lock_trigger_test` (two grace tests), `process_recreation_test` (two grace tests) now run the start-up rule load (`protectionBootstrap.synchronize()`) before asserting Standard/Sensitive grace; `security_level_qa_matrix_test` restart shares the secret store (a restart keeps the Keystore). The assertions are unchanged |

The native durability gate harness (`Phase10_M2/gate/NativeDurabilityGateTest.kt`)
gives 16 of 16. G1 native only; G2/G3 a grant with the Critical floor
(rules loaded, or R-A before they are known); G4/G5 the gap closes at the
first Dart sync. A record test shows that native alone still relies on
the floor Dart sends.

## Phase 10 / M2 device QA (adds to the consolidated plan; not executed)

Session 1i (RX1–RX12) of the consolidated plan
(`Phase10_M2/P6_P10_CONSOLIDATED_QA_PLAN.md`):
- update in place;
- the create flow and validation;
- a raising rule enforced;
- no inherited grace;
- rule end with no free pass;
- reductions needing the PIN/pattern;
- the floor;
- restart;
- clock and time zone;
- the draft guard;
- accessibility;
- Phase 9 unchanged.

With the M2 build, RS5–RS9 run through the UI except the RS9
corrupt-document check (still DEFERRED).

Release blockers:
- RX1, RX3–RX7;
- RX8 (a);
- RX9 (a) and (c);
- the challenge part of RX10;
- RX12.

F3, biometric, E13, Q6 and the combined Phase 6–10 round remain open.

**Status:** implemented and simulated-tested. It is **not device verified**
and **not release ready**.

## Automated evidence (Phase 10 / M3)

All results are **SIMULATED**:
- Dart: production conflict policy, diagnostics, bootstrap, access
  controller and Smart UI over `AppContainer.inMemory`, with the static
  watcher standing in for native.
- Kotlin: production `SmartRuleTransport`, `SmartRulePolicy` and
  `ProtectionStateStore` on the JVM, with a stub Android `Context`.

No device, real watcher, real clock or time-zone change, TalkBack or OEM
behaviour is observed.

| Suite | Tests | Covers |
| --- | --- | --- |
| `test/rules/smart_rule_conflict_m3_test.dart` (new) | 26 | **Priority:** the locked Critical > Sensitive > Standard > Unlocked list, and every action pair in both orders. **PRD 10J examples:** Std+Sens+Crit, Sens+Std+Crit, Crit+Sens → Critical; Std+Std → Standard; Crit+Unlocked → Critical; none → baseline; disabled ignored. **Overlap 1–10, K:** two and three-plus rules; same-level tie (first sorted id); insertion order never changes the level or the deciding rule; disabled or non-matching higher-priority rules never count; overnight owner day; Sunday → Monday; all-day vs timed; removing the winner falls back to the next strongest; no leakage across apps. **CR-2 interplay:** deleting, disabling or lowering the winner is a reduction; deleting a fully outranked rule, adding a weaker rule or reordering is not |
| `test/rules/smart_rule_diagnostics_m3_test.dart` (new) | 13 | **16–18:** PRD example (Standard app with Work Hours + Banking Protection); ties; saved level decides; a Sensitive rule covered by the saved level; an unprotected app; overnight day mismatch names the owner day; invalid input. **19–20:** confirmed only for an `applied` ack of exactly these rules; a calculated Critical is never a confirmation; engine states; bootstrap record applied / held / failed / failed read. **21–22:** no secret or authorization state in any diagnosis; diagnosing performs no write, sync or native call |
| `test/rules/smart_rule_parity_vectors_m3_test.dart` (new) | 70 | **Shared vectors** (`test/fixtures/smart_rules/conflict_vectors.json`, also run by Kotlin). Per set (11): Dart sends exactly the fixture transport; hand-written cases; dense boundary grid; every permutation gives the same result. DST/time-zone instants; 21 reduction pairs (CR-2 / held boundary, order-independent); invalid stored rules rejected; invalid queries never match |
| `test/ui/smart_rules_diagnostics_m3_test.dart` (new) | 14 | Collapsed by default. Multiple matching rules: deciding / outranked / covered by the saved level / not protected. Refresh re-evaluates at the clock (nothing refreshes by itself) and falls back to the next strongest rule. Native status: confirmed only after `applied`; "not checked yet" before any exchange (with the R-A note); unsynced save → not confirmed + behind saved; held → held; failed write → never confirmed. Read failure → R-A note in the error card. No writes, configures or authorizations when opening or refreshing; saved levels unchanged. 320 dp at 2× text in light and dark; toggle semantics (button, expanded state, tap action) with the body read separately |
| `test/regression/smart_rules_m3_regression_test.dart` (new) | 16 | **Controller:** E/F/G strictest at each decision, with Dart = native fake and saved levels unchanged; A/D restart; L a stricter overlap ends a weaker session; M winner ending → no grace, then the Sensitive cap (not Standard); 8 no grace inheritance; N delete winner with CR-2 → fallback in Dart and native; I without CR-2 → held, covered rule deletion applies; P R-A before the first read; Q failed read then recovery; J lockout survives rule changes. **Smart UI:** deleting the winner needs the PIN (cancel keeps both, PIN → fallback); deleting a covered rule needs no PIN; switching off the winner needs the PIN. **Real app + lock host:** one PIN unlock under two overlapping rules sends exactly one native authorization, at the strictest level (Critical); a wrong PIN sends none. **Static:** the legacy LockRule/RuleEngine is not a second engine; diagnostics code reaches no credentials, sessions, secrets, writes, native authorization or timers |
| `NativeDurabilityRegressionTest.kt` (new, JVM) | 16 | The Phase 10 / M2 native persistence gate, now permanent. Production `ProtectionStateStore` with a scripted `SharedPreferences` (OK / FAIL_BEFORE_DISK / FAIL_AFTER_DISK; a restart loads only the disk copy). **S1:** an authorized relaxation is durable and acked; an unauthorized one is held durably. **S2/S3/S5a:** a failed relaxation or raise, before or after disk, with or without a successful rollback, is never weaker in memory or after a restart. **S5:** every failure combination is never weaker; memory is never weaker than disk. **S5b:** records the original ambiguous-write defect without Option A, and native restored at the first Dart sync with it. **G1–G5:** native-only cold-start gap challenged; PIN grant with the Dart floor loaded or under R-A gets no weaker grace (records that native alone relies on that floor); the gap closes at the Dart sync even if the write fails again; a weaker grant is revoked at the next decision |
| `SmartRuleParityVectorsTest.kt` (new, JVM) | 9 | The same fixture: shape; hand-written cases through pure `SmartRulePolicy` and through `ProtectionStateStore.configure` + `effectiveLevel` with a restart; dense grid (pure and store, at :00 and :59 s); transport order; DST/TZ instants via `TimeZone.setDefault`; invalid transports rejected with the previous rules kept; invalid queries; **21 reduction pairs:** `relaxes` = Dart, and the store HOLDS the stricter union without the CR-2 flag (checked across the week and after a restart), APPLIES with it |

**Totals (final code):**
- **Full Flutter:** **+1760, all passed**, EXIT 0, no skips or reruns
  (1621 + 139 new: 26 + 13 + 70 + 14 + 16).
- **Kotlin JVM:** **OK (355)** = 330 + 9 parity + 16 durability.
  **Typecheck:** exit 0, 87 classes.
- **Static checks:** `flutter analyze` no issues; `dart format
  --language-version=3.5` 0 changed on the 12 new or changed Dart files;
  `git diff --check` clean.
- Initial failures, all fixed:
  - 5 in the new UI suite (first run): 3 test-harness issues (a wrong
    error-card key, an order-dependent set, and a lazily built off-screen
    toggle) and **2 real accessibility defects** in the new details toggle.
    `excludeSemantics` had dropped the tap action, and the missing
    `container: true` merged the whole body into one button. Both were
    fixed in production. A follow-up assertion that matched the body's
    exact semantics label was changed to a pattern match plus a "not a
    button" check, because the body is read as one card node.
  - No other new suite failed on its first run.
- After the first full run, `dart format` rewrapped 7 new files (layout
  only). The full Flutter suite and all 19 mutants were then re-run on the
  formatted code with the same results. One mutant anchor (T2) was updated
  to the rewrapped line. The native-authorization regression test was added
  afterwards, so the full suite was run a third time (the totals above), and
  D1/D2 were run against it.

**Dart ↔ native parity:** no mismatch found, so no native code change. Two
native-only mutants (X1, X2) are caught by the shared vectors.

**Targeted mutation checks: 21/21 killed, 0 invalid**
(`Phase10_M3/run_m3_mutations.py`, outside the repo; one production spot
per mutant; Dart mutants run the 5 M3 suites; Kotlin mutants run
`SmartRuleParityVectorsTest`; restoration verified byte-identical):
- **priority reversal (3/3):** Dart; native; Unlocked outranking Critical;
- **tie instability (2/2):** unsorted ids; last id decides;
- **second overlapping rule ignored (1/1);**
- **winner removal without fallback (2/2):** Dart cache cleared on a
  removal; native authorized reduction applying no rules;
- **parity mismatch, native only (2/2):** inclusive end; reduction check
  ignoring window ends;
- **half-open boundary, Dart (1/1);**
- **false confirmed status (3/3):** no transport comparison; no record;
  failed exchange;
- **startup floor removal (1/1);**
- **CR-2 bypass (2/2):** gate skipped; a lowering under an overlap not
  seen as a reduction;
- **grace inheritance (2/2):** leave grace from the current level; a
  stricter level not ending a weaker session or grace;
- **native authorization (2/2):** one unlock authorizing twice; the
  authorization sent without the strictest level floor.

Not covered automatically:
- the real watcher on a device;
- real clock, time-zone or DST changes;
- process death during a commit;
- TalkBack output;
- OEM behaviour.

## Phase 10 / M3 device QA (adds to the consolidated plan; not executed)

Session 1j (RM1–RM14) of the consolidated plan
(`Phase10_M3/P6_P10_CONSOLIDATED_QA_PLAN.md`):
- update in place;
- two and three overlapping rules;
- equal levels;
- removing or turning off the winner (PIN, fallback to the next strongest);
- deleting a covered rule (no PIN);
- overnight overlap;
- a stricter rule starting during a weaker unlock;
- confirmation only with an ack;
- accessibility;
- the details never changing anything;
- restart;
- clock moves never going below saved levels.

Release blockers:
- RM1, RM2, RM5–RM9;
- RM10 (a) and (b);
- RM12, RM13 (a), RM14.

F3, biometric, E13, Q6 and the combined Phase 6–10 round remain open.

**Status:** implemented and simulated-tested. It is **not device verified**
and **not release ready**.

# Phase 11 / M1 — Security Profiles: profile architecture & presets

## Automated evidence (Phase 11 / M1)

All results are **SIMULATED**:
- Dart: production profile model, document, repository, policy, bootstrap
  and access controller over `AppContainer.inMemory`, with the static
  watcher standing in for native.
- Kotlin: production `SmartRuleTransport`, `SmartRulePolicy` and
  `ProtectionStateStore` on the JVM, with a stub Android `Context` and
  in-memory `SharedPreferences` (AOSP failed-commit semantics).

Non-Normal profiles are activated **only by the test harnesses**; no user
can activate one in M1. No device, real watcher, TalkBack or OEM behaviour
is observed.

| Suite | Tests | Covers |
| --- | --- | --- |
| `test/profiles/security_profile_model_test.dart` (new) | 16 | **Presets:** five, canonical order, Normal active; only Guest adds protection; no Settings / Play Store / any app enrolled (D3); Work is an in-app profile (D2). **Raise-only (D1):** Standard rejected for "all" and per-app; Sensitive/Critical accepted; Normal adds nothing; Guest is exactly all Critical; invalid package, own package and more than 512 apps rejected. **Exactly one active:** unknown or empty id rejected; every preset can be the single active one; duplicates and missing presets rejected; input order irrelevant; unmodifiable. **Document:** round trip; not JSON / not an object → corrupt (never defaults); legacy `isActive` flag rejected |
| `test/profiles/security_profile_policy_test.dart` (new) | 16 | **Compilation:** Guest → one all-day, every-day Critical entry over the protected apps; no protected apps → no entry (empty targets never mean all); per-app entries grouped by level; Normal → transport identical to rules-only. **`transportLevelFor`:** "all protected apps" never reaches an unprotected app. **Raise-only:** effective ≥ baseline, ≥ rule and ≥ overlay over every level, day and boundary; the overlay is time-independent; stricter rule vs weaker overlay and vice versa. **D6:** leaving Guest relaxes all protected apps; entering or staying relaxes nothing; editing down or removing an app relaxes it. **Cache (R-A):** not current until read; a failed read keeps the last good profile (never Normal) and is not current; `normalOnly` |
| `test/profiles/security_profile_parity_vectors_test.dart` (new) | 58 | **Shared vectors** (`test/fixtures/security_profiles/profile_vectors.json`, also run by Kotlin). Presets equal the fixture; per scenario (7): Dart compiles exactly the overlay transport and sends exactly the combined transport (Normal: byte-identical to rules-only); 23 hand-written cases (rule, overlay, extra, effective, floor); dense grid (effective and engine level, plus the Dart floor's `transportLevelFor` view incl. unprotected targets). 11 switches/edits: transports and `relaxedPackages` match the brute-force oracle. 17 invalid documents rejected with the expected problem |
| `test/data/security_profile_repository_test.dart` (new) | 13 | Nothing saved → defaults, no write; save confirmed by read-back; **CAS** stale `expected` → conflict, no write; identical save → no write; corrupt / newer version → read error, write refused, value untouched; storage read error → `storageUnavailable` (never defaults); failed write → `writeFailed` with the key removed or the previous value restored; unconfirmed (dropped) write never reported as saved; a failing restore still reports the write failure; serialized concurrent saves; only its own key touched (legacy `profiles` table untouched) |
| `test/regression/security_profiles_m1_regression_test.dart` (new) | 14 | **Normal:** transport exactly rules-only, no profile document written, levels unchanged; empty transport with no rules. **Guest (harness):** R-A Critical before the first read; combined transport sent and applied; Dart grants Critical; unprotected app untouched; saved levels, protected set and native levels unchanged; engine stand-in Critical. **Kids (harness):** per-app Sensitive raises only that app; an unprotected app in the profile is never protected or challenged. **D6:** leaving Guest without authorization → HELD (stricter union kept), with the flag → APPLIED; nothing authorized. **R-A:** profile read failure → no transport (KEPT), Critical floor, recovery; corrupt document never replaced or overwritten; failed read after Guest keeps Guest; rule read failure → no transport. **Static:** no legacy LockProfile use; no timers / polling / isolates; no `saveProfiles` caller outside the repository; Health/Score code never reads profiles; no Settings / Play Store package |
| `SecurityProfileParityVectorsTest.kt` (new, JVM) | 6 | The same fixture through UNCHANGED native code: shape; Normal transport = rules transport; 23 cases via pure `SmartRulePolicy` and `ProtectionStateStore.configure` → `effectiveLevel` with a restart (saved level never rewritten; unprotected apps not protected); dense grid (pure and store, at :00 and :59 s); 11 switches: `relaxes` = Dart, unauthorized relaxation HELD as the stricter union (also after restart), authorized APPLIED; a failed durable write of a relaxing switch (even authorized) is never reported as persisted and never weaker live or after restart |

**Totals (final, formatted code):**
- **Full Flutter:** **+1877, all passed**, EXIT 0, no skips
  (1760 + 117 new: 16 + 16 + 58 + 13 + 14).
- **Kotlin JVM:** **OK (361)** = 355 + 6 profile parity.
- **Static checks:** `flutter analyze` no issues; `dart format
  --language-version=3.5` on the 13 new or changed Dart files;
  `git diff --check` clean.
- Initial failures, all fixed:
  - Kotlin parity, first run: 3 test-harness failures (a fixed snapshot
    session id reused across JUnit instances, so native correctly rejected
    the snapshots as stale). Fixed with a unique session per instance.
  - Regression, first run: **1 real defect** found and fixed in production:
    with Guest/Kids active, the Dart floor gave an UNPROTECTED app the
    profile's "all protected apps" level (stricter, never weaker, and the
    app was never challenged; native was unaffected). The Dart floor now
    mirrors the compiled overlay (`transportLevelFor`). Also 1 static-test
    false positive (a doc comment naming the legacy file); the check now
    ignores comments.

**Dart ↔ native parity:** no mismatch found; **no native code change.**

**Targeted mutation checks: 24/24 killed, 0 invalid**
(`Phase11/run_p11m1_mutations.py`, outside the repo; one production spot
per mutant; Dart mutants run the 5 new suites; Kotlin mutants run
`SecurityProfileParityVectorsTest`; restoration verified byte-identical):
- **validation (7/7):** Standard overlay accepted; Normal with an overlay;
  active id naming no profile; duplicate preset; Guest not Critical; own
  package; newer version accepted;
- **compilation and combination (6/6):** "all" entry dropped; wrong level;
  "all" entry with no protected apps; "all" leaking to unprotected apps;
  D6 relaxation ignoring the overlay; failed read falling back to Normal;
- **bootstrap / R-A (4/4):** `extraLevelFor` ignoring the profile;
  `extraLevelsCurrent` ignoring the profile read; rules-only transport;
  sending a stale profile after a failed read;
- **repository (4/4):** corrupt read as defaults; read-back mismatch
  accepted; CAS skipped; failed write not rolled back;
- **native, unchanged code (3/3):** all-day entries never matching;
  relaxation checking only packages still targeted; effective level
  ignoring the rule/overlay level.

Not covered automatically: the real watcher on a device; process death
during a commit; TalkBack; OEM behaviour.

## Phase 11 / M1 device QA (not executed)

M1 has no user-facing change: every user is on Normal, whose transport is
byte-identical to Phase 10. A device check is therefore limited to:
- a Phase 10 rules smoke test (unchanged behaviour);
- confirming no `security_profiles` setting is written on upgrade.

Profile switching QA belongs to M2.

F3, biometric, E13, Q6 and the detailed Phase 6–10 sessions remain open.

**Status:** implemented and simulated-tested. It is **not device verified**
and **not release ready**.

# Phase 11 / M2 — Security Profiles: manual switching & custom profiles

## Automated evidence (Phase 11 / M2)

All results are **SIMULATED**: production profile, bootstrap, gate,
switching and UI code over `AppContainer.inMemory`, with the static watcher
(which mirrors the native `SmartRuleSnapshotResolver`: unflagged relaxing →
HELD union; flagged → APPLIED from whatever it holds) standing in for
native. **No native code changed.** Proofs are minted through the real PIN
screen. No device, real watcher, TalkBack or OEM behaviour is observed.

| Suite | Tests | Covers |
| --- | --- | --- |
| `test/profiles/security_profile_m2_model_test.dart` (new) | 15 | **Custom model:** id `custom-` + 12 lowercase hex only; names trimmed, 1–32 characters, no control characters, unique ignoring case (incl. presets); raise-only (no Standard, no own package); presets keep their names, Normal/Guest immutable, Home editable but not removable; duplicate ids refused; at most 20 custom profiles and 2048 entries; canonical order; deleting the active profile makes Normal active; unknown/preset deletes refused; unique new ids; a custom profile compiles exactly like a preset with the same levels. **Document v2:** round trip with names; v1 decodes losslessly; 8 corrupt v2 variants rejected (renamed preset, untrimmed name, bad id, missing/extra key, duplicate name, unknown active, Standard); a v1 custom entry is corrupt; newer versions unsupported |
| `test/protection/bound_relaxation_m2_test.dart` (new) | 20 | **Exact protocol:** Guest → Normal asks the proof for exactly the relaxed apps; an unflagged probe of Guest precedes ONE flagged Normal; the document is committed only after the ack; nothing granted; nothing relaxed → no proof and no flag. **Isolation:** native holding an unrelated rule reduction → a profile reduction is `blocked` (no flag, rule still enforced); the reverse (held profile blocks a rule flag); wrong before-binding → `conflict`, nothing sent; a concurrent rule change → `conflict`; refused proof → `denied`, nothing sent; unprotected apps never in scope. **Precedence:** the stricter of overlay and rule decides in both directions on the Dart floor, the access decision and native. **Ack/recovery:** flagged write failing before or after apply → stricter state re-sent and acknowledged, document never committed (`notApplied`); recovery also failing → `unknown`; probe failure → `unknown`, no flag; document write failing after native applied → raised back; **process death** after the flagged ack but before the commit → the restart (R-A floor first) re-applies Guest unflagged; restart with Guest loads one profile; `confirmSaved` bound to the displayed rules; `synchronize()` can no longer send the flag. **Final gate:** a probe native resolved but could not persist (`persisted=false`, held union) is `unknown` and never followed by the flag, the unrelated held reduction stays enforced; probe, flag and commit are one serialized section (a concurrent `synchronize()` waits and then sends the committed profile unflagged) |
| `test/ui/security_profiles_m2_test.dart` (new) | 28 | **Switching** through Smart card → Profiles: stronger (no PIN, applied only after the ack, open session revoked, saved levels unchanged, others never protected); weaker (PIN titled for profiles, no biometric; cancel and wrong PIN write and send nothing; PIN → ONE flag, no grant, no auto-open); a profile PIN never releases a held rule; equal (no PIN, no flag); failed save → nothing claimed; unconfirmed sync → "Saved, not confirmed yet" and a Critical Dart floor; stale screen → conflict, no write. **Final gate:** a failed lowering (flagged write failing → "previous profile is still active"; flagged write and recovery failing → "Couldn't confirm the change") never shows "Normal is active" or a false "Applied". **Management:** create with name validation, inactive save without native contact; discard dialog (keep editing / discard); failed save keeps the draft and a retry doesn't duplicate; active edit-down needs the PIN; inactive edits never do (no flag, no authorized package, Dart floor and native unchanged); deleting the active profile → Normal with the PIN; duplicate Guest; corrupt and newer documents → error states, nothing written. **CR-2 isolation with real PIN proofs:** a profile proof can't unprotect, downgrade, write or flag a rule, or confirm saved settings, and flags one profile change once; a downgrade proof flags nothing; a rule proof flags only its own written packages, once, never after `maxAge` or with the clock moved back, never a profile; profile proofs out of scope / expired / clock moved back / empty refused; `confirmSaved` proofs separate. **Session safety:** lockout unchanged by a switch, a weaker switch impossible while locked out; a pending challenge survives both directions; no package authorized, no grace; an existing Critical grant isn't turned into Standard grace. **UI:** 320 dp at 2× text in light and dark (Smart card, list, editor) without overflow; TalkBack reads the name and "Active" once, inactive tiles are buttons, choices are labelled "<app>: <level>"; "Applied" only after an ack |

Changed existing suites (deliberate, follow from the gate):
- `security_profile_parity_vectors_test.dart` (58): v2 entries carry the
  preset name (merged into the v1-shape vectors; presets compared on policy
  fields plus names separately). The shared fixture's "newer version"
  document is now version 3 (version 2 is current); regenerated by its
  generator, a one-value diff, `--check` current. Kotlin does not read
  `presets` or `invalidDocuments`.
- `security_profile_repository_test.dart` (13): the "newer version" case
  uses `SecurityProfileDocument.version + 1`.
- `security_profiles_m1_regression_test.dart` (14): D6-1 now leaves Guest
  through the bound protocol (the broad flag no longer exists); S-3 lists
  `profile_change.dart` as an allowed `saveProfiles` caller.
- `smart_rule_enforcement_m2_test.dart`, `smart_rules_m3_regression_test.dart`:
  authorized rule relaxations go through `applyBoundRelaxation`.
- `smart_rules_reduction_rollback_m2_test.dart` D/J: strengthened — after a
  failed reduction the previous rules are re-sent unflagged and applied.

**Totals (final, formatted code):**
- **Full Flutter:** **+1940, all passed**, EXIT 0, no skips
  (1877 + 63 new: 15 + 20 + 28).
- **Kotlin JVM (regression, no native change):** **OK (361)**; Phase 10
  rule parity **OK (9)**; profile parity **OK (6)** on the updated shared
  fixture.
- **Static checks:** `dart analyze lib test` no issues; `dart format
  --language-version=3.5` on the M2 Dart files (the sensitive
  `unprotect_gate.dart` is not reformatted); `git diff --check` clean
  (tracked and new files).
- Failures found while building M2, all fixed:
  - 3 expected failures from the v2 document in existing suites (parity
    loader, repository "newer version", M1 static S-3), updated as listed
    above; 2 more in the parity suite (presets with names; the fixture's
    "newer version" was version 2).
  - 1 **TalkBack defect** in the new Profiles list (the name and "Active"
    were read twice), fixed in production.
  - Test-only issues: a lazily built list at 320 dp, list order by label,
    a Guest setup that made a rule deletion non-relaxing.

**Targeted mutation checks: 25/25 killed, 0 invalid**
(`Phase11/run_p11m2_mutations.py`, outside the repo; one production
behaviour per mutant; runs the 3 new suites plus the M1 regression and the
R-A start-up floor suite; unmutated baseline +80 green; restoration
verified byte-identical). The first full run killed **20/22**; the two
survivors exposed real test gaps (a rule-reduction flag past `maxAge`; the
Dart floor with a rule and a profile at different levels). Tests were
added (CR-3 expiry, PR-1) and both were then killed. The final security
gate added 4 focused tests (GATE-1 to GATE-4) and 3 mutants, all killed:
- **PIN gate / CR-2 (6/6):** missing PIN gate; broad `packageChange` proof
  for profiles; intent ignored in `consumeBoundRelaxation`; rule flag not
  limited to written packages; single use dropped; expiry ignored;
- **bound protocol (8/8):** wrong before-binding; probe ack not checked;
  probe skipped; probe sends the after state; dropped rollback (relaxed
  state re-sent); unconfirmed recovery reported as restored; commit before
  the flag; profile cache not refreshed;
- **switching (4/4):** false applied ack; grace inheritance (no revoke);
  stale overwrite (CAS removed in both layers); inactive edit contacting
  native;
- **policy / R-A (4/4):** wrong priority; Guest protecting unprotected apps;
  R-A skipped; R-A ignoring the profile read;
- **final gate (3/3):** bound protocol not serialized; failed lowering
  (`notApplied`) reported as active; unconfirmed lowering (`unknown`)
  reported as active.

Not covered automatically: the real watcher on a device; real process
death; TalkBack speech; OEM behaviour.

## Phase 11 / M2 device QA (not executed)

Plan only: Session 1k (PS1–PS14) in the consolidated plan
(`Phase10_M3/P6_P10_CONSOLIDATED_QA_PLAN.md`, outside the repo). PS14 is
HARNESS only. F3, biometric, the unverified parts of E13 and Q6, and the
step-level Phase 6–10 sessions remain open release gates.

**Status:** implemented and simulated-tested. It is **not device verified**
and **not release ready**.
