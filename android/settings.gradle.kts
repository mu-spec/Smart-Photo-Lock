// Root Gradle settings for the Android build.
// AGP 9.2.1: built-in Kotlin at a KGP runtime >= 2.2.20 (Flutter's
// minimum). Kotlin is provided by AGP's built-in Kotlin support
// (android.builtInKotlin=true) — no KGP version is declared here.

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
}

include(":app")
