import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: android/key.properties (git-ignored) points at the keystore.
// A release or profile build without it FAILS, because falling back to the
// debug key made APKs that look like releases but cannot update (or be updated
// by) the real app: Android refuses an update signed with another key. Two
// ways around it, both for builds that are never published:
//   -PallowDebugSigning=true   (flutter: --android-project-arg=allowDebugSigning=true)
//   an appIdSuffix build (the benchmark app), which installs beside the real
//   app and shares nothing with it.
// Debug builds are always debug-signed.
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) FileInputStream(file).use { load(it) }
}
val hasReleaseKey = keyProperties.containsKey("storeFile")
val debugSigningAllowed =
    project.findProperty("allowDebugSigning") == "true" || project.hasProperty("appIdSuffix")

android {
    namespace = "dev.herdrmobile.herdr_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications uses java.time and needs desugaring.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // Native code compressed in the APK. AGP's default stores .so files raw
    // (Android maps them straight from the APK), which suits a store that
    // compresses the download itself. This app is downloaded whole from a
    // GitHub release, on the radio, at every update: raw libraries were 45 of
    // its 49 MiB, and deflate takes them to about 20 (measured on 0.1.11:
    // libapp.so 11.9 -> 4.8 MiB, libflutter.so 11.2 -> 5.2 MiB for arm64).
    // The cost is on the phone: Android extracts the libraries at install,
    // so the space used after install stays about the same.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    defaultConfig {
        // `--android-project-arg=appIdSuffix=.kbbench` installs a benchmark build
        // beside the real app (own data, own icon) instead of over it.
        applicationId = "dev.herdrmobile.herdr_mobile" + (project.findProperty("appIdSuffix") as String? ?: "")
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keyProperties.containsKey("storeFile")) {
            create("release") {
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
        }
        // On-device profiling has to install over the shipped (release-signed)
        // app, or Android refuses it as a signature mismatch.
        getByName("profile") {
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
        }
    }
}

// Phones only: a plugin (jni) ships x86 libraries that the ARM-only release
// would otherwise carry for no device. Excluded per release variant, because
// the Flutter plugin replaces a build type's `ndk.abiFilters`, and an x86
// emulator's debug build still needs them.
androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        variant.packaging.jniLibs.excludes.addAll(listOf("lib/x86/**", "lib/x86_64/**"))
    }
}

gradle.taskGraph.whenReady {
    val signsRelease = allTasks.any { it.project == project && (it.name.endsWith("Release") || it.name.endsWith("Profile")) }
    if (signsRelease && !hasReleaseKey && !debugSigningAllowed) {
        throw GradleException(
            "No release signing key: create android/key.properties (storeFile, storePassword, keyAlias, " +
                "keyPassword; see README, 'Android release build'). A build signed with the debug key " +
                "cannot update the released app. For a build you will not publish, pass " +
                "--android-project-arg=allowDebugSigning=true.",
        )
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
