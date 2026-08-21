// Top-level build file. Repository declarations live here so all
// subprojects (the :app module and any Flutter plugin modules) can resolve
// their dependencies.
//
// Kotlin ownership: AGP 9.2's built-in Kotlin (android.builtInKotlin=true)
// is the compiler path — the app does NOT apply the Kotlin Gradle Plugin.
// However, AGP's built-in Kotlin still resolves KGP 2.2.10 as its runtime
// (below Flutter's 2.2.20 minimum). Per the AGP 9 release notes ("Upgrade
// to a higher KGP version"), declaring the KGP on the buildscript
// classpath raises the runtime without applying any plugin. The
// buildscript classpath resolves BEFORE allprojects, so it carries its
// own repositories.
buildscript {
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
