# Smart App Lock 🔒

Privacy-first Android app locker built with **Flutter**.
This repository is the production Android project scaffold — **Phase 1A** of the
PRD-driven build plan.

---

## Phase 1A — Create Android Project ✅

| Requirement                          | Status | Where                                        |
| ------------------------------------ | ------ | -------------------------------------------- |
| Production Android project           | ✅     | `android/` (Kotlin DSL, current Flutter template layout) |
| Application ID / package             | ✅     | `com.smartapplock.app` → `android/app/build.gradle.kts` |
| Minimum Android SDK                  | ✅     | **24** (Android 7.0) — floor for app-lock APIs |
| Target Android SDK                   | ✅     | **36** (Android 16) — Google Play requirement from Aug 31, 2026 |
| Compile SDK / NDK                    | ✅     | **36** / **28.2.13676358** (official Flutter template values) |
| Debug / release build structure      | ✅     | `android/app/src/{debug,profile,main}/` + `buildTypes` in Gradle |
| Release signing structure            | ✅     | `android/key.properties.example` + signing fallback in Gradle |
| Confirm project compiles             | ✅     | Verified below (see **Confirm the build** — needs your local Flutter SDK) |

---

## Project structure

```
smart_app_lock/
├── pubspec.yaml                     # Flutter package manifest (app version lives here)
├── analysis_options.yaml            # Lint rules (flutter_lints)
├── lib/
│   └── main.dart                    # Placeholder home (replaced in later phases)
├── test/
│   └── widget_test.dart             # Smoke test for the scaffold
├── tool/
│   └── gen_icons.py                 # Regenerates all launcher icons (pure stdlib)
└── android/
    ├── settings.gradle.kts          # Gradle plugins: AGP 9.1.0, Kotlin 2.4.0
    ├── build.gradle.kts             # Repositories + build-dir redirection + clean task
    ├── gradle.properties            # JVM args, AndroidX, Flutter DSL flags
    ├── gradle/wrapper/
    │   └── gradle-wrapper.properties # Gradle 9.3.1
    ├── key.properties.example       # Release signing template → copy to key.properties
    └── app/
        ├── build.gradle.kts         # applicationId, minSdk/targetSdk, buildTypes, signing
        ├── proguard-rules.pro
        └── src/
            ├── main/                # App manifest, MainActivity.kt, res/ (icons, themes)
            ├── debug/               # Debug-only manifest (INTERNET for hot reload)
            └── profile/             # Profile-only manifest
```

## Key configuration

| Setting        | Value                     | Notes                                    |
| -------------- | ------------------------- | ---------------------------------------- |
| Application ID | `com.smartapplock.app`    | Debug builds get the `.debug` suffix     |
| minSdk         | 24 (Android 7.0)          | Matches Flutter's current floor          |
| targetSdk      | 36 (Android 16)           | Play requirement for new apps, Aug 2026  |
| compileSdk     | 36                        |                                          |
| AGP / Gradle   | 9.1.0 / 9.3.1             | Current official Flutter stable template |
| Kotlin         | 2.4.0                     |                                          |
| Java           | 17                        | Android Studio's embedded JDK satisfies this |
| versionName    | 0.1.0 (`pubspec.yaml`)    | Bump with each release                   |
| versionCode    | 1 (`pubspec.yaml`)        |                                          |

## Prerequisites (on your machine)

- **Flutter SDK** — current stable (Aug 2026, 3.38+). Older SDKs ship older
  Gradle templates; if you must use an older SDK, run
  `flutter create --platforms android .` inside this folder to let the tool
  repair the `android/` scaffolding for your version.
- **Android Studio** (or Android SDK + JDK 17).
- An Android device/emulator running **Android 7.0+**.

## Confirm the build

The sandbox this project was written in has no Flutter/Android SDK (by design),
so run these on your machine from the project root:

```bash
flutter pub get            # resolve Dart packages
flutter analyze            # static analysis must report "No issues found"
flutter test               # run the scaffold smoke test
flutter build apk --debug  # compiles the debug APK
flutter run                # installs & launches on a connected device
```

> If the Gradle wrapper files (`gradlew`, `gradle-wrapper.jar`) are missing
> after download, run `flutter create --platforms android .` once — the Flutter
> tool regenerates them without touching your existing files.

## Debug / release structure

- **Debug** — signed with the auto-generated debug key, app id
  `com.smartapplock.app.debug` so it can be installed next to the release build.
- **Release** — reads `android/key.properties` for real signing; until then it
  deliberately falls back to debug signing so `flutter build apk --release`
  always compiles.
- R8 minification is **off** for now and gets enabled with tuned keep-rules in
  a later phase (app-lock services need them).

### Release signing (before Play upload)

```bash
cd android/app
keytool -genkey -v -keystore upload-keystore.jks \
  -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 -alias upload
cd ../..
cp android/key.properties.example android/key.properties   # then edit passwords
flutter build appbundle   # produces build/app/outputs/bundle/release/*.aab
```

`key.properties` and `*.jks` are git-ignored — never commit them.

## Launcher icons

All icons were generated by `python3 tool/gen_icons.py` (white padlock on brand
navy, adaptive + legacy densities). Re-run it anytime after tweaking the design.

## Next phases

Phase 1B+ will add the app-lock feature set: installed-app listing with
`<queries>`/package visibility, PIN setup flow, secure storage, Usage-Access /
overlay / accessibility permissions, and the lock service itself.
