import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

// Release signing + server config come from CI secrets (never from source):
//   ANDROID_KEYSTORE_FILE / ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_ALIAS / ANDROID_KEY_PASSWORD
//   RECON_BASE_URL / RECON_DISCOVERY_URL / RECON_API_KEY
fun env(name: String): String = System.getenv(name)?.trim().orEmpty()
fun quoted(v: String) = "\"" + v.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

val versionCodeFromCi = env("ANDROID_VERSION_CODE").toIntOrNull() ?: 1

android {
    namespace = "com.moltstrong.asbuilt.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.moltstrong.asbuilt.android"
        minSdk = 26
        targetSdk = 35
        versionCode = versionCodeFromCi
        versionName = "1.0.$versionCodeFromCi"
        buildConfigField("String", "RECON_BASE_URL", quoted(env("RECON_BASE_URL")))
        buildConfigField("String", "RECON_DISCOVERY_URL", quoted(env("RECON_DISCOVERY_URL")))
        buildConfigField("String", "RECON_API_KEY", quoted(env("RECON_API_KEY")))
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        val ks = env("ANDROID_KEYSTORE_FILE")
        if (ks.isNotEmpty() && file(ks).isFile) {
            create("release") {
                storeFile = file(ks)
                storePassword = env("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = env("ANDROID_KEY_ALIAS")
                keyPassword = env("ANDROID_KEY_PASSWORD").ifEmpty { env("ANDROID_KEYSTORE_PASSWORD") }
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            signingConfig = signingConfigs.findByName("release")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
        debug {
            applicationIdSuffix = ".debug"
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources.excludes += setOf("META-INF/{AL2.0,LGPL2.1}", "META-INF/versions/9/OSGI-INF/MANIFEST.MF")
    }

    // The bundled sample GLB must not be compressed (Filament reads it into a direct buffer).
    androidResources {
        noCompress += listOf("glb", "ktx")
    }
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    implementation(project(":core"))

    implementation(platform("androidx.compose:compose-bom:2025.02.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.10.0")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-service:2.8.7")
    implementation("androidx.exifinterface:exifinterface:1.3.7")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // AR capture + 3D viewer (Filament 1.56 with IBL).
    implementation("com.google.ar:core:1.48.0")
    implementation("io.github.sceneview:sceneview:2.3.0")

    debugImplementation("androidx.compose.ui:ui-tooling")
}
