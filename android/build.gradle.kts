plugins {
    id("com.android.application") version "8.6.0" apply false
    id("org.jetbrains.kotlin.android") version "2.0.20" apply false
    // Kotlin 2.0+ Compose compiler is a Gradle plugin, version-locked to the Kotlin version.
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.20" apply false
}
