plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.github.sxpsimon.handwriting"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.github.sxpsimon.handwriting"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(24, flutter.minSdkVersion)
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    sourceSets.getByName("main").jniLibs.srcDir(layout.buildDirectory.dir("rust-jni").get().asFile)

    val releaseSigning = listOf(
        "HANDWRITING_ANDROID_KEYSTORE_PATH",
        "HANDWRITING_ANDROID_STORE_PASSWORD",
        "HANDWRITING_ANDROID_KEY_ALIAS",
        "HANDWRITING_ANDROID_KEY_PASSWORD",
    ).map { System.getenv(it).orEmpty() }
    signingConfigs {
        if (releaseSigning.any { it.isNotEmpty() }) {
            require(releaseSigning.all { it.isNotEmpty() }) {
                "All four HANDWRITING_ANDROID signing variables must be provided"
            }
            require(file(releaseSigning[0]).isFile) { "Android release keystore is missing" }
            create("release") {
                storeFile = file(releaseSigning[0])
                storePassword = releaseSigning[1]
                keyAlias = releaseSigning[2]
                keyPassword = releaseSigning[3]
            }
        }
    }
    buildTypes {
        release {
            // Local release-mode testing may use debug keys; publication requires
            // the complete signing environment and checks its certificate.
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// 2026-10-12：flutter run/build 均会编译并打包本地引擎。
val buildMobileEngine by tasks.registering(Exec::class) {
    val repository = rootProject.projectDir.parentFile.parentFile
    val output = layout.buildDirectory.dir("rust-jni").get().asFile
    val platforms = (project.findProperty("target-platform") as? String).orEmpty()
    val abis = if (platforms == "android-arm64") "arm64-v8a"
        else if (platforms == "android-x64") "x86_64" else "arm64-v8a,x86_64"
    commandLine(if (System.getProperty("os.name").startsWith("Windows")) "python" else "python3",
        repository.resolve("scripts/build-mobile-engine.py"), "android",
        "--ndk", android.ndkDirectory, "--output", output, "--abis", abis)
}
tasks.named("preBuild") { dependsOn(buildMobileEngine) }
