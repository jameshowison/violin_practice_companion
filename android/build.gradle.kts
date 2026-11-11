allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Older plugins (flutter_js 0.8) compile Java for 11 and Kotlin for 1.8, which
// Kotlin's Gradle plugin rejects as an inconsistent JVM target. Overriding the
// Java side doesn't stick (AGP re-applies the plugin's compileOptions), so make
// each Kotlin task follow its own variant's javac target instead.
// Some plugins (file_picker 8) still compile against android-34, but
// flutter_plugin_android_lifecycle now requires 36 of anything depending on it.
// Raise only library modules' compileSdk (the headers they build against — no
// runtime change); bumping file_picker's major version would touch iOS too.
subprojects {
    if (!state.executed) afterEvaluate {
        extensions.findByType(com.android.build.api.dsl.LibraryExtension::class.java)?.let {
            if ((it.compileSdk ?: 0) < 36) it.compileSdk = 36
        }
    }
}

subprojects {
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        val javac = project.tasks.findByName(name.replace("Kotlin", "JavaWithJavac"))
            as? JavaCompile ?: return@configureEach
        compilerOptions.jvmTarget.set(
            org.jetbrains.kotlin.gradle.dsl.JvmTarget.fromTarget(javac.targetCompatibility))
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
