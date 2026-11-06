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

subprojects {
    // 1. Disable checkReleaseAarMetadata and related checks across all plugins
    // This allows plugins targeting older SDKs (like flutter_facebook_auth with android-31) to build cleanly
    tasks.matching { it.name.contains("AarMetadata") }.configureEach {
        enabled = false
    }

    // 2. Configure Java and Kotlin compilation targets to Java 17
    tasks.withType<JavaCompile>().configureEach {
        sourceCompatibility = "17"
        targetCompatibility = "17"
    }
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    // 3. Elevate compileSdkVersion to 35 for all plugins so they compile against modern Android APIs
    val configureAndroid: Project.() -> Unit = {
        extensions.findByName("android")?.let { ext ->
            try {
                val method = ext.javaClass.getMethod("compileSdkVersion", Int::class.javaPrimitiveType)
                method.invoke(ext, 35)
            } catch (_: Exception) {
                try {
                    val method = ext.javaClass.getMethod("setCompileSdkVersion", Int::class.javaPrimitiveType)
                    method.invoke(ext, 35)
                } catch (_: Exception) {}
            }
        }
    }

    if (state.executed) {
        configureAndroid()
    } else {
        afterEvaluate {
            configureAndroid()
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
