# Android protection capabilities

**Baseline:** C0 / Phases 1–5

This file is the source of truth for Android capabilities used by the current
lock engine. It describes the implementation that exists, not future phases.

## Enforcement architecture

Smart App Lock uses a hybrid design:

1. While Dart is healthy, Flutter evaluates foreground-package events and owns
   authentication, sessions, grace periods, and navigation.
2. A native foreground service holds a minimal, non-secret copy of the desired
   protection state and receives a Dart heartbeat.
3. If the heartbeat expires after process/isolate loss or reboot, native usage
   polling or accessibility events detect a protected package.
4. Native code first raises an opaque, touch-blocking
   `TYPE_APPLICATION_OVERLAY` shield, persists a pending package, and then
   launches `MainActivity` to reconstruct the Flutter challenge.
5. The shield is removed only after the Flutter challenge route is ready and
   the activity is resumed.

No PIN, password, pattern, hash, salt, or biometric material is copied into the
native recovery preferences.

## Capability model

| Capability | Classification | Current use | Behavior when unavailable |
| --- | --- | --- | --- |
| Draw over other apps (`SYSTEM_ALERT_WINDOW`) | **Required** | Opaque touch-blocking recovery/handoff shield and background-activity-launch exemption | Protection is unavailable; the UI must not claim it is active |
| Usage Access (`PACKAGE_USAGE_STATS`) | **Alternative detector** | Dart and native foreground-app polling | Accessibility can provide detection |
| Accessibility service (`BIND_ACCESSIBILITY_SERVICE`) | **Alternative detector** | Narrow window-state package events; no content retrieval | Usage Access can provide detection |
| Foreground service (`FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE`) | **Required internal capability** | Native recovery watcher | Protection cannot survive Dart/process loss |
| Notifications (`POST_NOTIFICATIONS`, API 33+) | **Optional** | Makes the ongoing service notification visible in the notification drawer | Service may run but health is degraded and notification visibility is reduced |
| Boot completed (`RECEIVE_BOOT_COMPLETED`) | **Required internal capability** | Restarts only previously configured protection after boot | Reboot recovery is unavailable |
| Launcher `<queries>` | **Required package visibility declaration** | Installed, launchable application discovery | App selection cannot be populated correctly |
| Biometrics (`USE_BIOMETRIC`) | **Optional authentication method** | Local biometric challenge when enabled by the user | Primary PIN/pattern remains available |

Minimum protection readiness is:

```text
overlay granted
AND (usage access granted OR accessibility enabled)
AND native recovery service available
AND credential configured
AND at least one protected package configured
```

Both detectors being present adds redundancy. One detector missing is a
degraded-but-available state, not a total failure. Notification denial is also
reported as degraded, not as proof that the service failed to start.

## Explicitly excluded capabilities

| Capability | Reason |
| --- | --- |
| `QUERY_ALL_PACKAGES` | Launcher `<queries>` is sufficient and less invasive |
| `USE_FULL_SCREEN_INTENT` | The handoff shield is an application overlay, not an alarm/call notification |
| Device administrator | Not necessary for the Phases 1–5 app-level lock architecture |
| Storage permissions / `MANAGE_EXTERNAL_STORAGE` | The app does not need shared-storage access |
| Camera | Intruder photography is outside the C0/Phases 1–5 baseline |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Not requested; OEM power restrictions remain a documented physical-device risk |
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
- If one detector or notification visibility is missing, protection health is
  degraded and the remaining enforcement path stays active.
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

1. alternative-detector capability combinations and truthful health states;
2. no native recovery enablement without both a credential and protected app;
3. fail-closed persistence/bootstrap errors;
4. recovery configuration surviving Flutter teardown;
5. watcher/overlay method-channel serialization;
6. authentication failure never granting a session;
7. release-manifest permission scope; and
8. process-recreation, reboot, screen, Home, Back, and task-switching behavior,
   followed by physical-device QA for Android lifecycle behavior that cannot be
   proven by a Dart unit test.
