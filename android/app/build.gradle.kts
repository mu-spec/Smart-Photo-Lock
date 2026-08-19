import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin
    // Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// Release signing.
// Credentials are loaded from android/key.properties (git-ignored).
// While that file is absent, the release build is debug-signed so the
// project always compiles. See README -> "Release signing".
// ---------------------------------------------------------------------------
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    // Java/Kotlin package used for generated classes (R, BuildConfig).
    namespace = "com.smartapplock.app"

    // SDK levels — match the current official Flutter stable template
    // (compileSdk/targetSdk 36 = Android 16, required by Google Play for new
    // submissions after Aug 31, 2026; minSdk 24 = Android 7.0).
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    defaultConfig {
        // The unique, production application ID. Never changes once published.
        applicationId = "com.smartapplock.app"

        minSdk = 24          // Android 7.0 — floor for app-lock APIs (usage stats, overlays)
        targetSdk = 36       // Android 16 — Play requirement as of Aug 2026
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        // Debug and release can be installed side by side thanks to the
        // `.debug` suffix (handy while testing both builds on one device).
        debug {
            applicationIdSuffix = ".debug"
            // Note: a suffixed applicationId means the debug build uses
            // com.smartapplock.app.debug.
        }
        release {
            // Falls back to debug signing until android/key.properties + the
            // upload keystore exist. See README -> "Release signing".
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

            // R8 shrinking/obfuscation is intentionally OFF for now; app-lock
            // features (accessibility service, reflection-heavy plugins) will
            // need tuned keep-rules before enabling in a later phase.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}
