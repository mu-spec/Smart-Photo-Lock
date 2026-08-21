// Root Gradle settings for the Android build.
// AGP 9.2.1 with built-in Kotlin (android.builtInKotlin=true) — no KGP
// version is declared here. AGP's built-in Kotlin resolves KGP 2.2.10,
// below Flutter's 2.2.20 minimum; the documented "upgrade to a higher
// KGP version" classpath override lives in android/build.gradle.kts.

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
