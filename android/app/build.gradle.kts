import com.android.build.gradle.internal.api.ApkVariantOutputImpl
import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.ksp)
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val packageName = "io.github.beomyo.purer"

// Keys

val keystoreProperties = Properties()
val keystorePropertiesFile: File = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    println("Load keystore props from file=$keystorePropertiesFile")
    // for release using credentials stored in a local file
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
} else {
    println("Load keystore props from system environment")
    // for release using credentials in environment variables set up by GitHub Actions
    // warning: in property file, single quotes should be escaped with a backslash,
    // but they should not be escaped when stored in env variables
    val env = System.getenv()
    fun getEnv(propKey: String, envKey: String) {
        if (envKey in env) {
            keystoreProperties[propKey] = env[envKey]
        }
    }
    getEnv("storeFile", "PURER_STORE_FILE")
    getEnv("storePassword", "PURER_STORE_PASSWORD")
    getEnv("keyAlias", "PURER_KEY_ALIAS")
    getEnv("keyPassword", "PURER_KEY_PASSWORD")
}

android {
    namespace = "io.github.beomyo.purer"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // enable support for the new language APIs on older devices
        // e.g. `java/util/function/Supplier` on Android 5.0 (API 21)
        isCoreLibraryDesugaringEnabled = true
    }

    kotlin {
        // Gradle looks up toolchain JDKs (for this app and each of its modules)
        // among locally installed JDKs (including in `~/.gradle/jdks/` and `~/jdks`)
        // and download them from configured repositories if necessary.
        jvmToolchain {
            languageVersion.set(JavaLanguageVersion.of(21))
            vendor.set(JvmVendorSpec.ADOPTIUM) // Temurin
            // for consistency, refresh `gradle-daemon-jvm.properties` with the following:
            // ./gradlew updateDaemonJvm --jvm-version=21 --jvm-vendor=ADOPTIUM
        }
    }

    defaultConfig {
        applicationId = packageName
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    // remove dependency metadata from build artifacts
    // cf https://izzyondroid.org/about/security/ApkScans/#signingblock-checks
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    signingConfigs {
        val storeFilePath = keystoreProperties["storeFile"] as String?
        if (storeFilePath != null) {
            println("Create signing config for release using file=$storeFilePath")
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(storeFilePath)
                storePassword = keystoreProperties["storePassword"] as String
                // enable every scheme, otherwise the v1 (JAR) signature is
                // omitted for minSdk >= 24 and some installers reject the APK
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    flavorDimensions += "store"

    productFlavors {
        create("play") {
            // single standalone distribution
            dimension = "store"
        }
    }

    buildFeatures {
        buildConfig = true
        resValues = true
    }

    packaging {
        jniLibs {
            // The native TIFF factory (libtiff/libjpeg/libimageOps) is only used
            // by local-file decoding. Remote images are decoded by the Flutter
            // engine, and remote video frames by the platform media stack, so
            // these libraries are unreachable in this app.
            excludes += setOf(
                "lib/arm64-v8a/libtiff.so",
                "lib/arm64-v8a/libjpeg.so",
                "lib/arm64-v8a/libimageOps.so",
            )
        }
    }

    buildTypes {
        getByName("debug") {
            applicationIdSuffix = ".debug"
        }

        getByName("profile") {
            applicationIdSuffix = ".profile"
        }

        getByName("release") {
            if (signingConfigs.names.contains("release")) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                println("Skip release signing as it is not configured")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")

            // NDK ABI filters are incompatible with split APK generation,
            // but filters are necessary to exclude x86 native libs from universal APKs
            // cf https://github.com/flutter/flutter/issues/37566#issuecomment-640879500
            var useNdkAbiFilters = true
            if (rootProject.extra.has("split-per-abi")) {
                val splitPerAbi = rootProject.extra["split-per-abi"]
                if (splitPerAbi == "true" || splitPerAbi == true) {
                    useNdkAbiFilters = false
                }
            }
            if (useNdkAbiFilters) {
                ndk {
                    // this app ships arm64-v8a only
                    abiFilters += listOf("arm64-v8a")
                }
            }
        }

        val abiCodes = mapOf(
            "armeabi-v7a" to 1,
            "arm64-v8a" to 2,
            "x86" to 3,
            "x86_64" to 4
        )

        applicationVariants.all {
            println("Application variant applicationId=$applicationId name=$name")

            outputs.forEach { output ->
                val abi = output.filters.find { it.filterType == "ABI" }?.identifier
                val baseAbiVersionCode = abiCodes[abi]
                if (baseAbiVersionCode != null) {
                    val versionCodeOverride = versionCode * 100 + baseAbiVersionCode
                    println("  output versionCodeOverride=$versionCodeOverride for abi=$abi")
                    (output as ApkVariantOutputImpl).versionCodeOverride = versionCodeOverride
                }
            }
        }
    }
}

androidComponents {
    onVariants { variant ->
        // uncompressed native libraries are recommended:
        // https://developer.android.com/build/releases/agp-4-2-0-release-notes#compress-native-libs-dsl
        // but compressed native libraries yield much smaller APK files (for sideloaded builds),
        // combined with `--split-per-abi` this brings the APK close to the per-device download size
        variant.packaging.jniLibs.useLegacyPackaging = true
    }
}

flutter {
    source = "../.."
}

repositories {
    maven {
        url = uri("https://jitpack.io")
        content {
            includeGroup("com.github.deckerst")
            includeGroup("com.github.deckerst.mp4parser")
        }
    }
    maven {
        url = uri("https://s3.amazonaws.com/repo.commonsware.com")
        content {
            excludeGroupByRegex("com\\.github\\.deckerst.*")
        }
    }
}

dependencies {
    // cf https://developer.android.com/studio/write/java8-support#library-desugaring
    coreLibraryDesugaring(libs.android.desugarJdkLibs)

    implementation(libs.kotlinx.coroutines.android)

    implementation(libs.androidx.annotation)
    implementation(libs.androidx.appcompat)
    implementation(libs.androidx.ktx)
    implementation(libs.androidx.performance)
    implementation(libs.androidx.lifecycle)
    implementation(libs.androidx.media)
    // Jetpack `security-crypto` library is deprecated:
    // https://developer.android.com/privacy-and-security/cryptography#security-crypto-jetpack-deprecated
    implementation(libs.androidx.security.crypto)

    implementation(libs.commonsware.cwac)
    implementation(libs.metadata.extractor)
    implementation(libs.glide)
    implementation(libs.google.material)
    // SLF4J implementation for `mp4parser`
    implementation(libs.slf4j)

    // forked, built by JitPack:
    // - https://jitpack.io/p/deckerst/Android-TiffBitmapFactory
    // - https://jitpack.io/p/deckerst/androidsvg
    // - https://jitpack.io/p/deckerst/mp4parser
    // - https://jitpack.io/p/deckerst/pixymeta-android
    implementation(libs.deckerst.tiffbitmapfactory)
    implementation(libs.deckerst.androidsvg)
    implementation(libs.deckerst.mp4parser.isoparser)
    implementation(libs.deckerst.mp4parser.muxer)
    implementation(libs.deckerst.pixymeta)
    implementation(project(":exifinterface"))

    testImplementation(libs.junit)

    ksp(libs.glideKsp)

    compileOnly(rootProject.findProject(":streams_channel")!!)
}
