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

// Force all subprojects (plugins) to use Java 17, for both Java and Kotlin
// compile tasks. Some hosted plugins (e.g. tflite_flutter) pin their own
// Java sourceCompatibility (often 1.8) in their own build.gradle and would
// otherwise win over a plain (non-afterEvaluate) override here, while
// Kotlin has no explicit jvmTarget and silently defaults to whatever JDK is
// running the build — producing a Java/Kotlin target mismatch that fails
// the build. Setting both from afterEvaluate, in the same block, guarantees
// our value is applied last (after the plugin's own build.gradle already
// ran) and that Java/Kotlin always agree, without needing to read back any
// AGP-managed lazy property (which throws "not yet finalized" this early).
// Skip :app since it already configures Java 17 with finalized properties.
subprojects {
    if (project.name != "app") {
        afterEvaluate {
            plugins.withType<com.android.build.gradle.BasePlugin> {
                extensions.configure<com.android.build.gradle.BaseExtension> {
                    compileOptions {
                        sourceCompatibility = JavaVersion.VERSION_17
                        targetCompatibility = JavaVersion.VERSION_17
                    }
                }
            }
            tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
                compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
