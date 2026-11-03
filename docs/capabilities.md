# Android protection capabilities

**Baseline:** C0 / Phases 1–5

This file is the source of truth for Android capabilities used by the current
lock engine. It describes the implementation that exists, not future phases.

## Enforcement architecture

Smart App Lock uses a hybrid design:

1. Native Accessibility handling owns the earliest package-to-shield
   transition even while Dart is healthy. Flutter owns authentication and the
   authoritative session/grace policy.
2. A native foreground service holds a minimal, non-secret copy of the desired
   protection state and receives a Dart heartbeat.
3. Accessibility events are handled synchronously in native code. UsageEvents
   polling is a slower recovery fallback; heartbeat expiry is not a prerequisite
   for native shielding.
4. A zero-sized inert overlay is pre-attached while protection is configured.
   Native code expands it into an opaque, touch/key-blocking
   `TYPE_APPLICATION_OVERLAY`, persists a pending package, and only then
   launches `MainActivity` to reconstruct the Flutter challenge.
5. The shield is removed only after the Flutter challenge route is ready and
   the activity is resumed.

No PIN, password, pattern, hash, salt, or biometric material is copied into the
native recovery preferences.

## Capability model

| Capability | Classification | Current use | Behavior when unavailable |
| --- | --- | --- | --- |
| Draw over other apps (`SYSTEM_ALERT_WINDOW`) | **Required** | Opaque touch-blocking recovery/handoff shield and background-activity-launch exemption | Protection is unavailable; the UI must not claim it is active |
| Usage Access (`PACKAGE_USAGE_STATS`) | **Recommended fallback** | Polling/history-based recovery detection | Recovery redundancy is reduced; UsageEvents alone cannot guarantee first-frame concealment |
| Accessibility service (`BIND_ACCESSIBILITY_SERVICE`) | **Required for strongest available protection** | Earliest narrow window-state package event; native shield is raised before Dart delivery; no content retrieval | Usage-only protection remains best-effort and is truthfully reported as delayed/degraded |
| Foreground service (`FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE`) | **Required internal capability** | Native recovery watcher | Protection cannot survive Dart/process loss |
| Notifications (`POST_NOTIFICATIONS`, API 33+) | **Optional** | Makes the ongoing service notification visible in the notification drawer | Service may run but health is degraded and notification visibility is reduced |
| Boot completed (`RECEIVE_BOOT_COMPLETED`) | **Required internal capability** | Restarts only previously configured protection after boot | Reboot recovery is unavailable |
| Launcher `<queries>` | **Required package visibility declaration** | Installed, launchable application discovery | App selection cannot be populated correctly |
| Biometrics (`USE_BIOMETRIC`) | **Optional authentication method** | Local biometric challenge when enabled by the user | Primary PIN/pattern remains available |

Minimum protection readiness is:

```text
overlay granted
AND accessibility enabled
AND native recovery service available
AND credential configured
AND at least one protected package configured
```

Usage Access adds recovery redundancy. Usage-only detection is still available
but degraded because Android exposes UsageEvents as historical queries; it
cannot promise flash-free first-frame enforcement. Notification denial is also
degraded, not proof that the service failed to start.

## Explicitly excluded capabilities

| Capability | Reason |
| --- | --- |
| `QUERY_ALL_PACKAGES` | Launcher `<queries>` is sufficient and less invasive |
| `USE_FULL_SCREEN_INTENT` | The handoff shield is an application overlay, not an alarm/call notification |
| Device administrator | Not necessary for the Phases 1–5 app-level lock architecture |
| Storage permissions / `MANAGE_EXTERNAL_STORAGE` | The app does not need shared-storage access |
| Camera | Intruder photography is outside the C0/Phases 1–5 baseline |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Not requested (Phase 6 / M3 reviewed): not required by the PRD, and on AOSP it is not documented to lift the "Restricted" state for foreground services. OEM power restrictions remain a documented physical-device risk |
| Root/ADB privileges | Outside the application security model |

## Request and denial behavior

- Usage Access, Accessibility, and Draw Over Other Apps are enabled only in
  Android system settings and re-checked when the app resumes.
- The app does not silently enable special access or present an in-app switch
  as though it were the Android grant.
- Notification permission is not requested as a prerequisite for starting the
  protection watcher.
- If overlay or both detection paths are missing/revoked, protection health is
  unavailable and setup/recovery guidance is shown.
- If Accessibility is missing but Usage Access remains, protection health is
  explicitly degraded as delayed/best-effort rather than described as
  flash-resistant. Missing Usage Access or notification visibility reduces
  redundancy without stopping Accessibility enforcement.
- A capability probe/storage failure never converts protection to a healthy
  state and never clears the last known native desired-protection state.

## Manifest inventory

The release manifest contains only the capabilities needed by this baseline:

- `PACKAGE_USAGE_STATS`
- `SYSTEM_ALERT_WINDOW`
- `POST_NOTIFICATIONS`
- `FOREGROUND_SERVICE`
- `FOREGROUND_SERVICE_SPECIAL_USE`
- `RECEIVE_BOOT_COMPLETED`
- `USE_BIOMETRIC`
- launcher `<queries>`
- the detection-only accessibility service
- the non-exported special-use watcher service
- the boot receiver

`INTERNET` is confined to Flutter's debug/profile manifests for development
tooling; it is not a release capability.

## Verification contract

Changes to this architecture must retain automated checks for:

1. early-detector/recovery-detector combinations and truthful health states;
2. no native recovery enablement without both a credential and protected app;
3. fail-closed persistence/bootstrap errors;
4. recovery configuration surviving Flutter teardown;
5. watcher/overlay method-channel serialization;
6. authentication failure never granting a session;
7. release-manifest permission scope; and
8. process-recreation, reboot, screen, Home, Back, and task-switching behavior,
   followed by physical-device QA for Android lifecycle behavior that cannot be
   proven by a Dart unit test.

## Platform limitations

- **Android Force Stop** (Settings, or an OEM cleaner that force-stops):
  Android puts the package into the stopped state and removes its enabled
  Accessibility service. The watcher, `START_STICKY` restart and boot receiver
  do not run, so **protection is unavailable while the app is force-stopped**,
  until the user opens Smart App Lock again (Accessibility may need to be
  re-enabled). The app cannot prevent this. Force Stop is therefore not a
  valid process-death (F3) test.
- **Alternate entry paths** (Phase 6 / M1): Smart App Lock cannot intercept
  intents sent to other apps. A notification, deep link, share, shortcut or
  widget entry is enforced when the protected app's Activity reaches the
  foreground, so the target app may already have received (and acted on) the
  intent before the shield appears. Notification actions that open no UI,
  notification content and launcher-rendered widget content are not covered
  by a foreground lock (notification privacy is PRD Phase 14). Bubbles and
  show-when-locked or full-screen-intent Activities over the keyguard are not
  device-verified.
- **Split screen, freeform and task switching** (Phase 6 / M2): unlock is
  refused while Smart App Lock's challenge shares the screen. The shield
  stays up and asks the user to use full screen or return to Home.
  Switching from an unlocked protected app to Smart App Lock's own screens
  counts as leaving it (grace 0 re-locks). Android 10+ does not report focus
  changes between split-screen panes. Picture-in-picture, OEM floating
  windows, foldables and Recents thumbnails of protected apps are not
  device-verified. `resizeableActivity` is not used: Android 16 ignores it
  on large screens.
- **Battery Saver and background restrictions** (Phase 6 / M3): stock
  Battery Saver does not stop foreground or Accessibility services, and no
  enforcement path uses jobs, alarms or background network. The AOSP 9+
  "Restricted" background-usage setting, and OEM power managers such as
  ColorOS's, can stop the watcher service. When that happens while protection
  is configured, every native session and grace window is revoked (fail
  closed), the shield and pending challenge are kept, and the Security
  screen reports the engine as unavailable with the reason. Until the service
  restarts, native screen-off re-lock pauses; Smart App Lock's own screen-off
  handling covers it while the app's engine is alive, and sessions are
  revoked when that engine closes with the service still stopped. Protection is not
  guaranteed while Android suspends these components. Phase 7 / M1 reports
  Android's "Restricted" state (`ActivityManager.isBackgroundRestricted`,
  API 28+) as a health issue; OEM power managers have no public API and are
  always reported as UNKNOWN. Device behaviour is not verified.

## Protection Health signals (Phase 7 / M1)

Health is read-only and uses no new permission, manifest entry or
dependency. Signals and their source:

| Signal | Source | UNKNOWN when |
| --- | --- | --- |
| Protection configured | Dart repositories (credential + protected app); first-time setup (no credential) and no protected apps are reported separately and never as a system failure | storage read fails |
| Native enforcement enabled | native `getHealth.protectionConfigured` (`ProtectionStateStore.isEnabled`); required for SECURE whenever protection is configured | native health unreadable |
| Overlay / Accessibility enabled / Usage Access | existing capability probes; grant history separates *not set up* from *revoked* | probe fails or times out (3 s) |
| Accessibility **bound** | `AccessibilityLockService` bind lifecycle (process-local) | native health unreadable |
| Watcher running, shield pre-armed, notifications, pending ticket | native `getHealth` | native health unreadable |
| Background restriction | `ActivityManager.isBackgroundRestricted()` | below API 28 = *unsupported* (limitation); read fails |
| Battery Saver / battery-optimization exemption | `PowerManager` | read fails |
| OEM background controls (for example ColorOS) | none (no public API) | always |
| Biometric hardware / enrollment / enabled in app | `BiometricService` capability queries, credential state | query fails |

Biometric health is advisory: a removed enrollment or missing sensor never
makes protection OFFLINE or ATTENTION REQUIRED; PIN/pattern stays primary.
Nothing is stored about biometrics, and enrollment is never launched by the
app. A battery-optimization exemption is reported, not requested.

SECURE means every observable core signal was positively seen in a fresh
snapshot. It is not a guarantee against every Android bypass: OEM power
managers, force-stop and other behaviour outside the public APIs cannot be
observed.

## Fix Protection limits (Phase 7 / M2)

Repairs only open screens; the user decides there. Smart App Lock never
grants a permission, requests a battery-optimization exemption or launches
biometric enrollment.

| Issue | What the app can do | What it cannot do |
| --- | --- | --- |
| Overlay / Accessibility / Usage Access | open the existing setup screen, which opens the Android Settings page | grant the capability |
| Notifications (Android 13+) | open the app's notification settings (App info if unavailable) | allow notifications |
| Android "Restricted" background | open App info (Battery lives there on AOSP) | change the restriction; reach OEM power managers (for example ColorOS), which have no public API: guidance only, names vary |
| Battery Saver | open Battery Saver settings (optional) | nothing is required |
| Fingerprint not enrolled | guidance only | open enrollment (and the Oppo test device cannot complete it) |
| Protection service stopped / shield not ready / native protection off | re-run the existing protection synchronization once per tap | keep Android or the OEM from stopping it again |

Whether each OEM build resolves these Settings screens is device-dependent
and UNVERIFIED until the combined device QA round.

## Health refresh limits (Phase 7 / M3)

Automatic refresh uses only Flutter app-lifecycle events and in-app
navigation; it adds no permission, manifest entry, receiver, job, alarm,
battery-optimization request, foreground-service change or SDK change.

- **Lifecycle mapping.** Android `onStop` → Flutter `paused` (real leave:
  Settings, Home, Recents, screen off); losing window focus (notification
  shade, quick-settings tile, system dialog) → `inactive` only. Both refresh
  on resume, but only a real leave forces a check that starts after the
  return. This mapping is the same on Android 9 (Oppo / ColorOS) and newer.
- **What a refresh can see** is exactly the Phase 7 / M1 signal set. OEM
  power managers (ColorOS auto-launch, app freezing, "deep optimization")
  have no public API: they are never reported as fixed or healthy by a
  refresh; their effect shows only indirectly (for example the watcher not
  running) and can lag until Android actually stops the service.
- **Notifications** (Android 13+ only): Android keeps no grant history the
  app can read, so "not allowed" is worded as setup, never as revoked. Below
  Android 13 (including the Android 9 Oppo) the runtime permission does not
  exist and nothing is reported (the app-level notification switch is not
  read there); per-channel switches are not read on any version.
- **Background restriction** is readable from API 28 (Android 9) via
  `ActivityManager.isBackgroundRestricted`; some OEM toggles are not
  reflected there.
- **Timing.** If an OEM Settings page applies a change after the app has
  resumed, the first check may still see the old value; the next trigger
  (Check again, tab return, next resume) corrects it. Device-dependent,
  recorded in the combined device QA.

## Security levels (Phase 8 / M1)

Per-app levels (Standard / Sensitive / Critical) are stored in the existing
app database only. They add no permission, manifest entry, native API,
service, dependency or SDK change, and in M1 they are not sent to the native
watcher: Android-side enforcement (challenge, tickets, grace, re-lock) is
identical for every protected app until Phase 8 / M2.

- **Android 9 SQLite (3.22).** Schema and write SQL avoid UPSERT and
  RETURNING; the v1 → v2 migration is a single `ADD COLUMN` with a constant
  default inside sqflite's open transaction.
- **App downgrade.** Installing an older (pre-M1) build over M1 data keeps
  every protected app; rows that the old build rewrites read as Standard
  again after upgrading. The re-upgrade is guarded so it cannot fail.
- **Backup / restore and data clearing** follow the existing database
  behaviour (Settings → Clear storage removes protected apps and their
  levels together).
- **What the levels do not do in M1:** no stricter re-lock, no
  authenticate-every-access, no per-level grace. The app says so in the
  level picker. *(Superseded by Phase 8 / M2 below.)*

## Security level enforcement (Phase 8 / M2)

Levels are now sent to the native watcher with the protected set and
enforced through the existing engine. **No new permission, manifest entry,
service, SDK, dependency, polling or keep-alive.** Platform facts that bound
what is promised:

- **Observable transitions only.** Sensitive and Critical act on foreground
  changes that Android reports (Accessibility window-state events; the
  Usage Access fallback when Accessibility is off, which is coarser and
  cannot renew a session on its own, U1-R). In-app navigation without a
  window event and content shown inside other apps are not observable.
- **Critical re-challenges on any reported departure**, including brief
  keyboard (IME) or System UI windows that some OEMs report as their own
  package. This is strict by design; it never loops while the user stays in
  the authenticated app.
- **Inactivity window expiry is event-driven** (H-2, unchanged): the window is
  checked when the next event for the app arrives.
- **Native persistence.** The levels live next to the protected set in the
  watcher's private `SharedPreferences`, written with `commit()` in the
  same edit, so they survive process death and reboot. A store written by a
  pre-M2 build has no level map and enforces Standard; a damaged map or one
  written by a newer build enforces Critical. If that write fails, native
  keeps the last confirmed (or the stricter requested) level and Dart reports
  the change as not confirmed; a lower level is never kept.
- **After installing M2 over M1**, native learns the levels when Smart App
  Lock's screen first starts. No app opens without the PIN/pattern before that
  (the update ends every unlock), and each unlock tells native its level, so
  re-locking follows the app's level from the first unlock.
- **Recommendations** use a fixed list of exact package names on the device.
  Nothing is uploaded and no analytics are collected. Package names were
  checked against public store listings (November 2026); a wrong entry can
  only show a dismissible hint.
- **Device behaviour is unverified** until the combined Phase 6–10 device
  round (`docs/regression.md`, Phase 8 / M2).


## Security level QA limits (Phase 8 / M3)

M3 adds regression tests only. Behaviour and permissions are unchanged. The
QA pass confirmed these bounds:

- **Unobserved transitions.** Native unlocks end on screen off, watcher
  teardown, stop and emergency exit. When the Accessibility service is
  disconnected (turned off, killed or force-stopped), switching apps is not
  reported, so a level cannot act on it. The Usage Access fallback stays
  coarser (U1-R). Smart App Lock does not claim to detect these transitions.
- **Failed upgrade, then process death.** If saving a stricter level fails
  on the native side and the process then dies, native reads the last saved
  (weaker) level until Smart App Lock's next start. No unlock survives the
  process death. Each new unlock carries the level the app shows, so
  re-locking stays strict.
- **Recommendations stay local.** The catalog file imports nothing else.
  The app has no network dependency and no INTERNET permission.
- **Device behaviour is unverified** until the combined Phase 6–10 round
  (`docs/regression.md`, Phase 8 / M3).

## Security Center limits (Phase 9 / M1)

The Security Center adds no permission, dependency or native code. It only
displays what already exists:

- **Counts are saved settings.** They come from the protected-apps
  database. An app counted as Critical is *assigned* Critical; that does
  not prove it is locked right now. The "Working now" status is the overall
  Phase 7 health result, not a per-app measurement. Smart App Lock has no
  per-app enforcement signal.
- **No absolute claims.** The status never says "100% protected",
  "guaranteed" or "impossible to bypass". SECURE means the last fresh
  check passed; a stale, unknown or failed check is never shown as SECURE.
- **Same health limits as Phase 7.** OEM background controls stay
  unobservable, and transitions during an Accessibility disconnect are not
  reported (Q6).
- **Device behaviour is unverified** until the combined Phase 6–10 round
  (`docs/regression.md`, Phase 9 / M1).

## Security Score limits (Phase 9 / M2)

- **An assessment, not a guarantee.** The score is "setup points" from
  Smart App Lock's own product-defined weights: 60 for a fresh passed
  health check, 40 for how quickly protected apps re-lock after you leave
  them. It is not a measured probability and does not measure resistance to
  bypass attempts. It is shown as "/ 100 points", never as "%".
- **Only observed or saved signals.** It counts the Phase 7 health result,
  the saved apps and levels, the native-confirmed levels and the saved
  re-lock grace. It never estimates native enforcement:
  - a level native has not confirmed earns no extra points;
  - an assignment made while protection is offline produces no number at
    all.
- **No number when it would mislead.** PROTECTION OFFLINE, a stale,
  failed or missing health check, an unreadable app list or setting, and
  unfinished setup all show a reason instead of a number (never 0, never a
  default 100). ATTENTION REQUIRED shows a **provisional** number of at
  most 40, with the problems still listed.
- **Never penalised:** unavailable or unenrolled biometrics, PIN vs
  pattern, the phone model, and how many apps you protect.
- **Same blind spots as Phase 7.** OEM battery managers stay unobservable,
  and Q6 (Accessibility disconnect transitions) applies. The 30-second
  freshness limit means an idle Security tab drops the number until Check
  again.
- **Device behaviour is unverified** until the combined Phase 6–10 round
  (`docs/regression.md`, Phase 9 / M2).

## Recommendation limits (Phase 9 / M3)

- **Advisory only.** "Recommended improvements" lists what Smart App Lock
  can observe or has saved: Phase 7 health problems, unfinished setup,
  stricter levels for apps on the Phase 8 reviewed catalog, and a shorter
  re-lock grace. Nothing is applied automatically; every change is made by
  the user through the existing screens (lowering a level still asks for
  the credential, CR-2).
- **Only exact catalog packages.** Level suggestions come from the Phase 8
  exact-package list (26 entries, some package names unverified). A wrong
  entry can only produce a hint, never a change. Unprotected apps are never
  suggested.
- **No invented fixes.** Health items reuse the Phase 7 explanations and
  repair paths. OEM battery managers and other controls Android does not
  report stay unobservable; the calm state says so.
- **Not a guarantee.** A shorter grace "would" reduce how long an app can
  stay open after you leave it; the wording never promises protection.
  Biometric and Battery Saver are never suggested.
- **Dismissals** are local and bound to the suggestion (`package@level`,
  re-lock value); they never change the score, a level or a setting. A
  suggestion is hidden only after the dismissal is saved; if the save
  fails, it stays visible with "Couldn't save your choice, so the
  suggestion is still shown. Nothing was changed." and Try again (both the
  Security Center and the Apps tab). If the saved dismissals cannot be
  read, optional suggestions are withheld rather than repeated.
- **Device behaviour is unverified** until the combined Phase 6–10 round
  (`docs/regression.md`, Phase 9 / M3).
