# Smart App Lock 🔒

Privacy-first Android app locker built with **Flutter**.
Development follows the PRD phase plan; this repository is the production
Android project.

**Current status: Phase 1 complete (1A–1G), Phase 2 underway (2A–2B done)** —
production scaffold, architecture, navigation, design system, persistence,
secure storage, regression pass, authentication data model, and the PIN
setup screen. Locking is not implemented yet.

---

## Phase status

| Phase | Description | Status |
| ----- | ----------- | ------ |
| 1A | Create production Android project | ✅ |
| 1B | Core project architecture (8 modules) | ✅ |
| 1C | Navigation foundation (5-tab shell + placeholder screens) | ✅ |
| 1D | Base design system (tokens, components, light/dark, security status) | ✅ |
| 1E | Local persistence foundation (preferences, protected apps, security settings, profiles, rules) | ✅ |
| 1F | Secure storage foundation (Android Keystore-backed encryption, no raw PINs) | ✅ |
| 1G | Phase 1 regression (structure + test suites + on-device checklist) | ✅ |
| 2A | Authentication data model (PIN, pattern, biometric + credential state) | ✅ |
| 2B | PIN setup screen (4-digit & 6-digit flow) | ✅ |
| 2C | PIN confirmation (mandatory confirm, clean mismatch handling) | ✅ |
| 2D | Secure PIN storage (derived/verifiable material only, never raw PIN) | ✅ |
| 2E | PIN unlock screen (authentication with the configured PIN) | ✅ |
| 2F | Failed PIN attempts (tracking + increasing cooldown) | ✅ |
| 2G | Randomized keypad (optional, default off for accessibility) | ✅ |

### Phase 1A ✅ — Create Android Project

| Requirement | Value | Where |
| ----------- | ----- | ----- |
| Application ID / package | `com.smartapplock.app` | `android/app/build.gradle.kts` |
| Minimum Android SDK | **24** (Android 7.0) — floor for app-lock APIs | `android/app/build.gradle.kts` |
| Target Android SDK | **36** (Android 16) — Play requirement from Aug 31, 2026 | `android/app/build.gradle.kts` |
| Compile SDK / NDK | **37** / **28.2.13676358** (36 template + 37 for flutter_secure_storage) | `android/app/build.gradle.kts` |
| Debug / release structure | `src/{main,debug,profile}/` + `buildTypes` (debug gets `.debug` suffix) | `android/app/` |
| Release signing | `key.properties` (git-ignored) + debug-signing fallback so builds always compile | `android/` |
| Toolchain | AGP 9.1.0 · Kotlin 2.4.0 · Gradle 9.3.1 · Java 17 | `android/settings.gradle.kts` |

### Phase 1B ✅ — Core Project Architecture

Eight modules, layered with strict dependency rules. Contracts are stubs
until their feature phase; pure logic (rules, PIN hashing) is implemented
and unit-tested. See **docs/architecture.md** for the full design.

### Phase 1C ✅ — Navigation Foundation

Five-tab bottom-navigation shell (Material 3 `NavigationBar` + `IndexedStack`):
**Home · Apps · Smart · Security · Settings**. Each tab is a real screen file;
feature tabs use the shared `PlaceholderScreen` widget and will be swapped for
real UI in their feature phases. Home has quick-access tiles that jump to the
other tabs. Widget tests cover tab switching and the quick-access wiring.

### Phase 1D ✅ — Base Design System

A complete design system in `lib/design_system/`:

- **Tokens** — `DsPalette` (semantic light/dark colors), `DsSpacing`/`DsInsets`
  (4pt grid), `DsRadii`, `DsTypography` (full Material text scale), `DsTone`.
- **Light/dark foundations** — `AppTheme.light` + `AppTheme.dark` generated
  from the same tokens; the app follows `ThemeMode.system`.
- **Components** — `DsButton` (5 variants × 3 sizes, icons, loading),
  `DsCard`, `DsTextField` (labels, helper/error, password toggle),
  `DsStatusPill`, `DsSectionTitle`.
- **Security status components** — `SecurityLevel` →
  `SecurityStatusPill` / `SecurityStatusItem` / `SecurityStatusBanner`.
  The Security tab is now real UI built from them (static "not set" states
  until the PIN phase).

Screens use `context.dsColors` for colors; hard-coded values are banned
outside `lib/design_system/`.

### Phase 1E ✅ — Local Persistence Foundation

Two storage tiers behind interfaces, wired through a single dependency
container (`lib/app/app_container.dart`):

| Tier | Interface | Production | In-memory (tests) |
| ---- | --------- | ---------- | ----------------- |
| Preferences | `KeyValueStore` → typed `PreferencesStore` | `shared_preferences` | `InMemoryKeyValueStore` |
| Database | `LocalDatabase` | SQLite via `sqflite` (schema v1) | `InMemoryLocalDatabase` |

Persisted domains: **preferences** (onboarding, theme, language,
notifications), **protected applications** (upsert, order, remove),
**security settings** (one JSON doc incl. the PIN credential hash),
**profiles** (single-active invariant), **rules** (replace-as-a-set).
Repositories return `Result<T>`; screens get them from `AppContainer`
(`create()` in `main()`, `inMemory()` in tests). No protection logic yet —
this layer only stores and retrieves.

### Phase 1F ✅ — Secure Storage Foundation

Sensitive values are protected end-to-end; **raw PINs/passwords are never
stored anywhere**.

```
PIN ──► PBKDF2 (salted) ──► PinHash ──► SecuritySettings JSON
                                          │ AES-256-GCM (fresh nonce)
                                          ▼
                        enc:v1:<base64> ──► SQLite security_settings
                                          ▲
                   256-bit master key ────┘  (Android Keystore-backed
                                             flutter_secure_storage)
```

- **`SecretStore`** (`flutter_secure_storage`) — master key lives only in the
  Android Keystore (EncryptedSharedPreferences, TEE/StrongBox where present).
- **`SettingsCipher`** (AES-256-GCM, `cryptography`) — settings encrypted at
  rest with a fresh nonce per write; any tampering fails decryption loudly.
- **Repository** stores only `enc:v1:` ciphertext; legacy 1E plaintext is
  still readable (auto re-encrypts on next save); fails closed without the
  cipher.
- **`android:allowBackup="false"`** — Keystore keys can't survive device
  restore, so cloud backup is disabled to protect the vault.

### Phase 1G ✅ — Phase 1 Regression

Full verification pass — see **docs/regression.md** for the complete record:

- **Structural regression tool** — `python3 tool/verify_structure.py`
  (15 checks: imports, balance, pubspec, manifests, icons, versions, test
  inventory, barrel exports — all green).
- **Regression test suite** — `test/regression/phase1_regression_test.dart`
  covers launch, navigation, persistence (all 5 domains), the security
  chain, both theme foundations, and crash-free rendering of every tab.
- **On-device checklist** — build / install / launch / navigation / theme /
  no-crash steps for a real device, with a defect log.

### Phase 2A ✅ — Authentication Data Model

Authentication types and the credential-state architecture, in
`lib/security/credentials/`:

- **Types** — `AuthType` (pin / pattern / biometric, with primary-secret
  eligibility), `PatternPolicy` + `PatternCodec` (3x3 grid, direction
  canonicalization), `BiometricOptions` + `BiometricKind`.
- **Hashing** — shared `CredentialHash` container (the old `PinHash` is a
  back-compatible alias), shared PBKDF2-HMAC-SHA256 core, `PatternHasher`
  beside the existing `PinHasher`.
- **State architecture** — `CredentialState` / `CredentialStatus`
  (unset / enrolled / lockedOut), `AuthAttemptResult` (success / failure /
  lockout), pure `CredentialStateMachine` (attempts + cooldown), and
  `CredentialManager` (enroll / status / authenticate / clear) with a
  working `DefaultCredentialManager` that persists counters through the
  encrypted settings — lockouts survive app restarts.
- **Biometric** — `BiometricService` platform contract (no secrets stored;
  the OS owns biometric material). Wired to `AppContainer.auth`.

### Phase 2B ✅ — PIN Setup Screen

Initial PIN setup (`lib/ui/screens/pin/pin_setup_screen.dart`), supporting
**4-digit and 6-digit PINs**:

- Length choice → entry → confirmation, with animated PIN dots and a shared
  numeric keypad (`DsPinDots` + `DsPinPad` in the design system — reused by
  the future unlock screen).
- Backspace + long-press clear; mismatches and save failures show an inline
  error banner and restart the entry.
- Enrolls through `CredentialManager` (PBKDF2 → encrypted settings) and
  marks onboarding complete; success screen with a Done action that pops
  with `true`.
- `AppScope` (inherited widget) publishes the `AppContainer` to screens;
  the Security tab's "Set up PIN" banner now opens this flow
  (`RouteNames.pinSetup`).

### Phase 2C ✅ — Confirm PIN

Confirmation is **mandatory before saving** — enrollment runs only after the
second entry matches the first. Mismatches land on a dedicated state with
two clean choices:

- **Re-confirm PIN** — keeps the first entry and re-asks only the
  confirmation (for a typo in the second entry).
- **Start over** — clears everything and restarts at the first entry.

A shake animation + red error dots make mismatches unmissable, and nothing
is ever partially saved (tests assert the credential store stays empty after
a mismatch).

### Phase 2D ✅ — Secure PIN Storage

Only **derived, verifiable credential material** is persisted — the raw PIN
is never saved anywhere:

```
PIN (memory only) ──PBKDF2 (50k, salted)──► PinHash ──► encrypted settings
                                                       (AES-256-GCM,
                                                        Keystore-backed key)
```

- **`PinCredentialStore`** — a hard boundary that only accepts/returns
  hashes; the raw PIN never crosses it. `DefaultPinCredentialStore` persists
  through the encrypted settings and **refuses sub-policy hashes on save**.
- **`CredentialHashPolicy`** — validates work factor, key/salt/digest sizes
  and encodings on every read; corrupted or weakened records **fail closed**
  (strict policy wired in production via `AppContainer`).
- **Hygiene** — the setup screen drops the raw PIN from widget state the
  moment enrollment completes; nothing logs credential material.
- Tests inspect the exact persisted bytes and assert the raw PIN appears
  nowhere in storage.

### Phase 2E ✅ — PIN Unlock Screen

Full-screen authentication using the **configured PIN**
(`RouteNames.pinUnlock`, pops `true` on success):

- Dots auto-size to the enrolled PIN's recorded length (4/6) and the entry
  auto-submits at that length through `CredentialManager`.
- Wrong PIN → inline error with remaining attempts + shake (shared
  `EntryShakeMixin`); lockout → live countdown with the pad disabled until
  the cooldown expires — **persisted lockouts are picked up the moment the
  screen opens**.
- No PIN configured → guided recovery view (Set up PIN / Back).
- The Security tab's "Unlock PIN" row opens the screen (snackbar hint when
  nothing is enrolled; "Authenticated ✓" on success).

### Phase 2F ✅ — Failed PIN Attempts

Failed attempts are tracked per credential state, and the lockout cooldown
**increases with repeated failures**:

- **Escalating schedule** — `EscalatingCooldownPolicy`: 30s → 1m → 2m → 4m
  → 8m → 10m cap (base × factor^streak, configurable; factor 1 opts out).
- **Persisted streak** — `lockoutStreak` lives in the encrypted settings and
  `CredentialState`, so restarts don't reset the escalation.
- **Fair retry semantics** — after a cooldown expires the attempt counter
  restarts fresh (a fresh set of tries), while the streak — and therefore
  the next, longer cooldown — stays until a successful authentication.
- **UI** — the unlock screen's lockout countdown reflects the escalated
  duration and shows "Cooldown increases with repeated failures." from the
  second lockout onward.

### Phase 2G ✅ — Randomized Keypad (optional)

Opt-in anti-shoulder-surfing; **the accessible 1-9 layout stays the default**
until the user enables it:

- `DsPinPad` accepts a parent-supplied `digitOrder` (keys keep their
  identity by value); `shuffledDigitOrder()` does a seeded-testable
  Fisher-Yates shuffle.
- The setting persists via `SecuritySettings.randomizedKeypadEnabled`
  (default **false**) → `CredentialState` → `CredentialManager`.
- The unlock screen shuffles **once per attempt window** — stable while
  typing, reshuffled after a wrong attempt or when a lockout expires — and
  shows a "Keypad order randomized" hint. The setup screen intentionally
  stays unshuffled (predictable while creating a PIN).
- A live toggle lives on the **Security tab** (first functional option
  there).

```
lib/
├── main.dart                 # entry point (boots AppContainer.create())
├── app/                      # app shell: router, theme, DI container
│   ├── app.dart              # SmartAppLockApp (root widget, ThemeMode.system)
│   ├── app_container.dart    # single wiring point for all persistence
│   ├── app_scope.dart        # InheritedWidget exposing the container
│   ├── router.dart           # central route registry (RouteNames + AppRouter)
│   └── theme/                # AppColors (brand), AppTheme (light + dark)
├── design_system/            # base design system (Phase 1D)
│   ├── ds_palette.dart       # semantic light/dark color tokens
│   ├── ds_spacing.dart       # spacing scale + EdgeInsets presets
│   ├── ds_radii.dart         # corner radius scale
│   ├── ds_typography.dart    # full Material text scale
│   ├── ds_tone.dart          # neutral/success/warning/danger/info
│   ├── ds_theme.dart         # light/dark ThemeData builders
│   ├── ds_context.dart       # context.dsColors extension
│   ├── design_system.dart    # barrel export
│   ├── widgets/              # DsButton, DsCard, DsTextField, DsStatusPill,
│   │                         # DsSectionTitle, DsPinDots, DsPinPad
│   └── security/             # SecurityLevel, SecurityStatusPill/Item/Banner
├── ui/                       # screens & shared widgets
│   ├── shell/                # MainShell: bottom NavigationBar + IndexedStack
│   ├── screens/
│   │   ├── home/             # Home tab (welcome, status, quick access)
│   │   ├── apps/             # Apps tab (placeholder)
│   │   ├── smart/            # Smart tab (placeholder)
│   │   ├── security/         # Security tab (status banner + control list)
│   │   ├── settings/         # Settings tab (placeholder)
│   │   └── pin/              # PIN setup (2B) + unlock (2E) flows
│   └── widgets/              # PlaceholderScreen, EntryShakeMixin (shared
│                             # PIN-entry shake feedback)
├── data/                     # persistence (Phase 1E)
│   ├── models/               # AppEntry, ProtectedApp, SecuritySettings
│   ├── storage/              # KeyValueStore, LocalDatabase, PreferencesStore
│   │   └── impl/             # shared_preferences, sqflite, in-memory stores
│   └── repositories/         # contracts + impls (protected apps, security
│                             # settings, profiles & rules)
├── security/                 # PIN hashing, secret store, credentials
│   ├── pin_hasher.dart       # PBKDF2-HMAC-SHA256 (PinHash = CredentialHash)
│   ├── pin_policy.dart       # 4-6 digit PIN validation
│   ├── storage/              # SecretStore + FlutterSecureSecretStore
│   │                         # (Android Keystore-backed) + in-memory impl
│   ├── encryption/           # SettingsCipher + AES-256-GCM implementation
│   └── credentials/          # Phase 2A: authentication data model
│       ├── auth_type.dart    # PIN / pattern / biometric
│       ├── credential_hash.dart  # shared hash container (PinHash alias)
│       ├── credential_hash_policy.dart # 2D: storage security policy
│       ├── pbkdf2.dart       # shared PBKDF2-HMAC-SHA256 core
│       ├── pattern_codec.dart    # 3x3 grid model + direction canonicalization
│       ├── pattern_policy.dart   # pattern validation rules
│       ├── pattern_hasher.dart   # PBKDF2 pattern hashing
│       ├── biometric_options.dart# biometric configuration (no secrets stored)
│       ├── auth_result.dart      # AuthSuccess / AuthFailure / AuthLockedOut
│       ├── credential_state.dart # enrolled/primary/attempts/lockout snapshot
│       ├── credential_state_machine.dart # pure attempt & cooldown logic
│       ├── cooldown_policy.dart      # 2F: escalating cooldown schedule
│       ├── credential_manager.dart# lifecycle contract
│       ├── pin_storage.dart      # 2D: secure PIN storage boundary
│       └── impl/             # DefaultCredentialManager (persistent counters),
│                             # DefaultPinCredentialStore (hashes only)
├── protection/               # lock enforcement contracts
│   ├── lock_engine.dart      # LockEngine interface (overlay/accessibility/admin)
│   ├── access_controller.dart# AccessDecision: allow / challenge / deny
│   └── lock_session.dart     # temporary unlock window model (working)
├── rules/                    # lock rule model + evaluation (working)
│   ├── lock_rule.dart        # always / timeWindow / launchLimit
│   └── rule_engine.dart      # pure shouldLock(...) decision logic
├── profiles/                 # lock profiles
│   ├── lock_profile.dart     # named package sets ("Kids mode", ...)
│   └── profile_manager.dart  # CRUD + activation contract
├── services/                 # Android platform bridge contracts
│   ├── installed_apps_service.dart
│   ├── overlay_lock_service.dart      # SYSTEM_ALERT_WINDOW strategy
│   ├── accessibility_lock_service.dart# foreground-app detection
│   └── device_admin_service.dart      # uninstall protection
└── utilities/                # leaf helpers (working)
    ├── result.dart           # Result<T> (Success/Failure) for every boundary
    ├── app_logger.dart       # leveled debug logging
    └── time_utils.dart       # minutes-of-day, overnight windows, formatting
```

**Tests** (run with `flutter test`): randomized keypad suites (pad digit
order rendering, deterministic seeded shuffle, opt-in unlock behavior with
reshuffle-on-failure, Security tab toggle persistence + disabled-without-
container), PIN unlock suites (configured-length dots 4/6, correct PIN pops
true, wrong PIN error + remaining attempts, lockout view + disabled pad,
pre-existing lockout on open, countdown expiry via injected clock,
no-credential recovery, escalating second lockout with 60s cooldown +
notice), cooldown policy suite (schedule, cap, custom factor, opt-out),
state machine escalation tests (streak increments, success resets,
expired-lockout semantics), PIN storage suites (hash
policy violations, save/load round-trip, raw-PIN-never-in-storage byte
inspection, fail-closed corrupted records, manager integration), PIN setup
flow (4-digit happy path, 6-digit happy path, mismatch state incl.
re-confirm / repeated mismatch / start-over and no-partial-enrollment
guarantees, backspace/long-press clear, initialLength, length change), PIN
pad + PIN dots component suites,
credential suites (auth types, pattern codec & policy, pattern hasher,
biometric options, credential state, state machine, credential manager
incl. lockout persistence), Phase 1G regression suite (launch, navigation,
persistence, security chain, theme, no-crashes), secure-storage suites
(secret store, AES-GCM cipher incl. tamper detection & key reuse, encrypted
settings repository incl. legacy fallback and no-raw-PIN invariant),
persistence suites (preferences store, protected apps, security settings,
profiles & rules, container integration), navigation tests (tab switching,
quick-access tiles, offstage assertions), design-system component tests
(button, input, card, section title, security status pill/item/banner,
theme + palette + scales), PIN hasher round-trip, rule engine (incl.
midnight-wrapping windows), lock session expiry, Result type.
Structural checks: `python3 tool/verify_structure.py` (no SDK needed).

---

## Key configuration

| Setting | Value |
| ------- | ----- |
| Application ID | `com.smartapplock.app` (debug builds: `com.smartapplock.app.debug`) |
| minSdk / targetSdk / compileSdk | 24 / 36 / 37 |
| AGP / Gradle / Kotlin | 9.1.0 / 9.3.1 / 2.4.0 |
| Java | 17 |
| versionName / versionCode | `0.14.0` / `15` (in `pubspec.yaml`) |
| Dependencies | `crypto` (PIN hashing), `shared_preferences` (preferences), `sqflite` + `path` (database), `flutter_secure_storage` (Keystore-backed secrets), `cryptography` (AES-GCM) |

## Prerequisites (on your machine)

- **Flutter SDK** — current stable (3.38+; tested on 3.47). Older SDKs ship
  older Gradle templates; if you must use an older SDK, run
  `flutter create --platforms android .` once to repair `android/`.
- **Android Studio** (or Android SDK + JDK 17).
- An Android device/emulator running **Android 7.0+**.

## Getting the code & building

```bash
git clone https://github.com/mu-spec/Smart-Photo-Lock.git
cd Smart-Photo-Lock
flutter pub get            # resolve packages (downloads `crypto`)
flutter analyze            # static analysis
flutter test               # unit + widget tests
flutter build apk --debug  # or: flutter build apk --release
```

APK output: `build/app/outputs/flutter-apk/app-{debug,release}.apk`

> Updating after a new phase is pushed: `git pull && flutter pub get`

## Debug / release structure

- **Debug** — debug-signed, app id `com.smartapplock.app.debug` (installable
  next to the release build). Has INTERNET for hot reload.
- **Release** — reads `android/key.properties` for real signing; falls back
  to debug signing until that file exists, so builds always compile.
- R8 minification is **off** until the hardening phase adds keep-rules for
  the lock services.

### Release signing (before Play upload)

```bash
cd android/app
keytool -genkey -v -keystore upload-keystore.jks \
  -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 -alias upload
cd ../..
cp android/key.properties.example android/key.properties   # then edit passwords
flutter build appbundle   # outputs build/app/outputs/bundle/release/*.aab
```

`key.properties` and `*.jks` are git-ignored — never commit them.

## Launcher icons

Generated by `python3 tool/gen_icons.py` (white padlock on brand navy,
adaptive + legacy densities). Re-run anytime after tweaking the design.

## Next phases

Phase 2 continues: pattern & biometric setup → app list (Apps tab) → smart
automations (Smart tab) → lock screen & enforcement → hardening. Each
phase's module ownership is mapped in `docs/architecture.md`.
