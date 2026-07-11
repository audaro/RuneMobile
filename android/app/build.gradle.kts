plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// PROD-RELEASE-ENG-02: release signing key material loaded from a gitignored keystore.properties (the key never
// enters the repo — android/.gitignore ignores it + *.jks/*.keystore). Absent (CI / a fresh clone / debug-only
// dev) -> the release build falls back to the debug key, so assembleRelease still yields an installable APK.
// See keystore.properties.example for the format + key generation / rotation.
val keystorePropsFile = rootProject.file("keystore.properties")
val keystoreProps: Map<String, String> =
    if (keystorePropsFile.exists()) {
        keystorePropsFile
            .readLines()
            .mapNotNull { it.trim().takeIf { l -> l.isNotEmpty() && !l.startsWith("#") && l.contains('=') } }
            .associate { it.substringBefore('=').trim() to it.substringAfter('=').trim() }
    } else {
        emptyMap()
    }
// A present-but-incomplete keystore.properties is user error — FAIL the build rather than silently sign with the
// debug key (shipping an unintended signature). Only a fully ABSENT file falls back to debug. This also makes the
// getValue("storeFile") below safe (all four keys are guaranteed non-blank when hasReleaseKey is true).
val requiredKeystoreKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val hasReleaseKey: Boolean =
    when {
        !keystorePropsFile.exists() -> false

        requiredKeystoreKeys.all { keystoreProps[it]?.isNotBlank() == true } -> true

        else -> throw GradleException(
            "android/keystore.properties is present but incomplete — it needs non-empty " +
                requiredKeystoreKeys.joinToString() + ". Fix it (see keystore.properties.example), or delete it to " +
                "fall back to debug signing.",
        )
    }

android {
    namespace = "dev.audaro.runemobile"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.audaro.runemobile"
        minSdk = 28
        targetSdk = 35
        // PROD-VERSIONING-UPDATE-04: semver versionName + a versionCode DERIVED from it, so a release bump is a
        // single edit and versionCode stays monotonic (Android verifies updates by a strictly-increasing
        // versionCode). Scheme: major*10000 + minor*100 + patch (room for 99 minors/patches). Record every bump
        // in CHANGELOG.md.
        val verMajor = 0
        val verMinor = 1
        val verPatch = 0
        val semverCode = verMajor * 10000 + verMinor * 100 + verPatch
        // CI rolling builds (tools/ci/) pass -PversionCodeOverride=<monotonic> and -PversionNameSuffix=<-master.N+sha>
        // so every merge-built APK is a strictly-newer update than the last; a normal local/tagged build passes
        // neither and gets the plain semver code/name. The override must stay > any semver-derived code to remain
        // monotonic across channels (CI uses a base well above the semver range — see build-release-artifacts.sh).
        val versionCodeOverride = (project.findProperty("versionCodeOverride") as String?)?.toIntOrNull()
        val versionNameSuffix = (project.findProperty("versionNameSuffix") as String?).orEmpty()
        versionName = "$verMajor.$verMinor.$verPatch$versionNameSuffix"
        versionCode = versionCodeOverride ?: semverCode

        ndk {
            // Emulator on Apple Silicon runs arm64 natively; the embedded HotSpot
            // JRE is an arm64 (bionic) build, so we ship only this ABI for now.
            abiFilters += "arm64-v8a"
        }

        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    // The embedded JRE + client jars are unpacked to filesDir on first launch (AssetInstaller uses
    // ctx.assets.open(), which transparently inflates), and the app .so are extracted on install
    // (extractNativeLibs=true) — so none are ever read in-place from the APK. Letting the jars + .so
    // DEFLATE in the APK is therefore a download-size win (~20 MB) and runtime-neutral; the big modules
    // jimage already compresses + boots through the same path. Only the tiny .dat/.bin stay stored.
    androidResources {
        noCompress += listOf("dat", "bin")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }

    signingConfigs {
        // Created ONLY when keystore.properties supplies a key — otherwise the release build falls back to the
        // debug key (below), so a keyless clone/CI still builds. storeFile is resolved relative to android/.
        if (hasReleaseKey) {
            create("release") {
                storeFile = rootProject.file(keystoreProps.getValue("storeFile"))
                storePassword = keystoreProps["storePassword"]
                keyAlias = keystoreProps["keyAlias"]
                keyPassword = keystoreProps["keyPassword"]
            }
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
        }
        release {
            // R8/minify stays OFF on purpose: the embedded RuneLite engine + our headless bridges are resolved
            // by NAME via JNI FindClass (net.runelite.client.headless.*, DeviceHeadlessBoot, UnsafePokeActivation)
            // and RuneLite leans heavily on reflection internally — shrinking/renaming would break the engine. The
            // APK size is dominated by the unshrinkable native JRE + jars anyway, so R8 would save little.
            isMinifyEnabled = false
            isShrinkResources = false
            // PROD-RELEASE-ENG-02: sign with the dedicated release key when keystore.properties supplies one
            // (stable signature for sideload updates); otherwise fall back to the AOSP debug key so a keyless
            // clone/CI still produces an installable APK. NOTE: switching keys breaks update-in-place for anyone
            // on the old signature — keep the same keystore once a build has been shared.
            signingConfig =
                if (hasReleaseKey) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
                }
        }
    }

    // A4: Jetpack Compose for the data-driven plugin UI (the live overlays stay classic Views — see
    // PORT-PHASING.md §4.2 hybrid decision).
    buildFeatures {
        compose = true
        buildConfig = true // A8: BuildConfig.DEBUG gates dev-only logging (stdio pipe, token PII, ext storage)
    }
}

// PROD-SECURITY-01 defense-in-depth: tokens.json is a live, replayable Jagex session secret. It lives ONLY under
// src/debug/assets (so release never bundles it), but src/main/assets is merged into EVERY variant — a stray copy
// left there locally (the path is gitignored, not absent) would silently ship in a release artifact and leak an
// account. This finalizer fails the release build fast if the secret ever reaches the merged release assets. It has
// no inputs/outputs, so it always runs (never UP-TO-DATE) whenever a release asset merge is in the graph.
val verifyNoReleaseSecret =
    tasks.register("verifyNoReleaseSecret") {
        description = "Fail the release build if the tokens.json session secret is present in the merged release assets."
        doLast {
            val merged =
                layout.buildDirectory
                    .dir("intermediates/assets/release")
                    .get()
                    .asFile
            if (merged.exists()) {
                val leaked = merged.walkTopDown().filter { it.isFile && it.name == "tokens.json" }.toList()
                if (leaked.isNotEmpty()) {
                    throw GradleException(
                        "PROD-SECURITY-01: tokens.json must never ship in a release artifact — found " +
                            leaked.joinToString { it.relativeTo(merged).path } +
                            ". Delete app/src/main/assets/tokens.json; the bundled session secret belongs only under " +
                            "app/src/debug/assets (debug builds).",
                    )
                }
            }
        }
    }
tasks.matching { it.name == "mergeReleaseAssets" }.configureEach { finalizedBy(verifyNoReleaseSecret) }

// PROD-RELEASE-ENG-01 / PROD-QA-02 fail-fast asset guard: the embedded JRE + the gpu/rlhd client jars are
// gitignored and produced by the ordered staging recipe (README "Full build-from-clean"). A fresh clone that runs
// assembleRelease WITHOUT staging them builds an APK that hard-aborts before JNI_CreateJavaVM — bootJvm requires
// client-*-gpu.jar and returns un-bootable on EVERY renderer when it is absent (MainActivity ~2875). Fail the
// release build now, with a pointer to the recipe, instead of shipping a silently-broken artifact. (Until the
// staging is wired into the Gradle graph — the remaining ENG-01 leg — this guard is what enforces the manual order.)
val verifyReleaseBootAssets =
    tasks.register("verifyReleaseBootAssets") {
        description = "Fail the release build if the staged JRE / gpu / rlhd boot artifacts are missing from the merged release assets."
        doLast {
            val merged =
                layout.buildDirectory
                    .dir("intermediates/assets/release")
                    .get()
                    .asFile
            if (!merged.exists()) return@doLast
            val files = merged.walkTopDown().filter { it.isFile }.toList()
            val missing = mutableListOf<String>()
            if (files.none { it.name.startsWith("client-") && it.name.endsWith("-gpu.jar") }) {
                missing += "jvm/client-*-gpu.jar (android/dev-tools/gpu/stage-android-gpu-jar.sh) — boot-fatal on every renderer"
            }
            if (files.none { it.name.startsWith("client-") && it.name.endsWith("-rlhd.jar") }) {
                missing += "jvm/client-*-rlhd.jar (android/dev-tools/gpu/stage-rlhd-zone-jar.sh) — 117HD renderer"
            }
            if (files.none { it.name == "libjvm.so" }) {
                missing += "jvm/jre/ embedded runtime (tools/stage-android-jre.sh)"
            }
            if (missing.isNotEmpty()) {
                throw GradleException(
                    "PROD-RELEASE-ENG-01: the release assets are missing boot artifacts:\n  - " +
                        missing.joinToString("\n  - ") +
                        "\nRun the ordered build-from-clean recipe in android/README.md (JRE -> :client:shadowJar -> gpu " +
                        "-> rlhd -> mobile-runtime) before assembleRelease; a build without these is un-bootable.",
                )
            }
        }
    }
tasks.matching { it.name == "mergeReleaseAssets" }.configureEach { finalizedBy(verifyReleaseBootAssets) }

// PROD-RELEASE-ENG-01: self-stage the gitignored boot artifacts (embedded JRE, gpu/rlhd client jars, probes.jar,
// runtime.tag) from Gradle so a clean clone yields a BOOTABLE APK without hand-running the README recipe. Each step
// Exec-wraps the existing tracked staging script (the shared :client jar lives in the SEPARATE root build, so it is
// reached via a nested `./gradlew :client:shadowJar`, not a cross-build dependsOn). Every task is
// onlyIf{ its own output is absent } — so an incremental build (artifacts already staged) SKIPS all of them with
// zero overhead, and only a fresh tree pays the cost. A shared headless/ change still needs a manual re-stage
// (delete the jars/runtime.tag or run `:app:stageBootAssets`); verifyReleaseBootAssets is the backstop.
val repoRoot: File = rootDir.parentFile
val jvmAssets = file("src/main/assets/jvm")
val clientLibs = File(repoRoot, "runelite-client/build/libs")
val stagingJavaHome = System.getenv("JAVA_HOME") ?: "/opt/homebrew/opt/openjdk@21"
// Version-precise staging guards: a version bump renames every artifact (client-<ver>-*.jar), so the guards check
// for the CURRENT version's jar (read from the root gradle.properties) rather than any client-*-*.jar — otherwise a
// bump would skip on a stale prior-version jar and ship the old client. null (gradle.properties unreadable) => stage
// (fail safe — never skip on uncertainty).
val clientVersion: String? =
    runCatching {
        File(repoRoot, "gradle.properties")
            .readLines()
            .firstOrNull { it.startsWith("project.build.version=") }
            ?.substringAfter("=")
            ?.trim()
    }.getOrNull()

fun jvmMissingVersioned(suffix: String) = clientVersion == null || !File(jvmAssets, "client-$clientVersion$suffix").exists()

val stageJre =
    tasks.register<Exec>("stageJre") {
        group = "staging"
        description = "Stage the SHA-pinned bionic OpenJDK 21 into assets/jvm/jre (if absent)."
        workingDir = repoRoot
        commandLine("bash", "tools/stage-android-jre.sh")
        onlyIf { !File(jvmAssets, "jre/lib/server/libjvm.so").exists() }
    }
val shadowJarClient =
    tasks.register<Exec>("shadowJarClient") {
        group = "staging"
        description = "Build the shared :client shaded jar in the root build (gpu/rlhd/probes need it)."
        workingDir = repoRoot
        environment("JAVA_HOME", stagingJavaHome)
        commandLine("./gradlew", "--no-daemon", ":client:shadowJar")
        onlyIf { clientVersion == null || !File(clientLibs, "client-$clientVersion-shaded.jar").exists() }
    }
val buildProbes =
    tasks.register<Exec>("buildProbes") {
        group = "staging"
        description = "Build probes.jar (on the Android boot classpath; folds in CACIO)."
        dependsOn(shadowJarClient)
        workingDir = File(repoRoot, "ios/app")
        environment("JAVA_HOME", stagingJavaHome)
        commandLine("bash", "build-probes.sh")
        onlyIf { !File(repoRoot, "ios/app/jvm-resources/probes.jar").exists() }
    }
val stageGpuJar =
    tasks.register<Exec>("stageGpuJar") {
        group = "staging"
        description = "Derive client-*-gpu.jar from the shaded jar."
        dependsOn(shadowJarClient)
        workingDir = File(repoRoot, "android/dev-tools/gpu")
        environment("JAVA_HOME", stagingJavaHome)
        commandLine("bash", "stage-android-gpu-jar.sh")
        onlyIf { jvmMissingVersioned("-gpu.jar") }
    }
val stageRlhdJar =
    tasks.register<Exec>("stageRlhdJar") {
        group = "staging"
        description = "Derive client-*-rlhd.jar (117HD Zone) from the shaded jar."
        dependsOn(shadowJarClient)
        mustRunAfter(stageGpuJar) // serialize: the gpu/rlhd stages share a scratch dir
        workingDir = File(repoRoot, "android/dev-tools/gpu")
        environment("JAVA_HOME", stagingJavaHome)
        commandLine("bash", "stage-rlhd-zone-jar.sh")
        onlyIf { jvmMissingVersioned("-rlhd.jar") }
    }
val stageMobileRuntime =
    tasks.register<Exec>("stageMobileRuntime") {
        group = "staging"
        description = "Stage probes + fold shaded/gpu/rlhd SHAs into runtime.tag (runs after gpu/rlhd)."
        dependsOn(shadowJarClient, buildProbes, stageGpuJar, stageRlhdJar)
        workingDir = repoRoot
        environment("JAVA_HOME", stagingJavaHome)
        commandLine("bash", "tools/stage-mobile-runtime.sh", "--no-build", "--android-only")
        onlyIf {
            val tag = File(jvmAssets, "runtime.tag")
            // (re-)fold when the tag/probes are absent, or when any staged jar is newer than the tag — e.g. a version
            // bump just re-staged gpu/rlhd, so the tag must be recomputed rather than left stale.
            !tag.exists() || !File(jvmAssets, "probes.jar").exists() ||
                jvmAssets.listFiles()?.any {
                    it.name.startsWith("client-") && it.name.endsWith(".jar") && it.lastModified() > tag.lastModified()
                } == true
        }
    }
val stageBootAssets =
    tasks.register("stageBootAssets") {
        group = "staging"
        description = "Stage every gitignored boot artifact (JRE + gpu/rlhd/probes + runtime.tag) for a bootable APK."
        dependsOn(stageJre, stageMobileRuntime)
    }
// A clean tree self-stages before the asset merge; an already-staged tree skips every step above (onlyIf) → no
// overhead on the normal incremental loop.
tasks.named("preBuild") { dependsOn(stageBootAssets) }

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.browser:browser:1.8.0") // AP-0 outbound links + A3 on-device login (consent flow in a Custom Tab)

    // Compose (BOM-versioned) for the A4 plugin list / config UI.
    val composeBom = platform("androidx.compose:compose-bom:2024.09.00")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
}
