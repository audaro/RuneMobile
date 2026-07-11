// Track G AG0 — a tiny STANDALONE GLES recon app (no embedded JVM, no NDK, no facade). Its launcher activity
// queries the device's real GLES tier + extensions on start and logs an ANDROID_AG0 verdict, so Firebase Test
// Lab Robo (which can't pass intent extras) runs it by just launching it. Separate applicationId so it installs
// alongside the main app. Built with `./gradlew :recon:assembleDebug`.
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.audaro.glesrecon"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.audaro.glesrecon"
        minSdk = 28
        targetSdk = 35
        versionCode = 1
        versionName = "0.1"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}
