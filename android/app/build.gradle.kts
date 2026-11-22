plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "name.howison.violinPracticeCompanion"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "name.howison.violinPracticeCompanion"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Two apps from one codebase (docs/family/mandolin-app.md): the Dart side
    // reads the flavor through `appFlavor`. `default-flavor` in pubspec.yaml
    // makes a plain `flutter run` build stringlings.
    flavorDimensions += "edition"
    productFlavors {
        create("stringlings") {
            dimension = "edition"
            manifestPlaceholders["appName"] = "Stringlings"
        }
        create("mandolin") {
            dimension = "edition"
            applicationIdSuffix = ".mandolin"
            manifestPlaceholders["appName"] = "Mandolings"
        }
        create("windlings") {
            dimension = "edition"
            applicationIdSuffix = ".windlings"
            manifestPlaceholders["appName"] = "Windlings"
        }
    }

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

dependencies {
    // Shrinking imported video (VideoShrinker.kt). Pinned to the media3
    // version video_player_android already pulls in, so there is one copy of
    // media3-common in the APK rather than two that disagree.
    implementation("androidx.media3:media3-transformer:1.9.2")
    implementation("androidx.media3:media3-effect:1.9.2")
    implementation("androidx.media3:media3-common:1.9.2")
}
