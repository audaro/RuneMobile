# Working on the Android port

The Android app is a Kotlin/Jetpack Compose host whose native layer starts a second JVM, an embedded HotSpot
OpenJDK 21, inside the app's ART process, runs headless RuneLite on it, and draws the frames on a `SurfaceView`.
This page covers the module layout, the JRE and jar staging, building and deploying, how the JVM boots, touch
handling, rendering, foldables and tablets, performance work, and the device traps that cost the most time.

Read [Setup](setup.md) first for the SDK, NDK and JDK, and [Architecture](architecture.md) for the frame and
input paths both ports share.

## At a glance

| | Android |
|---|---|
| Host | Kotlin + Jetpack Compose, package `dev.audaro.runemobile`, in `android/app/` |
| Native | `librunemobile.so` (JVM bootstrap, CPU blit, bridge calls) and `librlawt.so` (EGL/GLES bridge for GPU and 117 HD) |
| JVM | Bionic arm64 OpenJDK 21, shipped in the APK's assets and unpacked on first launch |
| JIT | Free: no debugger, no per-launch step |
| Jars | `client-<ver>-gpu.jar`, `client-<ver>-rlhd.jar`, `probes.jar`, plus `runtime.tag` |
| ABI | `arm64-v8a` only; `minSdk` and `targetSdk` are in `android/app/build.gradle.kts` |
| Gate | `android/dev-tools/ci/release-gate.sh` |

Tested devices are listed in the README's
[Platform status](../../README.md#platform-status--supported-devices) section.

## Module layout

```
android/
  app/
    build.gradle.kts       versions, signing, the self-staging tasks, release guards
    src/main/
      java/dev/audaro/runemobile/   the Kotlin app
      cpp/                 CMakeLists.txt, jvm_bootstrap.cpp, librlawt.cpp
      assets/jvm/          the JRE tree, staged jars and runtime.tag (gitignored)
      AndroidManifest.xml
    src/debug/             manifest overlay (Firebase Game Loop entry) and a GPU smoke jar
    src/release/           manifest overlay (drops the Android TV launcher category)
  recon/                   a separate GPU-probe app; never build it by accident
  config/detekt/           detekt rules and baseline
  dev-tools/               device, GPU, CI and gate tooling
  keystore.properties.example
```

The Kotlin files that matter most:

| File | Role |
|---|---|
| `MainActivity.kt` | Everything on the game screen: renderer choice, JVM boot, the `SurfaceView`, every touch path, the HUD views, settings, foldable resizing, keepalive. By far the largest file. |
| `JvmLauncher.kt` | The JNI facade: `startJvm` plus one `external fun` per bridge call (`nativeClick`, `nativeCamera`, `nativeMenuSnapshot`, …). |
| `AssetInstaller.kt` | Unpacks the JRE and jars from assets into `filesDir/jvm/` and decides when to re-unpack. |
| `LoginActivity.kt`, `JagexLogin.kt`, `JagexTokens.kt` | On-device Jagex login, minting the game session, and turning `tokens.json` into `JX_*` environment variables. |
| `GameSettings.kt` | The Game settings screen and its `game_settings` SharedPreferences (long-press time, camera speed, haptics). |
| `ChromeOverlayView.kt`, `ChatPillView.kt`, `MenuOverlayView.kt`, `DialogueView.kt`, `TapRingView.kt` | Native HUD drawn over the game: tab grid, chat, the long-press menu, NPC dialogue, tap feedback. |
| `PluginPanel.kt`, `ConfigScreen.kt`, `PluginHubScreen.kt`, `PanelView.kt`, `PanelReflowScreens.kt`, `XpTrackerScreen.kt`, `QuestWorldScreens.kt`, `InfoBoxScreen.kt` | Plugin list, config, hub, rendered side panels and the native panel screens. |
| `OverlayEditView.kt` | Overlay edit mode (move RuneLite overlays, the chat and the minimap). |
| `KeepaliveService.kt` | Foreground service that keeps a logged-in session alive in the background. |
| `ThermalGovernor.kt` | Feeds thermal status to `ThermalScaleKeeper.kt`, which lowers 117 HD's scene resolution under thermal pressure and restores it when the phone cools. |
| `SafeInsets.kt` | Window insets trimmed to the system bars. |

`cpp/CMakeLists.txt` builds two libraries, both linked with 16 KB page alignment:

- **`librunemobile.so`** (`jvm_bootstrap.cpp`, log tag `jvm-boot`): loads `libjvm.so`, creates the VM, pipes the
  VM's stdout and stderr to logcat, runs the CPU render loop that blits frames into the `SurfaceView`, and holds
  the JNI side of every `JvmLauncher` call.
- **`librlawt.so`** (`librlawt.cpp`, log tag `librlawt`): the EGL context, the GL forwarders behind RuneLite's GPU
  plugin and 117 HD, and the direct EGL present. It is a port of the iOS bridge
  (see [Rendering](#rendering)).

Gradle builds both from source; nothing native is staged by hand.

## The embedded JRE

The JRE is a bionic arm64 OpenJDK 21 (it needs `/system/bin/linker64` and the unversioned `libc.so`; a glibc
or Mach-O build won't load). [`tools/stage-android-jre.sh`](../../tools/stage-android-jre.sh) downloads the
SHA-pinned archive, checks it, stages it into `app/src/main/assets/jvm/jre/`, and builds the missing
`libawt_xawt.so` from [`dev-tools/fake-xawt/`](../../android/dev-tools/fake-xawt/build-libawt_xawt.sh) (no-op
headful stubs that depend on `libawt_headless.so`). Set `JRE_URL_MIRROR` to fall back to your own copy of the
same archive. Provenance is in
[`JRE21-ANDROID-INVENTORY.md`](../../android/dev-tools/JRE21-ANDROID-INVENTORY.md).

**The whole JRE goes in assets, never in `jniLibs/`.** The native bootstrap `dlopen`s
`filesDir/jvm/jre/lib/server/libjvm.so` and the rest of `lib/*.so` by absolute path. If the same libraries also
sit in `jniLibs/arm64-v8a/`, the linker resolves `libawt.so` by soname from the APK's library directory,
`libawt`'s `JNI_OnLoad` gets a relative path, and the VM aborts with
`Could not allocate library name` while `java.awt.Toolkit` initialises. Keep `jniLibs/` empty:
Gradle packages the CMake-built libraries from its own build output, not from there. `stage-android-jre.sh` removes stray JRE libraries from it.

Two settings exist only for this VM:

- `android:allowNativeHeapPointerTagging="false"` in the manifest: HotSpot's VM thread trips bionic's
  tagged-pointer check.
- `-Djava.io.tmpdir=<filesDir>/tmp`: the default `/tmp` doesn't exist in the app sandbox, and font loading
  fails without a writable temp directory.

**JIT is free.** Android lets the app map its own executable memory, so none of the iOS JIT machinery exists here:
no debugger, no `MirrorMappedCodeCache`, no per-launch step.

## Staging

Android bundles `client-<version>-gpu.jar` (the shaded client with the GL facade), `client-<version>-rlhd.jar`
(117 HD), `probes.jar` and `runtime.tag`. It does not bundle the pristine shaded jar: every renderer, CPU
included, boots from the `-gpu` jar, and the `-rlhd` jar is on every classpath so the renderer panel can list
117 HD. [`PORTS.md`](../../PORTS.md) compares this with iOS.

The order matters, because the GPU and 117 HD jars are built from the shaded jar and `runtime.tag` hashes all of
them. From the repository root:

```sh
tools/stage-android-jre.sh                               # 1. the JRE, into assets/jvm/jre
./gradlew :client:shadowJar                              # 2. the shaded client jar
( cd ios/app && ./build-probes.sh )                      # 3. probes.jar (shared with iOS)
android/dev-tools/gpu/stage-android-gpu-jar.sh           # 4. client-<ver>-gpu.jar
android/dev-tools/gpu/stage-rlhd-zone-jar.sh             # 5. client-<ver>-rlhd.jar
tools/stage-mobile-runtime.sh --no-build --android-only  # 6. probes.jar + runtime.tag
cd android && ./gradlew :app:assembleDebug               # 7. the APK
```

[`android/README.md`](../../android/README.md) has the same list with its reasons. `tools/stage-mobile-runtime.sh`
does not build the GPU or 117 HD jars; it fails loudly if they're missing.

### The self-staging Gradle tasks, and their trap

`:app:preBuild` depends on `:app:stageBootAssets`, which runs steps 1–6 for you: `stageJre`, `shadowJarClient`,
`buildProbes`, `stageGpuJar`, `stageRlhdJar` and `stageMobileRuntime`. Each one runs only if its output is
missing (no `libjvm.so`, no `client-<version>-*.jar` of the current version, and so on); `stageMobileRuntime`
also runs when a staged jar is newer than `runtime.tag`.

So a clean tree stages itself, and an already-staged tree skips all of it. **After a change to shared Java, or an
upstream merge that keeps the same version number, Gradle will happily build an APK with the old jars.** Re-run
steps 2–6 by hand whenever the Java side changed (deleting only the staged jars rebuilds them from the stale
shaded jar).

### `runtime.tag` and the on-device copy

On the phone, `AssetInstaller` copies assets into `filesDir/jvm/` and keeps two markers: `.installed-base` for the
JRE (bumped by hand when the JRE changes, which is rare) and `.installed-tag` for the jars (the contents of
`runtime.tag`, the first 12 hex digits of a SHA-256 over every staged jar). A new APK whose `runtime.tag` matches
the installed one does not re-copy the jars. **If you restage the jars without step 6, the phone keeps running the
old jars** even though the APK holds new ones.

### Build guards

After the asset merge, `verifyNoReleaseSecret` and `verifyReleaseBootAssets` check a release build, and
`verifyStagedClientJar` checks both builds. They fail a build that would carry a secret, miss a boot asset, or
bundle a client jar that lost its generated `runelite/` resources.

## Building

```sh
cd android
./gradlew :app:assembleDebug     # app/build/outputs/apk/debug/app-debug.apk
./gradlew :app:assembleRelease   # app/build/outputs/apk/release/app-release.apk
```

Never run a bare `./gradlew assemble`: it also builds the `:recon` probe app.

| | Debug | Release |
|---|---|---|
| VM stdout/stderr | to logcat (`jvm-stdout`) | dropped, except the perf probe's lines when armed |
| Dev markers and test broadcasts | honoured | ignored |
| Headless frame capture | on | off |
| Firebase Game Loop entry | exported | absent |
| Signing | debug key | `keystore.properties` if present, else the debug key |

**R8 is off in both.** The engine and the bridge are found by name through JNI `FindClass`, and RuneLite uses
reflection throughout, so shrinking or renaming would break them. The APK's size is mostly the JRE and the jars,
which R8 couldn't shrink anyway.

**Signing.** Copy [`keystore.properties.example`](../../android/keystore.properties.example) to
`android/keystore.properties` (gitignored) and fill in `storeFile`, `storePassword`, `keyAlias` and
`keyPassword`. Keep the keystore outside the repository. A file that exists but lacks any of the four keys fails
the build rather than falling back. Once a signed APK has been shared, keep the same key: Android only updates an
app in place when the signature matches.

**Versions.** `verMajor`, `verMinor` and `verPatch` in `android/app/build.gradle.kts` are the app's semver for
both ports. `versionCode` is `major*10000 + minor*100 + patch`, and CI overrides it with
`-PversionCodeOverride` and `-PversionNameSuffix` for rolling builds.

**Native changes.** After editing anything in `app/src/main/cpp/`, force the native build, because
`assembleDebug` can report it up to date and package the old `.so`. Then check that the APK holds your change:

```sh
cd android
./gradlew :app:externalNativeBuildDebug --rerun-tasks
./gradlew :app:assembleDebug
unzip -p app/build/outputs/apk/debug/app-debug.apk lib/arm64-v8a/librunemobile.so | strings | grep <a symbol or string you added>
```

**Lint.** Kotlin style is ktlint (`tools/lint/ktlint.sh`, configured by `.editorconfig`), static analysis is
detekt (`tools/lint/detekt.sh`, rules and baseline in `android/config/detekt/`), and Android lint runs as
`:app:lintRelease`, failing on errors. `android/dev-tools/ci/release-gate.sh` runs them all; see
[Before you commit](#before-you-commit-an-android-change).

## Deploying

Android needs no JIT step: install and launch.

```sh
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
adb shell am force-stop dev.audaro.runemobile
adb shell am start -n dev.audaro.runemobile/.MainActivity
```

[`android/dev-tools/deploy-wireless.sh`](../../android/dev-tools/deploy-wireless.sh) builds and installs over
Wi-Fi. Pair once with `--pair <ip:port> <code>` from the phone's Wireless debugging screen; after that it finds the
phone by mDNS (`deploy-wireless.sh debug launch`). `--tailnet <port>` reaches a phone that is off your network
over your own Tailscale network, and `--bootstrap` uses a cable for the legacy `adb tcpip` mode.
[`DEVICE-INSTALL.md`](../../android/dev-tools/DEVICE-INSTALL.md) is the first-install walkthrough.

### Traps

- **`adb install -r` leaves the old process running.** Until you force-stop it, you are testing the previous
  build.
- **Launch exactly once.** `am start -n …/.MainActivity` followed by `monkey -p dev.audaro.runemobile …` stacks a
  second `MainActivity`; the first one's `surfaceDestroyed` then blanks the game area. Force-stop first, then use
  one launch command.
- **A phone with its screen off never draws.** Launched while the screen is off, the activity starts in the
  background, `jvm-boot` logs `render paused (backgrounded)`, and `jvm-stdout` repeats
  `[boot] poll …ms draws=0 nullGraphics=0 frames=0 state=null` indefinitely. That is not a hang. Wake the phone
  first:
  ```sh
  adb shell dumpsys power | grep mWakefulness   # must be Awake
  adb shell input keyevent KEYCODE_WAKEUP
  ```
  `svc power stayon true` keeps the screen on only while the phone is charging. While you work, you can stop doze
  from dropping wireless adb with `adb shell dumpsys deviceidle disable` and `adb shell svc power stayon true`.
  Turn both back (`deviceidle enable`, `stayon false`) when you're done.
- **A failed GPU boot leaves a cookie.** Before a GPU or 117 HD boot, the app writes `files/auto-gpu-armed`; a
  watchdog deletes it once three frames have been presented, or gives up after 240 s. If the cookie is still
  there at the next launch, the app falls back to CPU, records the failure in `files/gpu-fail.txt`, and (if the
  renderer was the automatic pick) sets `autoGpuFailed` so the probe won't promote again. A test that
  stalled for any reason, a dark screen included, therefore makes the next launch silently run CPU. Clear it on a
  debug build:
  ```sh
  adb shell run-as dev.audaro.runemobile rm -f files/auto-gpu-armed
  ```
  The renderer choice itself lives in `shared_prefs/renderer.xml` (`mode` = `cpu`, `gpu` or `117hd`, plus
  `autoDecided`, `autoGpuFailed` and `gpuFailCount`). Users switch renderers in the plugin panel; the change applies
  at the next start.
- **Logging in.** With no `tokens.json`, the app sends the player to `LoginActivity` before booting. For a dev
  shortcut on a debug build, push an existing `tokens.json` (`DEVICE-INSTALL.md` step 3). Use a throwaway Jagex
  account. `tokens.json` is a secret; never log or commit it.

### Debug-only marker files

A debug build reads marker files from the app's external files directory,
`/sdcard/Android/data/dev.audaro.runemobile/files/`. Release builds ignore them, so a stray file can't change a
user's renderer or skip the login.

| Marker | Effect |
|---|---|
| `gpu.mode` | Boot the GPU renderer. |
| `rlhd.mode` | Boot 117 HD. Delete it after the test: it outranks the saved preference. |
| `perfprobe` | Arm the perf probe (a debug build is armed without it); see [Performance](#performance). |
| `cpufps N`, `xms SIZE`, `jfr SECS` | A/B knobs, written by `tools/perfprobe.sh android marker NAME VALUE`. |

## Boot sequence

1. **`MainActivity.onCreate`** resolves the renderer: it checks the `auto-gpu-armed` cookie, and on the very first
   run probes the GPU (`probeGpuCaps`: `117hd`, `gpu` or `cpu`). This runs only when the JVM is not already up,
   because `onCreate` re-runs on recreations the manifest doesn't absorb, and reading the cookie then would
   demote a healthy session.
2. **Login gate.** No `tokens.json` sends the player to `LoginActivity`. Login writes the file and restarts the
   process, because the JVM reads `JX_*` from the environment only when it is created.
3. **`jvm-boot` thread** runs `bootJvm`: `AssetInstaller` unpacks on the first launch or a tag change (with an
   "Unpacking… N%" line on the splash), and the jars are found by glob: `client-*-gpu.jar`, `client-*-rlhd.jar`,
   then `probes.jar`. The version is never written in code, so a version bump needs no edit. A missing jar shows a
   "Game files missing" card instead of crashing.
4. **Environment and prefs.** `JagexTokens.loadAndArm` sets the `JX_*` variables (or `LegacyCreds` arms a
   username/password login), and `ensureResizableDisplayMode` seeds the game's `preferences.dat`.
5. **`JvmLauncher.startJvm`** passes the classpath, `JAVA_HOME` (`filesDir/jvm/jre`), the library path and the
   options to native code, which starts a worker pthread and blocks until the VM exists.
6. **Native bring-up** (`jvm_bootstrap.cpp`): `dlopen` of `libjvm.so` and the JRE's other libraries,
   `JNI_CreateJavaVM`, then `UnsafePokeActivation.activate` to switch AWT to Caciocavallo before any AWT class
   loads. For GPU and 117 HD it `dlopen`s `librlawt.so`, registers the GL natives, and arms the direct EGL present.
7. **`DeviceHeadlessBoot.main`** runs on the worker. The engine starts its own threads, and the native render
   thread starts blitting frames for the CPU renderer.
8. **Watchdog and splash.** For a GPU or 117 HD boot, `auto-gpu-watchdog` waits for presented frames. The splash
   has a 60 s deadline (`SPLASH_TIMEOUT_MS`), the same as the iOS boot overlay.

### JVM options

`bootJvm` uses iOS's option set without the iOS JIT flags (`MirrorMappedCodeCache`,
`DisablePrimordialThreadGuardPages`, `-UseCompressedClassPointers`, `ReservedCodeCacheSize`). The differences
worth knowing:

| | Android | iOS |
|---|---|---|
| Heap | `-Xmx512m` (`MAX_HEAP_MB`) | `-Xmx1024m` |
| Boot window | `-Dheadless.runSeconds=86400`: `main` effectively never returns | `240`: `main` returns and the JVM thread parks ([why](ios.md#why-the-jvm-thread-parks-forever)) |
| Menu entries | `-Drunelite.menupeek.maxEntries=14` | `32` |
| Chrome | `-Drunelite.bridge.scrollrects=true` | per-touch hit tests |
| Temp dir | `-Djava.io.tmpdir=<filesDir>/tmp` | default |
| Frame capture | debug builds | Debug builds |

Renderer flags (`-Drunelite.routecgpu`, `-Drunelite.routecrlhd`), the forced plugin enable/disable lists, the
canvas size (`-Drunelite.headless.resize`) and the perf-probe options work as on iOS. The
[bridge API reference](bridge-api-reference.md) lists every `-D` property.

## Touch input

Android follows the iOS rules for what counts as a tap, a hold or a drag, so the two ports feel the same. When you
change one, change the other ([iOS touch mapping](ios.md#the-game-view-and-touch-mapping)).

- **One slop for everything.** `GestureDetector` treats a touch as a scroll once it moves past
  `ViewConfiguration`'s `scaledTouchSlop` (about 8 dp), which cancels both the tap and the long-press. A finger's
  natural roll crosses that, so taps went missing and holds never opened the menu. `MainActivity` tracks the raw
  touch itself with `sceneDragSlopPx` = 18 dp, the furthest the finger strayed from where it landed, not where it
  ended up.
- **Moves are withheld from the detector** until the finger leaves that radius (or a second finger lands). Down,
  up, cancel and pointer events always go through, and the pinch detector always sees the whole stream.
- **The first `onScroll` only classifies.** It carries all the withheld movement as one jump, so it decides what
  the drag is (camera, map, chat, list, item) and is otherwise dropped. Applying it would snap the camera 18 dp at
  the start of every drag.
- **The long-press is timed by `holdRunnable`**, not the detector, so it can use the player's setting
  (`GameSettings.longPressMs`, 200–1000 ms, default 400). When it fires it sends the detector a synthetic
  `ACTION_CANCEL`, so the lift can't also click, and opens the engine's menu at the landing point.
- **Taps are armed on touch-down** (`JvmLauncher.armTap`) for plain world taps, so the engine resolves the hover
  while the finger is down, and every move sample is handed to the bridge (`tapMove`). Routed taps (orbs, minimap,
  map window, dialogue) click precisely instead.
- **Drags** route by where they started: the world map's panels or the map itself, the chat, an inventory or
  reorder pane (only after `GameSettings.dragHoldMs`, at most 150 ms; a quicker swipe scrolls), a scrollable engine
  list, otherwise the camera, scaled by `GameSettings.cameraGain`.
- **Native views over the game take the touches in their bounds.** The dialogue parchment, chat pill, tab grid
  and menus are ordinary Android views on top of the `SurfaceView`; a tap there never reaches the game. Each one
  has to forward its taps to the engine itself (the dialogue goes through the engine's continue handler, for
  example), and an overlay that should not catch touches must not be clickable.
- **The world map stretches the `SurfaceView`.** While the map is open, `applyMapFullscreen` scales the surface
  (pivot at the top-left, plus a translation) so the map window fills the screen. Overlay views are not scaled.
  Convert a surface point with `surfaceToOverlay` before hit-testing or placing anything in overlay space, or a
  menu held open on the map draws away from the finger.
- **Keyboard.** `GameInputView` offers the number pad when the game's prompt wants a number
  (`textInputKind() == 2`) and text otherwise, and a Paste pill sits above the keyboard.

## Rendering

The CPU renderer's frames come from `JavaBridge`'s pixel buffer. The native render thread copies each one into
the `SurfaceView`'s `ANativeWindow`, swapping the channel order on the way. When the activity is backgrounded the
loop pauses.

GPU and 117 HD run RuneLite's GPU plugin and 117 HD against `librlawt`'s EGL context on the same surface, through
the GL facade in the `-gpu` jar, and present straight from EGL. [Renderers](renderers.md) covers the facade,
probing, fallback, the GLES shader ports and the pinned 117 HD sources.

**Port GL fixes from iOS.** `librlawt.cpp` is a port of the iOS bridge, `ios/dev-tools/gpu-routec/jni/routec_gl_jni.m`
and `ios/dev-tools/gpu-zone/jni/routec_zone_jni.m`, and it has missed iOS fixes before. A base-GPU "translucent
wedge" and one-frame wall dropouts on Android turned out to be a bug iOS had already fixed: NIO buffers sized by
`capacity()` instead of `remaining()` from `position()`. Another time an unbound `glReadPixels` overload froze the
game when a plugin took a screenshot. For an Android-only GPU artefact, compare the Android entry point with the
iOS one and search `git log -- ios/dev-tools/gpu-routec ios/dev-tools/gpu-zone` before forming a theory. These
artefacts often last one frame, so record with `adb shell screenrecord` and step through frames instead of
trusting single screenshots.

**ThermalGovernor.** While 117 HD is the live renderer, a thermal-status listener steps its
`sceneResolutionScale` down at moderate thermal status and above, and restores the saved value when the phone
cools. A marker file records the real value while throttled, so a session killed mid-throttle can't make the
lowered value the next baseline, and the marker goes only once that value is on disk (see
[Heat](renderers.md#heat)). The governor arms before the JVM is up and is otherwise woken only by a status change,
so it runs again every 2 s while it has more to do, and for as long as a limit is in force.
`android/dev-tools/diagnostics/heat-check.sh` checks all of this on an emulator.

## Settings and live config

`GameSettings` keeps the long-press time, camera sensitivity (0.1–4.0, default 2.0), drag hold and four haptic
triggers with a strength in the `game_settings` SharedPreferences. `MainActivity` reads them live, so changes apply
without a restart. The keys and ranges match iOS's `RMGameSettings`.

Debug builds also accept test broadcasts:

```sh
adb shell am broadcast -a dev.audaro.runemobile.SET_HD_CONFIG --es key drawDistance --es value 20
adb shell am broadcast -a dev.audaro.runemobile.SET_HD_CONFIG --es preset base       # or: new
adb shell am broadcast -a dev.audaro.runemobile.SET_RECONNECT_OVERLAY --es show on   # on | off | clear
adb shell am broadcast -a dev.audaro.runemobile.SET_SESSION_EXPIRED_OVERLAY --es show off
```

`SET_HD_CONFIG` applies a 117 HD setting live; logcat confirms with `SET_HD_CONFIG applied live: [...]`. It writes
the player's real RuneLite profile (`files/.runelite/profiles2/`), but only when RuneLite's ConfigManager next
saves: the first save comes 30 s plus a random 0–5 minutes after launch, then every 5 minutes. A force-stop
before that throws the change away, and a test value that did get saved stays in the profile. After a live test,
set the original value back, wait for the profile file's modification time to change, and check the keys on disk
before you force-stop or redeploy. Send one broadcast per key, written out literally.

The day/night cycle is forced off at every launch on both ports, so a live flip of it lasts only until the next
start.

## Foldables and tablets

The canvas rules (all in `MainActivity`):

- **Never narrower than 765 px** (`MIN_CANVAS_W`), the game's narrowest layout.
- **Phones** (short side under 600 dp, `LARGE_SCREEN_DP`) keep a 540 px tall canvas (`PHONE_CANVAS_SHORT`). A phone
  whose canvas matches its screen must stay exactly as it was; changes here are checked against that.
- **Large screens** (tablets, unfolded book foldables) keep the phone's canvas pixels per dp (540 px over 411 dp,
  `PHONE_SHORT_DP`), so the HUD stays phone-sized.
- **Letterbox, don't stretch.** When the window's shape is more than 10% off the canvas's
  (`STAGE_ASPECT_SLACK`), the game stage letterboxes until the canvas has been resized.
- **Live resize.** A window size change, debounced 300 ms, calls `JavaBridge.requestResize`, which re-runs the
  frame resize on the client thread. iOS doesn't do this yet.
- **Zoom per screen class.** The camera zoom is saved separately for the phone and large-screen classes
  (`swapZoom`, SharedPreferences `zoom`) and swapped when the class changes and at each login. There is
  deliberately no automatic zoom-out on a larger screen: it would change a setting the player never touched.

**Tablets need no code of their own;** the large-screen rule covers them. A larger canvas costs the CPU renderer
frame rate.

Emulate them on a phone:

```sh
adb shell wm size 1968x2184     # an unfolded book foldable (any large size works); change it mid-session to test the live resize
adb shell wm size 1600x2560 && adb shell wm density 320 && adb shell wm user-rotation lock 1   # a 10" tablet
```

Restore with `wm size reset`, `wm density reset` and `wm user-rotation free`, then delete
`shared_prefs/zoom.xml` (`adb shell run-as dev.audaro.runemobile rm shared_prefs/zoom.xml`), which the class
change wrote. On recent Android versions a display at least 600 dp wide ignores the app's landscape request and
letterboxes it inside a portrait display unless you lock the rotation as above. A very short emulated size can
push the tab grid to its minimum and look broken; that is the emulation.

## Backgrounding

When the activity stops while the player is logged in and the "keep session alive" setting is on (the default),
`KeepaliveService` runs as a foreground service with an ongoing notification. Rendering pauses but the client
keeps ticking and the game socket stays up. After 10 minutes in the background
(`KEEPALIVE_IDLE_STOP_MS`, the same as iOS's idle release) the service stops itself. If Android refuses to start a
foreground service, the app carries on without it, and the reconnect overlay handles the dropped session when the
player returns.

**Top-level interface 165 is not a bug.** While the app is backgrounded, just foregrounded or idle, the game's
top-level interface can read 165 with the inventory parked off-canvas. The first interaction (opening a tab)
lays it out again as 164, the layout the native HUD is built for. Before treating a 165 reading as a broken
bridge, open a tab in the foreground and read it again.

## Performance

Arm the perf probe without rebuilding (a debug build is always armed), then measure:

```sh
tools/perfprobe.sh android on            # takes effect at the next launch: force-stop and start again
android/dev-tools/gpu/fps-measure.sh -d 60 baseline     # capture 60 s over adb and summarise
tools/perfprobe.sh android marker jfr 60 # a 60 s Java Flight Recording, starting a minute after launch
```

`fps-measure.sh` reads the `[fpsprobe]`, `[frameprobe]`, `[framebins]`, `[framehist]` and `[presentprobe]` lines
and prints fps and frame-time percentiles plus the thermal state. Compare percentiles, not one smoothed fps: that
is how a 2–3 fps change is told apart from noise.

**Heat moves the CPU renderer more than code does.** The engine's client thread uses nearly a whole core in CPU
mode, so fps follows whichever core the scheduler gives it and how far that core is throttled. The same build on
the same phone measured 37 fps cool and 12 fps hot and charging. Before you call a CPU-mode slowdown a
regression, compare runs of the same build across the day and read the thermal state:

```sh
adb shell dumpsys thermalservice
adb shell cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_max_freq   # a big core's current cap; core numbering varies by SoC
```

## Testing reconnects

Airplane mode would also cut wireless adb. Cut only the app's network instead:

```sh
adb shell cmd connectivity set-chain3-enabled true
adb shell cmd connectivity set-package-networking-enabled false dev.audaro.runemobile
# ... the game notices after about 14 s (LOGGED_IN -> CONNECTION_LOST) ...
adb shell cmd connectivity set-package-networking-enabled true dev.audaro.runemobile
adb shell cmd connectivity set-chain3-enabled false
```

Put the undo in a `trap … EXIT` in any script, so a failed run doesn't leave the app offline. logcat rolls over in
a few minutes; the complete record is RuneLite's own log:

```sh
adb shell run-as dev.audaro.runemobile cat files/.runelite/logs/client.log
```

## Logs

| Source | How to read it | What |
|---|---|---|
| logcat `jvm-boot` | `adb logcat -s jvm-boot` | Native bring-up, `JNI_CreateJavaVM`, render paused and resumed. |
| logcat `jvm-stdout` | `adb logcat -s jvm-stdout` | The JVM's stdout and stderr, including `DeviceHeadlessBoot`'s `[boot] poll` lines (debug builds; release keeps only the perf probe's lines). |
| logcat `librlawt` | `adb logcat -s librlawt` | EGL and GL bridge, `[presentprobe]`. |
| logcat `MainActivity` | `adb logcat -s MainActivity` | The host: renderer choice, auto-GPU, touch routing, thermal governor. |
| logcat `AssetInstaller`, `JagexLogin`, `JagexTokens`, `KeepaliveService` | as above | Unpacking, login (redacted), keepalive. |
| `files/.runelite/logs/client.log` | `run-as` as above | RuneLite's log; survives logcat rollover. |
| `files/gpu-fail.txt` | `run-as` | The last GPU or 117 HD boot that never presented a frame. |

`run-as` works only on a debug build. [Debugging](debugging.md) has the symptom table, and
[`tools/log-scan/`](../../tools/log-scan/README.md) separates new warnings from known noise in a logcat dump.

## Dev tools

Each directory under `android/dev-tools/` has its own README. In one line each:

| Directory | What |
|---|---|
| [`a0-login`](../../android/dev-tools/a0-login/README.md) | Gate: from a pushed `tokens.json`, the engine reaches `LOGGED_IN` with no taps. |
| [`a1-input`](../../android/dev-tools/a1-input/README.md) | Gate for the input scheme (taps, camera, keys) over the bridge. |
| [`a1b-gatecensus`](../../android/dev-tools/a1b-gatecensus/README.md) | Runtime census: each bridge gate flips on a real boot. |
| [`a2-menupeek`](../../android/dev-tools/a2-menupeek/README.md) | The press-and-peek native right-click menu. |
| [`a3-login`](../../android/dev-tools/a3-login/README.md) | On-device Jagex login. |
| [`a4-pluginplane`](../../android/dev-tools/a4-pluginplane/README.md) | Plugin list, toggles and config through `MobileUiBridge`. |
| [`a5-panels`](../../android/dev-tools/a5-panels/README.md), [`a5-tier2`](../../android/dev-tools/a5-tier2/README.md) | Rendered plugin side panels, and the native Quest Helper and World Switcher screens. |
| [`a6-chrome`](../../android/dev-tools/a6-chrome/README.md) | The native tab grid and chat chrome. |
| [`bridge-census`](../../android/dev-tools/bridge-census/README.md) | `run-census-desktop.sh`: every bridge member Android calls resolves in the jar, on desktop JDK 21. |
| [`browserstack`](../../android/dev-tools/browserstack/README.md), [`firebase`](../../android/dev-tools/firebase/README.md) | Real-device gates on hosted device farms (Firebase Test Lab has a free tier). |
| [`gpu`](../../android/dev-tools/gpu/README.md) | GPU and 117 HD: jar stagers, the GL facade sources, shader and Java overlays, `fps-measure.sh`. |
| `ci/release-gate.sh` | The Android gate (below). |
| `deploy-wireless.sh`, [`DEVICE-INSTALL.md`](../../android/dev-tools/DEVICE-INSTALL.md) | Installing on a phone. |
| `fake-xawt/`, [`JRE21-ANDROID-INVENTORY.md`](../../android/dev-tools/JRE21-ANDROID-INVENTORY.md) | The JRE's missing `libawt_xawt.so`, and the JRE's provenance. |

The `a*` gates were written while the port came up on the emulator. Their READMEs describe what each checks; the
mechanics of a few have since changed (the login, for one, now goes through Chrome and the clipboard rather than
a WebView), so read the code next to them.

## Before you commit an Android change

1. Build and run it on a phone (force-stop, one launch), and check the change on the device.
2. After a native change, confirm the `.so` in the APK holds it.
3. After a shared-Java change, restage (steps 2–6 above), then run
   `android/dev-tools/bridge-census/run-census-desktop.sh` (expect `ANDROID_BRIDGE_CENSUS_GREEN`) and the iOS census
   too: the bridge is shared.
4. Run `./android/dev-tools/ci/release-gate.sh --skip-build` (contract, shellcheck, ktlint, detekt, bridge unit
   tests, lint). Run it in full before a release; CI runs only `--contract-only`.

[Testing and QA](testing-qa.md) has the full ladder.

## See also

- [`android/README.md`](../../android/README.md): layout, the JRE rules, the staging order.
- [`android/dev-tools/DEVICE-INSTALL.md`](../../android/dev-tools/DEVICE-INSTALL.md): first install and login.
- [`PORTS.md`](../../PORTS.md): what the two ports share and bundle.
- [iOS port](ios.md), [Architecture](architecture.md), [The bridge API](bridge-api.md), [Renderers](renderers.md),
  [Testing and QA](testing-qa.md), [Debugging](debugging.md), [Gotchas](gotchas.md).
