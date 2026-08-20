# Phase 4A — Capability Requirements

**Status:** Architecture definition (no implementation in this phase).

This document defines *exactly* which Android capabilities the selected
protection architecture requires, what each is for, what it does NOT
grant, and how it is requested. It is the single source of truth for all
later phases; any manifest or permission change must reference it.

---

## 1. Protection architecture being served

```
Foreground-app detection ──► Lock decision ──► PIN challenge on top of
(usage access, primary)     (rules +         the protected app
(accessibility, fallback)    protection set)  (overlay window)
                                                    │
                                          unlock → app opens
```

| Stage | Mechanism (selected) | Capability |
| ----- | -------------------- | ---------- |
| Detect the foreground app | Usage-stats polling (primary) | **Usage Access** (user grant) |
| Detect the foreground app | Accessibility events (fallback) | **Accessibility Service** (user grant) |
| Draw the lock screen over any app | Overlay window (`TYPE_APPLICATION_OVERLAY`) | **Draw over other apps** (user grant) |
| Stop casual uninstall while locks are active | Device admin watchdog (optional hardening) | **Device admin** (user grant) |
| Read the installed-app catalog | `<queries>` launcher visibility (already shipped, 3A) | No permission |
| Keep the watcher alive in the background | Foreground service (NOTIFICATION + FOREGROUND_SERVICE) | Normal permissions |

---

## 2. Capability inventory — what IS required, what is NOT

### Required (runtime, user-granted)

| # | Capability | Manifest element | Used for | Can the user deny it? | App behavior when denied |
| - | ---------- | ---------------- | -------- | --------------------- | ------------------------ |
| 1 | **Usage Access** | none (special settings) | Foreground-app detection (primary). The system settings app surfaces the grant via `Settings.ACTION_USAGE_ACCESS_SETTINGS`; the app holds **no** `PACKAGE_USAGE_STATS` declaration — that permission is guarded by AppOps and granted by the system UI, not by the manifest. | Yes | Lock engine falls back to accessibility detection; prompts guide re-enabling |
| 2 | **Draw over other apps** | `SYSTEM_ALERT_WINDOW` | The lock screen must be able to appear **on top of any protected app** — this is the entire enforcement surface. | Yes | Locking cannot show the challenge; prompts guide enabling |
| 3 | **Accessibility service** | `<service android:permission="BIND_ACCESSIBILITY_SERVICE">` + `accessibilityservice` intent filter + XML config | Fallback foreground detection + the "close app when locked" gesture | Yes | Usage-access path (if granted) covers detection; prompts guide enabling |

### Required (normal, install-time — cannot be denied individually)

| # | Capability | Purpose |
| - | ---------- | ------- |
| 4 | `POST_NOTIFICATIONS` (API 33+) | Required to *start* the foreground-service watcher |
| 5 | `FOREGROUND_SERVICE` | Permission class for the watcher service |
| 6 | `FOREGROUND_SERVICE_SPECIAL_USE` | The watcher has no camera/mic/data/media type — the special-use type applies, with the required `<property>` declaration (Play policy) |
| 7 | `<queries>` MAIN/LAUNCHER (already present, 3A) | Installed-app visibility — no permission |

### Already present (carried from earlier phases — NOT re-added)

| Capability | Phase | Purpose |
| ---------- | ----- | ------- |
| `USE_BIOMETRIC` | 2J | BiometricPrompt on API < 28 |
| `INTERNET` (debug/profile only) | 1A | Hot reload / profiling |

### Explicitly NOT required — and why

| Rejected capability | Reason it stays out |
| ------------------- | ------------------- |
| **Device admin** (optional hardening only) | The PRD's protection architecture is *app-level* (detect → overlay → unlock). Device admin is listed as an optional hardening stage, and Phase 4A does not activate it: it is the most user-alarming grant and Play-restricts it to enterprise/lock/wipe uses. Adding it later requires a separate PRD decision. |
| `PACKAGE_USAGE_STATS` in the manifest | The platform *ignores* the manifest declaration for this permission; the grant comes solely from the Usage Access settings screen (AppOps). Declaring it adds noise and confuses reviewers. |
| `QUERY_ALL_PACKAGES` | Play-restricted, broad package visibility. The `<queries>` launcher declaration (3A) already provides what the app-list needs. |
| **Full-screen intent** (`USE_FULL_SCREEN_INTENT`) | The lock surface is an overlay window, not a notification-triggered activity. |
| `MANAGE_EXTERNAL_STORAGE` / storage permissions | Nothing in the architecture touches shared storage. |
| `RECEIVE_BOOT_COMPLETED` | The watcher restarts lazily (app open or foreground-service reconnect); boot persistence is not part of the design. |
| Camera permission | Reserved for the later intruder-selfie feature — **not** part of the protection architecture; not requested now. |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Battery optimization may shorten polling; the design degrades gracefully to accessibility detection. Not required at this stage. |
| Root / ADB / `BIND_DEVICE_ADMIN` + `USES_POLICY_FORCE_LOCK` | Out of scope for an app-level locker. |

---

## 3. Manifest changes planned (future phases; NONE in 4A)

| Manifest change | When it lands | Notes |
| --------------- | ------------- | ----- |
| `SYSTEM_ALERT_WINDOW` | Lock-screen phase | Normal permission, listed only |
| Overlay service (`<service>` for the challenge window) | Lock-screen phase | The overlay is Flutter-rendered via a service/activity with `TYPE_APPLICATION_OVERLAY` |
| Watcher foreground service + `FOREGROUND_SERVICE[_SPECIAL_USE]` + `POST_NOTIFICATIONS` | Watcher phase | Includes the `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` declaration |
| Accessibility `<service>` + `res/xml/accessibility_service_config.xml` | ✅ **Landed in 4C** | `android:canRetrieveWindowContent="false"` + `typeWindowStateChanged` only — detection-only, no content capture; detection wiring itself ships with the lock engine |
| (Optional, future PRD) Device-admin receiver | Only if hardening activates it | Requires an explicit decision; not part of this phase |

---

## 4. Request flow each capability follows

Every runtime capability uses the same pattern (matching the Phase 1B
service contracts):

```
Feature opens → service.isAvailable() →
  granted      → proceed
  denied       → service.requestX() opens the SYSTEM settings screen
                 (never an in-app fake toggle)
                 → on return, isAvailable() is re-checked
```

- The app never blocks forever on a denial — every path has a
  user-safe "continue without" or "re-check later" state.
- Settings screens are opened via `Settings.ACTION_*` intents: the user
  makes the final choice in the system UI, which is the only way these
  special grants are legally surfaced.

---

## 5. Denial matrix (the "avoid unnecessary permissions" proof)

| Denied | What still works |
| ------ | ---------------- |
| Usage access | App list, protection selection, PIN/pattern/biometric setup; locking runs on the accessibility path if enabled, otherwise locking is off with clear prompts |
| Overlay | Everything except the challenge window itself; the engine reports "not available" instead of crashing |
| Accessibility | Locking runs on usage-access detection alone |
| Both detection paths | App management fully works; locking is disabled with a setup wizard |
| Notifications (API 33+) | The watcher cannot run in the background → detection uses accessibility only (same as a denial) |

---

## 6. Test / verification contract (implemented in later phases)

For each capability, the implementing phase must ship:

1. `isAvailable()` returns the true OS state (probed, not assumed).
2. `requestX()` opens the correct system settings screen.
3. Re-check after return from settings.
4. Denied-state UI message per the matrix above.
5. No capability is declared in the manifest before its phase.
