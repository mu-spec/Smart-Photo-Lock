// Top-level build file. Repository declarations live here so all
// subprojects (the :app module and any Flutter plugin modules) can resolve
// their dependencies.
//
// Kotlin ownership: AGP 9.2's built-in Kotlin (android.builtInKotlin=true)
// carries a KGP runtime >= 2.2.20 — Flutter's minimum — so there is NO
// manual Kotlin classpath/plugin declaration anywhere.

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
