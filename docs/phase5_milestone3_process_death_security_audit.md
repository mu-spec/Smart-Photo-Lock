# Phase 5 / Milestone 3: 5T Process-Death Recovery, Security Audit

| Item | Value |
|---|---|
| Repository | `https://github.com/mu-spec/Smart-Photo-Lock.git` |
| Branch / commit audited | `main` @ **`3277068ed7e4695cbc090c86ad9c4f0e6907dbee`** (Fix #3). Verified equal to `origin/main` with `git ls-remote`. |
| Package / device under QA | `com.smartapplock.app` / Oppo CPH2083, Android 9 (ColorOS) |
| Audit date | 2026-10-25 |
| Production code changed | **None.** `lib/`, `android/`, build files and `pubspec.yaml` are untouched. |
| Test-only change | **Added** `test/regression/process_death_recovery_test.dart` (7 *simulated* tests, see §8). Not committed. |
| **H-1 reconciliation** | **Updated 2026-10-25 on HEAD `e5ca340` + the uncommitted H-1 F1/F2 working tree.** The original T5 pinned the H-1 *bug* and was rewritten to the corrected behaviour; a companion genuine-leave test (T5b) keeps its security property. The file now has **8** simulated tests. Findings below are the original audit at `3277068` unless marked **[§15]**. See **§15**. |
| Physical device available to this audit | **No.** No device or emulator, and no Test B logcat was uploaded. Every device statement below is either a *user report* or an *inference*. |

---

## 1. Executive verdict

**Overall 5T verdict: UNVERIFIED.**

- Functional recovery works. The user reported it, and the code and simulation agree.
- Authorization fails closed after process death: verified in code and simulation.
- **Zero protected-content exposure is not proven, and the platform does not guarantee it.** Android removes a dead process's overlay window at once, and finishes the crashed foreground activity, so the app underneath can resurface. The new process can only re-cover it once it has been restarted. That window was not measured.

| # | Property | Verdict | Basis |
|---|---|---|---|
| P1 | Background crash (Test A): protection recovers and CamScanner stays protected | **PASS (user-reported)** | Physical Test A as reported by the user. The log was not reviewed by this audit. |
| P2 | Crash with challenge active (Test B Run 1): app restarts, challenge reappears, wrong PIN blocks, correct PIN opens | **PASS (user-reported), 1 run** | User report: PID 23326 → 27617, `WatcherService.onCreate` seen, wrong PIN blocked, correct PIN opened. One run only, no artifacts. |
| P3 | No authentication session or authorization survives process death | **PASS (code + simulated tests)** | Native authorizations, ready handoff and `activityResumed` are memory-only (`ProtectionAccessState`, `ProtectionRuntime` in `ProtectionStateStore.kt` L198–248). Dart sessions are memory-only. Proven by tests T1 and T6 (§8) and by `process_recreation_test.dart`. |
| P4 | A stale or pre-death ticket can never acknowledge or authorize | **PASS (code + simulated tests)** | Exact-ticket checks: `OverlayStatusChannel` L95–131, `WatcherService.authorizePackage` L440–470 and `consumeChallengeHandoff`. Tests T3–T5, plus mutation M2 (§8.3). |
| P5 | Persisted ticket restore keeps the same generation on the nominal path | **PASS in code and simulation; NOT what happened on the device** | `ensurePendingChallenge` (StateStore L64–72) keeps the generation. On the device, 81 became 82, so a clear or replace happened (§5). The cause is UNVERIFIED. |
| P6 | Generation change 81→82→85 is safe regeneration (not a security break) | **PASS (code inference)** | The counter is monotonic and persisted with `commit()`, matching is exact, and the ready handoff is process-local. Each specific cause is UNVERIFIED without the log (§5). |
| P7 | **Zero protected-content exposure between crash and shield** | **UNVERIFIED, and not guaranteed by design** | §4. The user could not tell whether CamScanner flashed. No screen recording exists. |
| P8 | Unknown states fail closed | **FAIL (conditional)** | Fail-open paths exist: no ticket at death (§4.3, F-3), overlay permission lost (F-6), and the process not restarted (F-2). Authorization *state* fails closed in all of them, but *enforcement over the visible app* does not. |
| P9 | Restart reliability on Oppo / ColorOS | **UNVERIFIED** | One successful auto-restart was reported. AOSP back-off and ColorOS auto-launch rules can suppress restarts (§7). |
| P10 | Android build and instrumented tests | **NOT RUN (tool unavailable)** | No Android SDK, no JDK 17, no Gradle wrapper or `local.properties`. Kotlin JVM unit tests ran through an out-of-tree kotlinc harness (§8.4). |

**Blockers for marking 5T PASS:** see §10. They are B-1 (exposure evidence), B-2 (the Test B log for the 81→82→85 attribution), B-3 (repeat runs and the Test C run), and B-4 (CR-2, which is still open).

---

## 2. Evidence map: components, files, methods, lines (HEAD `3277068`)

Kotlin paths are relative to `android/app/src/main/kotlin/com/smartapplock/app/`.

| Concern | Path | Method / lines | What it does in process death |
|---|---|---|---|
| Foreground service | `WatcherService.kt` | `onCreate` L146–162 | Registers the SCREEN_OFF/ON/USER_PRESENT receiver. Logs `WatcherService.onCreate`. |
| | | `onStartCommand` L164–191 | `startForeground`, `arm()`. **If a ticket is persisted: `show()`, then `recoverProtected(RETRY)`**. Starts the usage poll. Returns `START_STICKY` (L190). |
| | | `onDestroy` L193–208 | Disarms only if protection is disabled. It does not run on a crash. |
| | | `reportForeground` L329–436 | Native decision path for every a11y or usage report. Usage reports are ignored for 5 s after an a11y report (L354–363). `lastAccessibilityElapsedMs` (L279) is memory-only and resets to 0 on restart. |
| | | **H-1 clear** L392–406 | An unprotected report while `readyChallenge` is set clears the exact pending ticket (L397–399). **[§15: true at `3277068`/`e5ca340`; narrowed by F1/F2 in the working tree]** |
| | | `authorizePackage` L440–470 | Requires a protected package, the exact pending ticket (L446–452), and `consumeChallengeHandoff` (L455). Then authorizes, `rememberWakeReauthPackage`, and the exact clear (L462). |
| | | `recoverProtected` L476–512 | `WakeRecoveryGate` → `ensurePendingChallenge` (same generation) → skip if resumed and ready → **shield first** (L494) → `MainActivity.foregroundForRecovery` (L500) → `lastError` → retry. |
| | | `onChallengeHandoffFailed` L531–540 | **Replaces** the ticket (new generation) when `hide()` fails after an accepted ack. |
| | | SCREEN_OFF L66–92 | Revokes all and **replaces** the wake ticket (L87). |
| | | `scheduleRecoveryRetry` L254–259; `RECOVERY_RETRY_MS` L268 | 3 s retry while a ticket is pending. |
| Accessibility service | `AccessibilityLockService.kt` | `onServiceConnected` L25–33 | `arm()` (invisible). Starts `WatcherService` if it is not running. **Does not show the shield, and does not replay the current window.** |
| | | `onAccessibilityEvent` L35–59 | Only `TYPE_WINDOW_STATE_CHANGED`. Drops its own package (L41). Reports to native first (L46), then to Dart. Logs `a11y foreground -> pkg` unguarded (L53, N-1). |
| Shield | `ProtectionOverlayController.kt` | `arm` L30–104, `show` L106–127, `hide` L129–148, `disarm` L150 | `TYPE_APPLICATION_OVERLAY` (L74). It lives in the app process, so **it dies with the process**. Shield flags L173–175 (touchable and focusable, `FLAG_SECURE`). Standby flags L166–170. |
| Challenge activity | `MainActivity.kt` | `onCreate` L31–34, `onResume` L37–44 (`activityResumed = true` L41), `onPause` L58–59, `onDestroy` L63–64 | `activityResumed` is memory-only and starts `false` in a new process (fail closed for `ChallengeReadyPolicy`). |
| | | `acceptRecoveryIntent` L80–93 | An exact `RecoveryIntentPolicy` match → `onChallengeActivityAvailable` (shield plus retry). |
| | | `foregroundForRecovery` L125–157, `launchCold` L160–175 | Existing task: `moveTaskToFront`. Otherwise `startActivity` with `NEW_TASK \| CLEAR_TOP \| SINGLE_TOP` (L112–114). |
| | `AndroidManifest.xml` | L76–77 | `launchMode="singleTop"`, `taskAffinity=""`. **No `android:process`**, so a single process owns the shield, the services and Flutter. |
| Ticket persistence | `ProtectionStateStore.kt` (SharedPreferences `smart_app_lock_protection_bootstrap`) | `configure` L27–46 (`apply()` L36) | Clears the ticket only when disabled or when the package was removed. |
| | | `ensurePendingChallenge` L64–72 | Same package means the same generation. |
| | | `replacePendingChallenge` L79–94 | New generation, **`commit()`** (L92). |
| | | `rememberWakeReauthPackage` L119–133 | `commit()` (L132). |
| | | `restoreWakeReauthChallenge` L145–150 | Only when no ticket is pending. |
| | | `clearPendingChallenge` L152–169 | Exact match, **`apply()`** (L168). |
| Ready-ack gate | `OverlayStatusChannel.kt` | `markChallengeReady` L95–131 | Exact pending ticket plus `ChallengeReadyPolicy(activityResumed, !keyguard, match)` → `markChallengeReady` and `hide()`. A failed hide calls `onChallengeHandoffFailed`. |
| Policies | `WakeRecoveryGate.kt` | `RecoveryIntentPolicy` L29–37, `ChallengeReadyPolicy` L39–45, `WakeRecoveryGate.shouldAttempt` | Unchanged by this audit. Its memory-only state resets on restart, which allows an immediate attempt. |
| Foreground fallback | `InstalledAppsChannel.kt` | `FOREGROUND_LOOKBACK_WINDOW_MS = 60_000` L50, `getForegroundPackage` L263–300 | Latest `MOVE_TO_FOREGROUND` within 60 s. Returns null if its own app is latest. Logs unguarded (L300). |
| Dart bootstrap | `lib/protection/protection_bootstrap.dart` | `synchronize` (`configured = hasAnyCredential && packages non-empty` L47–48) | A restart re-configures with `enabled = true`, so it does not clear the ticket. |
| Dart host | `lib/app/lock_challenge_host.dart` | `_bootstrapProtection` L281–311 | `takePendingChallenge`, then `_presentChallenge` (the native ticket wins over any Dart state). |
| | | `_heartbeatAndRecoverPending` L317–371 | Every 2 s. **Adopts a replaced ticket** for the on-screen route (L343–353). |
| | | `_presentChallenge` L633–874 | `showLockChallenge` (L733) → push the route → post-frame ack → on correct credential, `grantAccess` then native `authorizePackage(_activeNativeChallenge)` (L844). A native failure revokes both layers (L847–850). |
| | | `_afterChallengeClosed` L876–957 | A not-passed close while in the foreground re-presents. |
| | | `_handOffChallengeReady` L960+ | Bounded ready retry (Fix #2). |
| Test double | `lib/services/impl/static_native_challenge_contract.dart` | whole file | Deterministic model of the native rules above. It was **not modified**. |

---

## 3. Recovery sequence: challenge → crash → restore → PIN

Each step is labelled: **[F]** confirmed in code at `3277068`, **[P]** documented Android platform behaviour (not observed by this audit), **[R]** user-reported, **[I]** inference.

| Step | Event | Effect | Label |
|---|---|---|---|
| 0 | CamScanner opens. Native `reportForeground` → `recoverProtected` → `ensurePendingChallenge` (gen N, `commit()`), `show()`, launch. Dart presents, acks; native `markChallengeReady` → ready = N, `hide()`. | The PIN route is visible and the shield is released. **Ticket N is on disk.** | F |
| 1 | `adb shell am crash com.smartapplock.app` | The main thread throws. Nothing else of the app's runs on the main thread, so no a11y callback, no handler and no channel call can change the ticket. | P / I |
| 2 | Process dies | **WindowManager removes the shield window and the activity window. ActivityManager finishes the crashed top activity.** | P |
| 3 | **Exposure window opens** | The task beneath resurfaces (CamScanner, or the launcher, depending on task return order; see §4). No Smart App Lock code exists to cover it. | P / I |
| 4 | AM schedules service restarts (`START_STICKY` WatcherService; the bound a11y service). AOSP base delay is about 1 s, with back-off on repeats (§7). | Not controlled by the app. | P |
| 5 | New process (PID 27617). `Application` → `WatcherService.onCreate` (logged) → `onStartCommand` | `arm()`. **If the ticket is on disk: `show()` (opaque) → `recoverProtected(RETRY)` → `ensurePendingChallenge` returns the same N → `launchCold` `startActivity`.** | F (code), R (`onCreate` seen) |
| 5′ | (Alternative or concurrent) a11y rebind → `onServiceConnected` | `arm()` + `WatcherService.start` (idempotent). No shield until `onStartCommand` or an a11y event. | F |
| 6 | **Exposure window closes** at the first opaque `show()` in step 5. If no ticket was on disk, it closes only at the first protected a11y or usage report. | | F / I |
| 7 | `MainActivity.onCreate/onResume` → `activityResumed = true`; recovery intent exact → `onChallengeActivityAvailable` (shield stays) | | F |
| 8 | Flutter mounts. `_bootstrapProtection` → `synchronize` (enabled = true) → `takePendingChallenge` = N → `_presentChallenge` → `showLockChallenge` (`ensure` gives N) → route → post-frame `markChallengeReady(N)` → accepted → `hide()` | The PIN route is visible. | F; R (challenge reappeared) |
| 9 | Wrong PIN | Dart `AuthFailure`. No grant call. Native ticket unchanged. | F (tested T1); R |
| 10 | Correct PIN | `grantAccess`, then native `authorizePackage(exact ticket)` → `consumeChallengeHandoff` → authorize → exact clear → `hideLockChallenge` → `launchApp` | F (tested T1); R ("opened", gen 85) |

**Observed vs nominal.** On the nominal path, steps 5–10 all use **the same generation N**. The device reported 81 before the crash, 82 after recovery and 85 at success, so the run did **not** follow the nominal path exactly (§5).

---

## 4. Crash-to-shield exposure risk

### 4.1 Fail-open windows

| ID | Window | Cause | Unavoidable vs fixable | Severity |
|---|---|---|---|---|
| **W1** | From process death to the first `show()` in the new process | The overlay is owned by the dying process [P]. AM finishes the crashed foreground activity [P]. The protected task can resurface **visible and interactive**. Its length is the restart delay (AOSP base about 1 s, more under back-off) plus process start plus Application/service init on a low-end Helio P35 device. | **Unavoidable with the current single-process architecture.** It is platform behaviour. It can be partly mitigated by design (§11, R-4: a separate shield-owning process covers *UI-process* crashes, but not force-stop or whole-package kills). | **High (UNVERIFIED magnitude)** |
| **W2** | W1 extended until a detection event, when **no ticket was persisted** at death | The ticket was cleared before death (an authorized session; or an H-1 clear just before the crash. **[§15]** Under F1/F2 a transient window no longer clears; a genuine leave still does, and then no ticket is expected). `onStartCommand` then shows nothing. Recovery waits for an a11y event (a rebind does not replay the window) or a usage report (only within the 60 s lookback). | **Fixable** (§11, R-2: restore from the persisted `wake_reauth` marker on a fresh process). | **Medium** |
| **W3** | Indefinite, when the process is **not restarted** | A second crash within about 60 s marks the process bad. Bound-service crash back-off applies. ColorOS auto-launch is denied, or there is a force-stop. | Platform/OEM limit, **unavoidable** by app code. Must be detected and disclosed (health/notification). | **High (conditional)** |
| W4 | Indefinite, when the overlay permission is lost | `recoverProtected` launches only after a successful `show()` (L494–500). With no overlay there is neither a shield nor a challenge launch. | Capability revocation, out of 5T scope. Should be surfaced (Phase 4 health). Tested as a characterization (T7). | Medium |
| W5 | System UI over the shield | `TYPE_APPLICATION_OVERLAY` sits below the status bar, notification shade and IME. | Platform, unavoidable. Not specific to process death. | Low |

### 4.2 What the user's Test B Run 1 does and does not show

- **Shows [R]:** the app restarted on its own, the challenge came back, and the PIN gate held.
- **Does not show:**
  - whether CamScanner was drawn, or accepted touches, during W1;
  - how long W1 lasted;
  - which restart trigger fired first (sticky service or a11y rebind);
  - whether a ticket was on disk at death (see §5, hypothesis H-A).

A service-restart log line does not prove zero exposure. **P7 remains UNVERIFIED.**

### 4.3 Death while the protected app is open under a valid session (Test C)

There is no ticket at death (the authorization cleared it). After restart, no authorization survives, which is correct, but **nothing re-covers the app already on screen** until the next a11y event or a usage report inside 60 s. Simulated test T6 pins this behaviour.

The Dart `LockTrigger` baseline probe only runs when the Flutter UI starts. A background service restart does not start it.

---

## 5. Generation analysis: 81 → 82 → 85

**Code facts [F]:**

1. Only native code creates generations. `replacePendingChallenge` increments a counter persisted with `commit()`, so generations are **never reused** across process death.
2. `ensurePendingChallenge` returns the **same** generation for the same package. Nominal restart (onStartCommand → recover → Dart present → ack) therefore keeps 81. Simulated test T1 proves this, and mutation M1 shows the test detects a regression.
3. A new generation appears only after one of these events:
   - (a) a clear followed by an `ensure`. The clears are H-1 L397–399, authorize L462, safe-exit L692, `configure` disable/remove L39, and `stop` L303.
   - (b) a replace: SCREEN_OFF L87, `onChallengeHandoffFailed` L533, or `restoreWakeReauthChallenge` (only after a clear).
4. A wrong PIN never touches the native ticket. Simulated test T1 asserts the ticket is unchanged after a wrong PIN.
5. The ready handoff is process-local. After death **no** old ticket can authorize, and within the new process only the exact current ticket can (tests T3, T4, T5 and T5b; **[§15]**).

**Why 81→82 happened.** The cause is UNVERIFIED because no log was supplied. Candidate explanations consistent with the code:

| Hyp. | Sequence | Discriminator in a `SAL_QA_DIAG` logcat | Security impact |
|---|---|---|---|
| **H-A** (pre-death clear) | While route 81 was ready, an **unprotected** report reached native (H-1), so 81 was cleared before the crash. At death there was no ticket. After restart, recovery came from detection: `usage events foreground -> com.intsig.camscanner` (CamScanner is the latest event after AM finished Smart App Lock's activity) or an a11y event, then `ensure` produced **82**. | Old PID: `a11y foreground -> <unprotected pkg>` after `READY generation=81 accepted=true` and before `am crash`. New PID: the first generation logged is 82, and `usage events foreground -> com.intsig.camscanner` precedes the shield. | Fail-closed for authorization, but **W2 applies**: no shield at `onStartCommand`, so the exposure lasts until detection. This is the most consequential hypothesis. |
| **H-B** (post-restore clear) | Restored 81 is presented and acked in the new PID. Then an unprotected report (a transient system window, `android`, `com.android.systemui`, an OEM pop-up) clears 81 (H-1). Then a re-present or an `ensure` produces 82. | New PID: `PRESENTED generation=81`, then `a11y foreground -> <unprotected>`, then `PRESENTED generation=82`. | Fail-closed. Simulated test T5 shows that if the user enters the correct PIN while the ticket is cleared, native rejects it, Dart revokes, the host re-challenges with a new generation, and only that generation authorizes. **[§15]** Under F1/F2, `android`, `com.android.systemui` and default-IME reports no longer clear the ticket, so H-B no longer applies to them (the rewritten T5 shows the correct PIN authorizes the same generation). Unlisted OEM pop-ups can still cause it (F4 not approved). The rejection property now lives in T5b. |
| H-C | A screen off/on cycle (screen timeout or power key) | `SCREEN_OFF observed=… wakePackage=com.intsig.camscanner` | Fail-closed, the intended design (5W). |
| H-D | `hide()` failed after an accepted ack (`onChallengeHandoffFailed`) | `heartbeat recovery TICKET generation=N challenging=true` with no preceding unprotected report or SCREEN_OFF | Fail-closed (simulated test T4). |

**82 → 85.** Three more clear/replace events happened before the successful authorization. A wrong PIN does not cause one (fact 4). Repeated H-1 clears with re-presents (H-B), screen cycles (H-C), or handoff failures (H-D) each add exactly one. The specific causes are **UNVERIFIED**.

The H-B chain is concrete: a correct PIN rejected after a clear is logged as `CLOSED reason=route-navigation-completion-back passed=false` immediately after PIN entry. It produces one extra generation per occurrence (original T5 at `3277068`; **[§15]** under F1/F2 this chain is no longer expected for System UI, framework or default-IME windows).

**Verdict for audit task 4.**

- **Safe regeneration: yes.** The counter is persisted (`commit()`) and monotonic, matching is exact, and the handoff is process-local. No evidence of a broken persistence contract was found. The ticket write uses `commit()`.
- **The restore contract was nevertheless not exercised as designed in Run 1.** Either the ticket was cleared before death (H-A, which means the persisted-ticket path did **not** protect this run), or it was cleared and replaced after the restore (H-B/C/D).
- **Classifying the run needs the Test B logcat.**
- **The native layer logs no ticket create, clear or replace, and no authorize rejection.** Attribution therefore depends on the Dart QA diagnostics plus the `a11y`/`usage` lines (F-7).

---

## 6. Race findings

| ID | Race | Code evidence | Outcome | Severity |
|---|---|---|---|---|
| R-1 | Sticky service restart vs accessibility rebind (either order, or both) | `arm` is idempotent (`shield != null`, L32). `show` is idempotent (`showing`). `ensure` keeps the generation. `start` is guarded by `isRunning` (AccessibilityLockService L30). | Safe. Simulated test T2: duplicate signals keep one generation and one route. | Info |
| R-2 | An a11y event arrives before WatcherService is running | `reportForeground` is static (companion) and works without an instance. `recoverProtected` calls `activeInstance?.scheduleRecoveryRetry()` (no-op if null). `start` at L433. | Safe. The retry is lost until `onStartCommand` re-arms it from the persisted ticket. | Low |
| R-3 | Shield readiness vs activity launch | `show()` precedes `foregroundForRecovery` (L494–500). `onStartCommand` shows before `recover` (L179–185). | Safe when the overlay is permitted. With no overlay there is no launch (W4). | Info / Medium (W4) |
| R-4 | Foreground reporting after restart | `lastAccessibilityElapsedMs` resets to 0 (L279), so usage reports are immediately authoritative. Usage data is historical (60 s). | A stale unprotected usage report after an ack triggers an H-1 clear (fail closed, churn). A stale protected report triggers `ensure` (same generation). | Low |
| R-5 | Challenge dismissal (safe exit) across death | `safeExitGate` is memory-only. The ticket persists. | After restart the shield and challenge return. The user may need "Return to Home" again. Fail closed. | Low |
| R-6 | Screen off/on during W1 | Receivers are registered only in `onCreate` (L146–160). Events during W1 are missed. | The persisted ticket still restores. A replace in the new process supersedes it, and the stale ticket is rejected (T3). | Low |
| R-7 | User switches apps during W1 | The persisted ticket is for CamScanner. The new process shields and launches the CamScanner challenge over whatever is in front, even an unprotected app. Before the ack there is no H-1 clear. | Over-protection (availability), not exposure. "Return to Home" escapes. | Low |
| R-8 | Stale callbacks (old route ack/auth, old recovery intent) | Exact matches: `OverlayStatusChannel` L101–107, `authorizePackage` L446–455, `RecoveryIntentPolicy`. The Dart serial guard is in `_handOffChallengeReady`. | Safe (T3, T4, mutation M2). | Info |
| R-9 | Duplicate challenges (bootstrap pending vs LockTrigger baseline vs heartbeat) | The Dart `_presenting`/`_challenging` guard drops same-package requests (L647–681). Native `ensure` returns the same ticket. | Safe (T2). | Info |
| **R-10** | **Unprotected report after the restored ack (H-1)** | L392–406 clears on *any* unprotected package while ready. This includes system/OEM transient windows. | Fail closed. It causes generation churn, and **the correct PIN can be rejected once** (T5). The most likely source of the 81→85 churn [I]. Hypothesis H-A shows it can also strip the persisted ticket just before a death, enabling W2. **[§15]** Narrowed by F1/F2 (working tree, uncommitted, not device-verified): transient windows keep the ticket; unlisted OEM overlays still defer the clear and forget the wake identity. | **Medium** |
| R-11 | Failed shield hide after the restored ack | `onChallengeHandoffFailed` L531–540 | Fail closed. The route adopts the new ticket (T4). | Low |
| R-12 | Repeated crash / restart storm | AOSP: a second crash within 60 s marks the process bad, and restart back-off applies. | No restart (W3). | High (conditional) |
| R-13 | Durability of `apply()` writes at death | `clearPendingChallenge` `apply()` (L168). `configure` `apply()` (L36). | A cleared ticket may survive on disk, causing a spurious re-challenge (fail closed). A just-added protected package may not be on disk if death follows within milliseconds; native would not protect it until the UI re-bootstraps. | Low |

---

## 7. Android 9 and Oppo / ColorOS constraints

| Topic | Status | Notes |
|---|---|---|
| Background activity start | **Allowed on Android 9** [P] | Background-activity-start limits begin in Android 10. On 10+, the visible SYSTEM_ALERT_WINDOW shield is the exemption the code relies on (not exercised on this device). |
| Overlay survives the process | **No** [P] | Windows are removed with the owning process, which causes W1. **No code comment or document should claim continuous coverage across a crash.** |
| Crash finishes the foreground activity | Yes [P] | AM finishes the top crashed activity, so the underlying task can resurface. |
| Service restart delay | AOSP `ActiveServices.scheduleServiceRestartLocked` [P] | Base `SERVICE_RESTART_DURATION` is 1 s. ×4 back-off within `SERVICE_RESET_RUN_DURATION` (60 s). `SERVICE_MIN_RESTART_TIME_BETWEEN` is 10 s between services. For a crashed service with `crashCount > 1`, `BOUND_SERVICE_CRASH_RESTART_DURATION` × (crashCount−1), which is 30 min per AOSP constants. Values on the ColorOS build are **unverified**. |
| Repeated crashes | AOSP `AppErrors` [P] | A second crash within about 60 s marks the process bad. QA runs must be spaced at least 2 min apart. |
| Force-stop | [P] | Removes the package from enabled accessibility services and leaves the app in stopped state. **Not a valid 5T method.** Note that `docs/regression.md` 5T device QA (L718–721) still suggests "force-stop Smart App Lock from recents". |
| ColorOS | [I] | The battery/auto-launch manager can deny restarts and may force-stop the app on swipe-from-Recents. One successful restart was reported. Reliability is unmeasured. |
| `am crash` | [P] | Android 8.0+. Exits 0 even when no process exists, so check `pidof` first. |

**Guarantees not supported by the code:**

- `docs/regression.md` L718–721 ("the challenge must be back … never an unlocked shell") presents force-stop as a recovery scenario.
- `docs/architecture.md` L1243–1246 says "fail-closed: everything locks". This is true for authorization state, but **the app already on screen is not re-covered until detection** (W2, Test C). The same section omits that the pending ticket and wake marker are persisted.
- The existing `test/regression/process_recreation_test.dart` (7 tests) uses the **lenient, unbound** doubles. It does not exercise native ticket persistence or ready-handoff rules. The new test file closes that gap at the simulation level.

---

## 8. Tests: what was executed

Environment: Flutter 3.47.7 (stable, framework `abaf9c5237`), Dart from that SDK, OpenJDK 11, Linux sandbox, about 2 GB RAM. Run from the repository at `3277068` plus the one new test file.

`flutter pub get` was needed to materialise packages. It rewrote `analysis_options.yaml` and created `pubspec.lock`. Both were restored or removed: `git checkout -- analysis_options.yaml`, and `pubspec.lock` deleted.

### 8.1 Commands and totals

| Command | Result |
|---|---|
| `flutter analyze --no-pub` | **No issues found** (exit 0) |
| `flutter test --no-pub test/regression/process_death_recovery_test.dart` | **7 passed / 0 failed** |
| `flutter test --no-pub -r expanded` (full suite) | **763 passed / 0 failed** (756 pre-existing + 7 new; exit 0) |
| Kotlin JVM unit tests (out-of-tree harness, §8.4) | **25 passed / 0 failed** (`ProtectionAccessStateTest` 6, `SafeExitGateTest` 5, `WakeRecoveryGateTest` 14) |
| `./gradlew testDebugUnitTest` / `assembleDebug` / `assembleRelease` | **NOT RUN.** No Android SDK, no JDK 17, no Gradle wrapper / `local.properties`. |
| Instrumented / device / emulator tests | **NOT RUN.** No device or emulator. |

Raw logs are outside the repo, in `/home/user/Phase5_M3_Process_Death_Audit/`: `analyze.txt`, `tests_full.txt`, `mutation_checks.txt`, `kotlin_jvm_tests.txt`.

### 8.2 New test file: `test/regression/process_death_recovery_test.dart`

**These are SIMULATED process-death tests, not real process death.**

- The Flutter tree is torn down, then a fresh `AppContainer` is built over the same persisted stores.
- A fresh `StaticNativeChallengeContract` carries over **only** what production persists in SharedPreferences: the enabled flag, packages, ticket, generation counter and wake marker.
- All process-local state is reset: ready handoff, `activityResumed = false`, authorizations, and shield visibility (false, as WindowManager would leave it).
- The native restart order (sticky `onStartCommand` → `MainActivity.onResume` → Flutter mount) is driven explicitly.
- They prove contract logic. **They cannot measure W1 or prove zero exposure.**

| # | Test | Proves |
|---|---|---|
| T1 | Death mid-challenge → restore | The persisted ticket is restored with the **same generation**. The shield is visible before any UI. No session or authorization survives. A wrong PIN leaves the ticket and grants untouched. The correct PIN authorizes exactly once and launches once. |
| T2 | Duplicate restart signals | Sticky restart + a11y rebind + retry ticks + repeated protected reports + a Dart `LockRequired` produce **one generation and one route**. The shield is released only by the exact ack. |
| T3 | Screen-off in the new process before mount | The new generation comes from the persisted counter (no reuse). The **stale pre-death ticket cannot ack or authorize**. The new one authorizes. |
| T4 | Failed hide after the restored ack | `onChallengeHandoffFailed` regenerates. The shield stays up (fail closed). The route adopts the new ticket. Only that ticket authorizes. |
| T5 | ~~H-1 characterization~~ → **H-1 corrected (F1/F2)** [§15] | *Original (pinned the bug, obsolete):* an unprotected `android` report after the restored ack clears the ticket and the correct PIN is rejected. *Now:* the `android` report **preserves the exact ticket, the readiness handoff and the wake identity**, creates no leave candidate and grants nothing; a wrong PIN is still rejected; the correct PIN authorizes **the same generation exactly once** (no native rejection, no new handoff); the consumed generation cannot be replayed. |
| T5b | **H-1 retained property** (new) [§15] | A **genuine** leave after the restored ack (MainActivity paused, then the launcher reported) still clears the exact ticket and forgets the wake identity. The correct PIN for the cleared generation is **rejected by native**, Dart revokes, nothing launches, the stale ticket cannot authorize directly. The host re-challenges with a **new** generation, which alone authorizes. |
| T6 | Test C characterization (**unchanged** [§15]; F3 not approved) | Death under a valid session leaves no authorization, **but also no ticket and no shield until a foreground report arrives**. The first report challenges. |
| T7 | Overlay permission lost across the restart | No shield and no activity promotion. The ticket persists, so authorization stays closed. Residual fail-open over the visible app (W4). |

### 8.3 Mutation checks

Run on a scratch copy at `/home/user/.cache/mut/repo`. The real `lib/` was untouched.

| Mutation in the contract double | Effect on the new tests |
|---|---|
| M1: `_recover` uses `replacePendingChallenge` (regenerate on restore) | **6/7 FAIL.** Only T6 passes, because it has no ticket. |
| M2: `authorizePackage` ignores the generation and the ready handoff | **2/7 FAIL** (T3, T4). T5 still passes because its rejection comes from the cleared ticket, not the generation check. (Recorded at `3277068` against the original T5; not re-run for the §15 tests.) |

### 8.4 Kotlin JVM harness (limitations)

The real, unmodified sources (`ProtectionStateStore.kt`, `ProtectionAccessState.kt`, `SafeExitGate.kt`, `WakeRecoveryGate.kt`) and their three JUnit tests were compiled with **kotlinc 2.0.21** against the `com.google.android:android:4.1.1.4` API stubs, and run with JUnit 4.13.2.

This is **not** the Gradle/AGP build: it uses a different Kotlin compiler version and no Android resources or R8. It confirms that the pure policy logic tests pass. It does not validate the APK.

### 8.5 Limitations

- No real process death.
- No WindowManager or ActivityManager behaviour.
- No timing measurement.
- No ColorOS behaviour.
- The contract double models the documented Kotlin rules. It is *not* the Kotlin code, and a divergence between the two would not be detected here.
- The usage-events authority window and `WakeRecoveryGate` rate limiting are outside the double's scope (as stated in its header).

---

## 9. Reassessment of CR-2, H-1, H-2, H-3 (source at `3277068`)

| ID | Status | Evidence | Process-death relevance | Severity now |
|---|---|---|---|---|
| **CR-2** | **OPEN** | `lib/ui/screens/apps/apps_screen.dart`: `_bulkUnprotect` L277–291 (`protectedApps.remove` L291) and `_toggleProtection` L337–351 (`remove` L351) have no authentication step. The app shell has no entry gate (`lib/app/app.dart` L43 `initialRoute: RouteNames.home`). | After recovery, Home leaves the challenge. Opening Smart App Lock → Apps → unprotect CamScanner → open it bypasses the lock **without any credential**. Independent of process death, but it voids P2's assurance. | **Critical** (unchanged) |
| **H-1** | **OPEN at `3277068`/`e5ca340`.** **[§15]** F1/F2 implemented in the working tree (uncommitted, not device-verified); F3/F4 not approved. | `WatcherService.kt` L392–406: an unprotected report while `readyChallenge` is set clears the exact ticket (L397–399). | Demonstrated fail closed (T5): no authorization path was found, and no exposure path was found by this audit. It causes generation churn and false rejection of a correct PIN. It is the most likely contributor to 81→85 [I]. Before death it can strip the persisted ticket (H-A), enabling W2. | **Recommend Medium** (security impact indirect). Keep High until a device trace rules out H-A-style W2 exposure. |
| **H-2** | **OPEN** | Dart session slides: `lib/protection/lock_session.dart` L14 (2 min window), L30 `refresh`. Native is fixed at authorize: `ProtectionAccessState.kt` L80–96 (`activeUntilElapsedMs`, extended only by grace re-entry). | None. Both are memory-only and both drop on death (fail closed). The mismatch remains in normal runtime. | High (unchanged) |
| **H-3** | **OPEN** | `lib/security/credentials/biometric_options.dart` L19 `allowDeviceCredential = true` (default), L63 JSON default `true`. `local_auth_biometric_service.dart` L67 `biometricOnly: !opts.allowDeviceCredential`. `security_screen.dart` L553. | None directly. The recovered challenge still allows the biometric route to accept the device credential, contrary to the approved policy (app credential only). | High (unchanged) |

---

## 10. Outstanding blockers

| ID | Blocker | Needed to close |
|---|---|---|
| **B-1** | P7 zero-exposure is unproven, and W1 is unmeasured | Screen recording plus logcat of Test B Run 2 (§12), analysed frame by frame |
| **B-2** | 81→82→85 cause unknown (H-A vs H-B/C/D) | The Test B Run 1 logcat (`-b main,system,events,crash`), or Run 2 with the QA diagnostics build |
| **B-3** | One run only. Test C not run. Restart reliability on ColorOS unknown. | Three spaced runs of B, plus one run of C |
| **B-4** | CR-2 open (Critical) | Fix approval (outside 5T) |
| B-5 | No Gradle/APK build or instrumented test executed in this audit | Developer workstation run of `./gradlew testDebugUnitTest assembleRelease` |

---

## 11. Prioritized remediation plan

None of these is implemented. Each needs approval, and Kotlin items need an explanation and approval before any change.

| Pri | Item | Change (proposed) | Addresses |
|---|---|---|---|
| P0 | Evidence | Run §12 and upload the recordings and logs. Also upload the Run 1 logcat if it still exists. | B-1, B-2, B-3 |
| P1 | **CR-2** | Require app-credential authentication (with native ticket semantics unchanged) before any unprotect, single or bulk. | Critical bypass |
| P2 | **R-2: fail closed on fresh-process restart with no ticket** (Kotlin) | In `onStartCommand` / `onServiceConnected` of a fresh process, if no ticket is pending but the persisted `wake_reauth` package is protected (it is set on a protected foreground or authorize, and cleared on an unprotected one), call `restoreWakeReauthChallenge` → `show()` → `recoverProtected`. This mirrors the existing SCREEN_ON logic. | W2, Test C, H-A |
| P3 | **R-3: narrow H-1** (Kotlin) | Clear a ready ticket only on a confirmed launcher/Home package (reuse the safe-exit Home resolution), or on a stable unprotected foreground. Ignore `android`, `com.android.systemui`, IME and known OEM overlay packages. | R-10, generation churn, correct-PIN rejection. **[§15]** Implemented as F1/F2 (paused-Activity confirmation instead of Home resolution), **except** known OEM overlay packages (F4, not approved). |
| P4 | **R-4: shrink W1** (architecture, approval needed) | Evaluate moving the overlay owner (and optionally the watcher and a11y service) into a separate lightweight process (`android:process`). A Flutter/UI-process crash would then not remove the shield. It does not help force-stop or a whole-package kill. | W1 for UI crashes |
| P5 | Observability (Kotlin, QA-gated) | Behind a QA/debug flag, log ticket `ensure`/`replace`/`clear` with reason and generation, and `authorizePackage` rejection reasons. Guard the existing `Log.d` lines (N-1) so production logs no package names. | B-2 in future runs, N-1 |
| P6 | Restart health | Surface "accessibility disabled", "overlay missing" and "restart suppressed" in the health UI and notification. Document ColorOS auto-launch requirements. | W3, W4 |
| P7 | Durability (Kotlin, low) | Use `commit()` for `configure` (enabled/packages), so a newly protected package is durable before any death. | R-13 |
| P8 | Docs (non-code) | Correct the `docs/regression.md` 5T device QA (drop force-stop, add the `am crash` procedure, remove the "never" wording). Correct `docs/architecture.md` §5T (persisted ticket, W1/W2, Test C). Add this audit's tests to the 5T suite table. | Accuracy |
| P9 | H-2, H-3 | As already planned: align the native window with the Dart sliding session; `allowDeviceCredential = false` per the approved policy. | H-2, H-3 |

---

## 12. Exact next physical QA (Windows CMD, Oppo CPH2083)

Prerequisites:

- Install the QA build (`flutter build apk --release --dart-define=SAL_QA_DIAG=true`).
- ColorOS: allow Auto-launch and disable battery optimisation for Smart App Lock.
- Do **not** force-stop the app or clear its data.
- Space crash runs **at least 2 minutes** apart.

```bat
:: Terminal 1: logs (all buffers, timestamps)
adb logcat -c
adb logcat -v threadtime -b main,system,events,crash > 5t_B2_logcat.txt

:: Terminal 2: preconditions
adb shell settings get secure enabled_accessibility_services
adb shell appops get com.smartapplock.app SYSTEM_ALERT_WINDOW
:: Open CamScanner on the phone and wait until the PIN challenge is fully visible (about 5 s).
adb shell pidof com.smartapplock.app

:: Terminal 3: screen recording (max 180 s). Start it just before the crash.
adb shell screenrecord --bit-rate 8000000 /sdcard/5t_B2.mp4

:: Terminal 2: crash
adb shell am crash com.smartapplock.app
:: Do NOT touch the phone until the challenge is back, then:
adb shell pidof com.smartapplock.app
adb shell settings get secure enabled_accessibility_services
adb shell dumpsys activity services com.smartapplock.app > 5t_B2_services.txt
:: On the phone: enter a WRONG PIN, observe, then the CORRECT PIN.

:: Stop screenrecord (Ctrl+C in Terminal 3), then:
adb pull /sdcard/5t_B2.mp4
```

1. **Independent capture.** Also film the phone with a second camera at 60 fps or more. `screenrecord` can drop frames, and secure (`FLAG_SECURE`) layers such as the shield and challenge are expected to appear **black** in it. Any visible CamScanner content between the crash and the black or shield frames is exposure.
2. **Analysis.**
   - Extract frames (`ffmpeg -i 5t_B2.mp4 -vsync 0 f\%05d.png`).
   - Measure from the first frame after `am crash` to the first shield frame, in ms.
   - Note any CamScanner content frames.
   - Correlate with the `am_crash`, `am_proc_died`, `am_proc_start`, `WatcherService.onCreate`, `usage events foreground ->`, `a11y foreground ->`, `PRESENTED generation=`, `READY generation=` and `CLOSED reason=` lines.
3. **Interaction probe (separate run, at least 2 min later).** Repeat, and during the gap tap a harmless CamScanner UI element. Record whether the tap took effect.
4. **Test C (separate run).**
   - Unlock CamScanner and stay in it.
   - `am crash`.
   - Record whether CamScanner remains usable after the restart, and for how long, without any app switch.
5. **Repeat** B2 three times (2 min apart) for a latency distribution and generation behaviour.
6. **Pass criteria for P7:** zero frames of protected content in **every** run, on both the screen recording and the external camera. Otherwise record the exposure duration, keep P7 **FAIL / UNVERIFIED**, and prioritise R-2 and R-4.

---

## 13. Facts vs assumptions

**Verified facts (this audit, executed or read at `3277068`):**

- the code locations, persistence modes (`commit()`/`apply()`) and decision paths cited in §2;
- analyze clean;
- 763/763 Flutter tests;
- 7/7 new simulated tests (at `3277068`; **8/8** after the §15 reconciliation);
- mutations M1 and M2 detected;
- 25/25 Kotlin JVM tests (out-of-tree harness);
- no production code changed;
- CR-2, H-1, H-2 and H-3 are still present in source (at `3277068`; for H-1 see §15).

**User-reported (not independently verified):** Test A pass; Test B Run 1 (PIDs 23326 → 27617, `WatcherService.onCreate`, automatic challenge, wrong PIN blocked, correct PIN opened, generations 81 / 82 / 85); the user could not tell whether content flashed.

**Platform behaviour (documented AOSP behaviour, not observed here):** overlay removal on process death; crashed-activity finish; service restart delays and back-off; bad-process marking; force-stop disabling accessibility; Android 9 having no background-activity-start limits.

**Inferences / assumptions:**

- Hypotheses H-A to H-D for the generation changes, and which one occurred.
- That the W1 magnitude is at least about 1 s on this device.
- Which task resurfaced after the crash (CamScanner or the launcher).
- ColorOS restart reliability.
- That `screenrecord` blacks out secure layers on this device.
- That the contract double faithfully mirrors the Kotlin rules (it was written from the sources, but it is not the Kotlin code).

---

## 14. Files touched by this audit (uncommitted)

| File | Change |
|---|---|
| `test/regression/process_death_recovery_test.dart` | **New**, test-only, 7 simulated tests |
| `docs/phase5_milestone3_process_death_security_audit.md` | **New**, this report |
| `test/regression/process_death_recovery_test.dart` (2026-10-25, §15) | T5 rewritten to the corrected H-1 behaviour; T5b added. T1–T4, T6 (Test C) and T7 byte-identical. |
| `docs/phase5_milestone3_process_death_security_audit.md` (2026-10-25, §15) | Reconciliation markers and §15 added; original findings kept. |

HEAD remains `3277068`. Nothing was committed or pushed: no commit or push was authorized.

(§15 reconciliation: HEAD `e5ca340`; both files still untracked; nothing committed or pushed.)

---

## 15. Addendum: H-1 F1/F2 reconciliation (2026-10-25)

| Item | Value |
|---|---|
| HEAD | `e5ca3401093eea0bead130000590c2992e59fd57` (CR-3), equal to GitHub `main` |
| Code under test | HEAD **plus the uncommitted H-1 F1/F2 working tree** (`WatcherService.kt`, `MainActivity.kt`, `WakeRecoveryGate.kt` `ChallengeAbandonPolicy`, the `StaticNativeChallengeContract` model). See `/home/user/Phase5_M3_H1_Fix/H1_Fix_Report.md`. |
| Production code changed by this reconciliation | **None.** Only this test file and this document were edited. |
| F3 (restart restoration) / F4 (OEM Activity classification) | **Not implemented, not approved.** |
| Device verification | **None.** All results below are SIMULATED or pure-JVM. |

### 15.1 Old H-1 bug vs corrected behaviour

| Situation (after the restored ack, PIN route on screen) | Old behaviour, `3277068` / `e5ca340` (**the H-1 bug**) | Corrected behaviour, F1/F2 working tree |
|---|---|---|
| Transient window reported: `android` (crash/ANR/permission dialog), `com.android.systemui`, default IME, blank | exact ticket **cleared**, handoff invalidated, wake identity forgotten; the correct PIN is **rejected** and the host re-challenges with a new generation (H-B churn) | exact ticket, readiness handoff and wake identity **preserved**; no leave candidate; nothing granted; wrong PIN rejected; correct PIN authorizes **the same generation, exactly once** |
| Genuine leave: MainActivity paused, then a launcher/app reported | cleared | **cleared** (unchanged): the cleared generation cannot authorize; a new generation alone authorizes |
| Launcher reported while MainActivity is still resumed | cleared | deferred; cleared only by the matching `onPause` within 1.5 s (exact ticket, screen interactive) |
| Unlisted OEM overlay (e.g. `com.coloros.gesture`) | cleared | deferred only; **still forgets the wake identity** (residual, needs F4) |
| Death under a valid session (Test C / T6) | no ticket, no shield until a report | **unchanged** (F3 not approved) |

Effect on this audit's hypotheses:
- **H-B / R-10:** no longer expected for System UI, framework or default-IME windows. They remain possible for unlisted OEM windows.
- **H-A / W2:** a transient window just before a crash no longer strips the persisted ticket. A genuine leave still clears it, which is correct (the user left).

### 15.2 Test changes in `test/regression/process_death_recovery_test.dart`

| Test | Change |
|---|---|
| T1–T4, T7 | byte-identical |
| **T6 (Test C)** | **byte-identical** (verified with `diff` against the pre-edit copy). It still characterizes the restart gap; F3 is not approved |
| **T5** | **Rewritten.** Was "SIMULATED (H-1 characterization) … clears the ticket; the correct PIN then CANNOT authorize". Now "SIMULATED (H-1 corrected, F1/F2) …". See the assertions below |
| **T5b** | **New.** "SIMULATED (H-1 retained property) …": genuine leave (pause + `com.android.launcher`) clears the ticket. It keeps *every* security assertion of the old T5 (native rejection of the cleared generation, Dart revocation, no launch, no session, re-challenge with a strictly newer generation that alone authorizes) and adds a direct stale-ticket authorize rejection |

Assertions in the rewritten T5:

1. Precondition: the wake identity was persisted.
2. After `reportForeground('android')`:
   - `pending == persistedTicket`;
   - `readyChallenge == persistedTicket`;
   - `wakeReauthPackage == protected`;
   - `abandonCandidate == null`;
   - no authorization, no session, no launch.
3. Wrong PIN: rejected, ticket and handoff unchanged, no grant or launch.
4. Correct PIN:
   - `authorizeRejections` unchanged;
   - `readyAccepted` unchanged (no regenerated handoff);
   - authorized exactly `{protected}`;
   - pending and handoff consumed;
   - launched exactly once.
5. Replay of the consumed generation is rejected.

No assertion was removed without an equivalent or stronger one in T5 or T5b.

### 15.3 Results (executed 2026-10-25)

| Check | Result |
|---|---|
| `flutter test --no-pub test/regression/process_death_recovery_test.dart` | **8 passed / 0 failed** |
| **RED check** (scratch copy; simulator = pre-fix `e5ca340` logic + inert field/classifier) | rewritten T5 **fails** at the F1 assertion (`Expected: PendingLockChallenge, Actual: null`); the other 7, including T5b, pass. This shows T5 detects the H-1 regression and T5b holds under both behaviours |
| `flutter analyze --no-pub` | **No issues found** (exit 0) |
| `flutter test --no-pub -r expanded` (complete suite, including this file) | **842 passed / 0 failed** (exit 0) = 834 tracked + 8 in this untracked file |
| Kotlin JVM policy tests (kotlinc 2.0.21 + android-4.1.1.4 stub + JUnit 4.13.2; **not Gradle**) | **39 / 39 OK** (`ProtectionAccessStateTest`, `SafeExitGateTest`, `WakeRecoveryGateTest`, `ChallengeAbandonPolicyTest`) |
| Gradle / AGP build, device or emulator | **NOT RUN / UNVERIFIED** |

Logs: `/home/user/Phase5_M3_T5_Reconcile/`.

### 15.4 Still open

- **Device QA** for F1/F2 (see the fix report's D1–D12). Exposure claims remain **UNVERIFIED**.
- **W1/W2/W4 and Test C** (§4) are unchanged by F1/F2.
- **F3 and F4** are not approved.
- The fix and these two files are **uncommitted**.
