import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Requires android/app/google-services.json (not committed) -- see
    // README.md's "Setting up FCM" section.
    id("com.google.gms.google-services")
}

// Release signing config, loaded from android/key.properties (gitignored --
// see android/.gitignore). That file is never committed and points at a
// keystore kept outside the repo entirely; see README.md's release-signing
// section for how to generate both. Missing key.properties (a fresh clone,
// CI, or a contributor who only needs debug builds) falls back to null,
// which below means "keep signing release with the debug key" -- so
// `flutter build apk/appbundle --release` still works, it just isn't a
// Play-uploadable artifact until this file is created locally.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

android {
    namespace = "de.behringer24.freizone"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "de.behringer24.freizone"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Only created when android/key.properties exists (see the loader
        // above) -- a fresh clone without it falls back to the debug config
        // below, so debug builds/tests are never blocked by a missing
        // keystore. Required before any Play Store upload.
        if (keystoreProperties.isNotEmpty()) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystoreProperties.isNotEmpty()) {
                signingConfigs.getByName("release")
            } else {
                // No android/key.properties locally -- keeps `flutter build
                // apk/appbundle --release` working for local testing, but
                // this is NOT a Play-uploadable artifact until key.properties
                // (and the keystore it points at) exist. See README.md.
                signingConfigs.getByName("debug")
            }
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
