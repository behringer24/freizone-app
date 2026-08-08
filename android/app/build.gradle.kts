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

    // The ABIs this app actually works on are exactly the set
    // native/build_android.ps1 builds libfreizonecore.so for: arm64-v8a and
    // x86_64. KEEP THE TWO IN STEP -- allowing an ABI here that has no core
    // built for it produces a build that installs and then dies.
    //
    // Without this, Flutter emits an armeabi-v7a split too, and Play serves it
    // to 32-bit-only devices. That split carried every other native library but
    // not the core, so DynamicLibrary.open failed the moment AppSession was
    // constructed -- unusable from first launch, not merely degraded. Excluding
    // the ABI shows "not compatible" in the store instead, which is honest, and
    // costs nothing: no working installation on it ever existed.
    //
    // Done here rather than with defaultConfig.ndk.abiFilters, which was tried
    // first and had no effect -- Flutter's Gradle plugin sets that itself from
    // --target-platform and overwrites it. --target-platform alone is not
    // enough either: it drops Flutter's own libflutter.so and libapp.so for the
    // ABI but leaves the plugins' prebuilt .so behind, which is a worse split
    // than before rather than none at all. Excluding at packaging time is the
    // only one of the three that acts on what actually ends up in the archive.
    //
    // 64-bit-only is ordinary now: Play has required 64-bit support since 2019,
    // and with minSdk 24 this leaves out 32-bit-only hardware from around 2016.
    //
    // No deadline on revisiting this, and deliberately so: the only change ever
    // on the table is adding the ABI back, which is purely additive -- devices
    // that cannot install today would be able to, and nobody loses anything.
    // (Shipping it and then removing it would strand users, but that is not the
    // direction available here.) So it can wait until after a launch as easily
    // as before one, and the 32-bit share only shrinks meanwhile.
    //
    // Note what to revisit it WITH. Install numbers cannot answer it: excluding
    // the ABI means Play stops
    // offering the app to those devices, so the installs are zero by
    // construction and would merely confirm the decision that caused them. They
    // were never informative here anyway, since the app crashed on launch on
    // that ABI, so any install it did have measured curiosity, not usage.
    //
    // The Play console's device catalogue is what answers it: it counts
    // *eligible devices* rather than installs, and reports how many are excluded
    // and why. That number keeps working precisely because of this exclusion.
    packaging {
        jniLibs {
            excludes += "lib/armeabi-v7a/**"
        }
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
    // ShortcutManagerCompat / ShortcutInfoCompat for the per-chat sharing
    // shortcuts in APP-15 level 2 -- the compat versions handle the API-level
    // differences (long-lived shortcuts, Person, share targets) for us.
    implementation("androidx.core:core-ktx:1.13.1")
    // FreizonePushService (APP-12) subclasses firebase_messaging's own service,
    // so FirebaseMessagingService has to be on *this* module's compile
    // classpath -- via the plugin it is only a transitive runtime dependency,
    // which is enough to run but not to extend. Version comes from the BOM so
    // it can never drift from what the plugin actually ships.
    implementation(platform("com.google.firebase:firebase-bom:33.7.0"))
    implementation("com.google.firebase:firebase-messaging")
}
