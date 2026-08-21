// Top-level build file. Repository declarations live here so all
// subprojects (the :app module and any Flutter plugin modules) can resolve
// their dependencies.
//
// Kotlin ownership: AGP 9.2's built-in Kotlin (android.builtInKotlin=true)
// is the compiler path — the app does NOT apply the Kotlin Gradle Plugin.
// KGP 2.3.20 is raised in TWO places, both per official guidance:
//  * settings.gradle.kts plugins block (apply false) — the classpath
//    Flutter's dependency checker actually reads (AGP's internal
//    getKotlinAndroidPluginVersion);
//  * the buildscript classpath below — the documented AGP "upgrade to a
//    higher KGP version" mechanism, covering AGP flows that resolve KGP
//    from the root classpath.
// Both declare the SAME version, so they reinforce rather than conflict.
buildscript {
    // The buildscript classpath resolves BEFORE the allprojects block
    // below, so it needs its own repositories.
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
    dependencies {
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.3.20")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Redirect the Gradle build directory to the Flutter root `build/` folder
// so `flutter clean` and tooling stay consistent.
val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
