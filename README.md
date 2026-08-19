# Smart App Lock 🔒

Privacy-first Android app locker built with **Flutter**.
Development follows the PRD phase plan; this repository is the production
Android project.

**Current status: Phase 1A + 1B + 1C + 1D complete** — production project
scaffold, core architecture, five-tab navigation, and base design system.
Locking is not implemented yet.

---

## Phase status

| Phase | Description | Status |
| ----- | ----------- | ------ |
| 1A | Create production Android project | ✅ |
| 1B | Core project architecture (8 modules) | ✅ |
| 1C | Navigation foundation (5-tab shell + placeholder screens) | ✅ |
| 1D | Base design system (tokens, components, light/dark, security status) | ✅ |

### Phase 1A ✅ — Create Android Project

| Requirement | Value | Where |
| ----------- | ----- | ----- |
| Application ID / package | `com.smartapplock.app` | `android/app/build.gradle.kts` |
| Minimum Android SDK | **24** (Android 7.0) — floor for app-lock APIs | `android/app/build.gradle.kts` |
| Target Android SDK | **36** (Android 16) — Play requirement from Aug 31, 2026 | `android/app/build.gradle.kts` |
| Compile SDK / NDK | **36** / **28.2.13676358** (official Flutter template) | `android/app/build.gradle.kts` |
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

```
lib/
├── main.dart                 # entry point
├── app/                      # app shell: router, theme
│   ├── app.dart              # SmartAppLockApp (root widget, ThemeMode.system)
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
│   │                         # DsSectionTitle
│   └── security/             # SecurityLevel, SecurityStatusPill/Item/Banner
├── ui/                       # screens & shared widgets
│   ├── shell/                # MainShell: bottom NavigationBar + IndexedStack
│   ├── screens/
│   │   ├── home/             # Home tab (welcome, status, quick access)
│   │   ├── apps/             # Apps tab (placeholder)
│   │   ├── smart/            # Smart tab (placeholder)
│   │   ├── security/         # Security tab (status banner + control list)
│   │   └── settings/         # Settings tab (placeholder)
│   └── widgets/              # PlaceholderScreen (shared by feature tabs)
├── data/                     # models + repository contracts
│   ├── models/               # AppEntry (pure Dart)
│   └── repositories/         # InstalledAppsRepository, LockSettingsRepository
├── security/                 # PIN hashing & policy (working)
│   ├── pin_hasher.dart       # PBKDF2-HMAC-SHA256 (crypto package)
│   └── pin_policy.dart       # 4-6 digit PIN validation
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

**Tests** (run with `flutter test`): navigation tests (tab switching,
quick-access tiles, offstage assertions), design-system component tests
(button, input, card, section title, security status pill/item/banner,
theme + palette + scales), PIN hasher round-trip, rule engine (incl.
midnight-wrapping windows), lock session expiry, Result type.

---

## Key configuration

| Setting | Value |
| ------- | ----- |
| Application ID | `com.smartapplock.app` (debug builds: `com.smartapplock.app.debug`) |
| minSdk / targetSdk / compileSdk | 24 / 36 / 36 |
| AGP / Gradle / Kotlin | 9.1.0 / 9.3.1 / 2.4.0 |
| Java | 17 |
| versionName / versionCode | `0.4.0` / `4` (in `pubspec.yaml`) |
| Dependencies | `crypto` (PIN hashing) |

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

Onboarding + PIN setup → app list (Apps tab) → smart automations (Smart tab)
→ security settings (Security tab) → lock screen & enforcement → hardening.
Each phase's module ownership is mapped in `docs/architecture.md`.
