pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "RuneliteAndroid"
include(":app")
include(":recon") // Track G AG0 — standalone GLES recon app (dev.audaro.glesrecon)
