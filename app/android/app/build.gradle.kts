plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "top.liuweiqing.handwriting_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "top.liuweiqing.handwriting_app"
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

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
