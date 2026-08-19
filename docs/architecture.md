# Smart App Lock — Architecture (Phase 1B)

This document describes the layered architecture introduced in **Phase 1B**.
Locking behaviour is **not** implemented yet; this phase establishes the
folders, contracts, and rules that every later phase must follow.

---

## 1. The eight modules

```
┌──────────────────────────────────────────────────────────────────────┐
│  ui/          screens + shared widgets (Flutter only)                 │
├──────────────────────────────────────────────────────────────────────┤
│  data/        models + repository contracts                          │
│  profiles/    lock profile model + manager contract                  │
├──────────────────────────────────────────────────────────────────────┤
│  security/    PIN hashing (PBKDF2) + PIN policy  ── pure Dart        │
│  rules/       lock rule model + pure evaluation engine ── pure Dart  │
│  protection/  lock engine + access controller contracts              │
├──────────────────────────────────────────────────────────────────────┤
│  services/    Android platform bridges (MethodChannel contracts)     │
├──────────────────────────────────────────────────────────────────────┤
│  utilities/   Result, logger, time helpers  (leaf — no dependencies) │
└──────────────────────────────────────────────────────────────────────┘
```

| Module | Path | Responsibility | Key files | Implemented |
| ------ | ---- | -------------- | --------- | ----------- |
| UI | `lib/ui` | Screens, shared widgets | `screens/home/home_screen.dart`, `widgets/module_card.dart` | 1B (dashboard only) |
| Data | `lib/data` | Domain models, repository contracts | `models/app_entry.dart`, `repositories/*.dart` | contracts |
| Security | `lib/security` | PIN hashing & strength policy | `pin_hasher.dart` ✅, `pin_policy.dart` ✅ | **working primitives** |
| Protection | `lib/protection` | Lock engine, access control, unlock sessions | `lock_engine.dart`, `access_controller.dart`, `lock_session.dart` | contracts (+session model) |
| Rules | `lib/rules` | Lock rule model + pure evaluation | `lock_rule.dart`, `rule_engine.dart` ✅ | **working pure logic** |
| Profiles | `lib/profiles` | Lock profiles (groups of locked apps) | `lock_profile.dart`, `profile_manager.dart` | contracts (+model) |
| Services | `lib/services` | Android platform bridges | overlay / accessibility / device-admin / installed-apps | contracts |
| Utilities | `lib/utilities` | Shared leaf helpers | `result.dart` ✅, `app_logger.dart` ✅, `time_utils.dart` ✅ | **working** |

---

## 2. Dependency rules

1. **Pure Dart models** — files under `data/models`, `security`, `rules`,
   `profiles` must not import Flutter. They stay unit-testable and portable.
2. **Interface-first** — every platform touchpoint is an abstract contract.
   Implementations land together with the phase that needs them.
3. **`Result<T>` at every boundary** — repositories and services return
   `Result<T>` instead of throwing. In an app locker, "permission denied" is
   a normal state, not an exception.
4. **One-way flow** — `ui → data/repositories → services → Android`.
   Screens never touch platform channels directly; they consult
   repositories and controllers.
5. **Enforcement lives in `protection/` only** — UI and rules never trigger
   locks themselves; they consult `AccessController` / `LockEngine`.

---

## 3. The lock decision pipeline (future phases)

```
App launch detected (launcher intent / accessibility event / usage poll)
        │
        ▼
AccessController.evaluate(packageName)
        │  1. active LockSession?            ── yes ──► ALLOW
        │  2. RuleEngine.shouldLock(...)?    ── no  ──► ALLOW
        ▼
LockEngine.lockNow(packageName)     (overlay service draws challenge)
        ▼
LockScreen UI  ── PIN entered ──►  PinHasher.verify(...)
        │                                │ correct
        │                                ▼
        │                    AccessController.grantAccess(packageName)
        │                                │
        │                    LockSession (2 min window) ──► app opens
        └── wrong PIN ──► attempt counter (cooldown rule) ──► DENY
```

Every arrow is already represented by a contract in this phase; only the
implementation is deferred.

---

## 4. Phase roadmap (module ownership)

| Upcoming phase | Modules it will implement |
| -------------- | ------------------------- |
| Onboarding / PIN setup | `ui` (screens), `security` (verify via hasher), `data` (storage impl) |
| App list | `ui` (list screen), `services/installed_apps_service` (native impl), `data/installed_apps_repository` (cache impl) |
| Rules editor | `ui` (rule UI), `rules` (already done), `data/lock_settings_repository` impl |
| Profiles | `ui` (profile picker), `profiles/profile_manager` impl |
| Lock screen & enforcement | `ui` (challenge screen), `protection` (engine + controller impls), `services` (overlay/accessibility impls) |
| Hardening | `services/device_admin_service` impl, Keystore-backed secrets, R8 keep-rules |
