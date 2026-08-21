// Top-level build file. Repository declarations live here so all
// subprojects (the :app module and any Flutter plugin modules) can resolve
// their dependencies.

// AGP 9 built-in Kotlin uses the Kotlin Gradle Plugin (KGP) as a RUNTIME
// dependency and bundles KGP 2.2.10 by default — below Flutter's minimum
// of 2.2.20. Per the AGP 9 release notes ("Upgrade to a higher KGP
// version"), declaring the KGP on the buildscript classpath upgrades the
// runtime WITHOUT applying the kotlin-android plugin: built-in Kotlin
// stays the compiler path, and the effective Kotlin becomes 2.2.20.
buildscript {
    // The buildscript classpath resolves BEFORE the allprojects block
    // below, so it needs its own repositories.
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
    dependencies {
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.2.20")
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
