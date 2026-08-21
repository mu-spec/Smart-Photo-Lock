// Root Gradle settings for the Android build.
// AGP 9.2.1 with built-in Kotlin (android.builtInKotlin=true). No KGP is
// APPLIED anywhere; KGP 2.2.20 is declared on the settings plugin
// classpath below (apply false) — the classpath Flutter's dependency
// checker reads via AGP's internal getKotlinAndroidPluginVersion — with
// a matching root buildscript classpath entry in android/build.gradle.kts.

pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.2.1" apply false
    // KGP VERSION MANAGEMENT ONLY (apply false — the plugin is never
    // applied): AGP 9.2's built-in Kotlin resolves KGP 2.2.10 from this
    // settings plugin classpath, below Flutter's 2.2.20 minimum. This
    // request raises the resolved classpath version to 2.2.20 — the
    // mechanism Flutter's own dependency checker reads (AGP's internal
    // getKotlinAndroidPluginVersion). Built-in Kotlin remains the
    // compiler path; no plugin is applied anywhere.
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")
