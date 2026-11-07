# Working on the iOS port

The iOS app is an Objective-C/UIKit host that boots a real HotSpot JVM inside its own process, runs headless
RuneLite on it, and draws the engine's frames on a UIKit view. This page covers the Xcode project, how the JVM
starts, how JIT works on a phone, how to build, install and run in the iOS Simulator, the native UI and touch
mapping, and what keeps a session alive in the background.

Read [Setup](setup.md) first for the tools to install and a fresh-checkout walkthrough, and
[Architecture](architecture.md) for the frame and input paths both ports share.

## At a glance

| | iOS |
|---|---|
| Host | Objective-C/UIKit, `ios/app/RuneMobile/` (no Swift) |
| Project | `ios/app/project.yml`, turned into `RuneMobile.xcodeproj` by xcodegen |
| JVM | Patched arm64 OpenJDK 21, bundled as `jre/`, created with `JNI_CreateJavaVM` |
| JIT | Needs a debugger attach on every launch (StikDebug + `runelite-jit.js`); not needed in the Simulator |
| Jars | `client-shaded.jar`, `client-rlhd.jar`, `probes.jar`, `routec-l1.jar` (version-agnostic names) |
| Renderers | CPU (UIImageView blit), GPU and 117 HD (EAGL GLES 3 bridge); see [Renderers](renderers.md) |
| Fast loop | Desktop JDK 21 for Java, then `ios/dev-tools/run-sim.sh`, then the phone |

Supported iOS versions and tested devices are listed in the README's
[Platform status](../../README.md#platform-status--supported-devices) section.

## Project layout

```
ios/
  app/
    project.yml            the source of truth for the Xcode project
    RuneMobile/            the Objective-C app
    jvm-resources/         staged jars (gitignored)
    scripts/               build phases: check-staged-jar.sh, resign-jre.sh
    stikdebug/             runelite-jit.js, the per-launch JIT script
    build-probes.sh        builds probes.jar
  dev-tools/
    jre/                   the embedded JRE (gitignored, placed per machine)
    gpu-routec/            GPU bridge: JNI GL forwarders + jar stager (compiled into the app)
    gpu-zone/              117 HD bridge additions + jar stager (compiled into the app)
    run-sim.sh, sim-gate.sh, sim-screens/, bridge-census/   Simulator tooling
    remote-build.sh, deploy-remote.sh, serve-ipa.sh         build and install
```

The files in `ios/app/RuneMobile/`:

| File | Role |
|---|---|
| `main.m` | Installs an uncaught-exception handler that writes `crash.log`, then runs `UIApplicationMain`. |
| `AppDelegate.m` | Registers defaults (for example the default pinned control) and makes `ViewController` the root. |
| `ViewController.m` | The game screen: Tap to Play cover, JIT polling, boot, frame display, every touch path, the HUD veneers, settings, keepalive and PiP. By far the largest file. |
| `JVMLauncher.m` | Loads `libjvm`, builds the JVM options, creates the VM, runs `DeviceHeadlessBoot`, and wraps every `JavaBridge` call the UI makes. |
| `PluginPanelsViewController.m` | The plugin rail and side panels: a plugin's Swing panel rendered headless into an image, with taps mapped back as Swing clicks. |
| `PluginConfigViewController.m` | Native config screen for one plugin, built from `MobileUiBridge.getPluginConfig`. Also hosts the curated 117 HD Graphics screen. |
| `PluginHubViewController.m` | Plugin Hub browse, install and remove. |
| `OverlayEditView.m` | Overlay edit mode: drag handles for every movable RuneLite overlay, plus the chat box and minimap cluster. |
| `JagexLoginViewController.m` | On-device Jagex login in a `WKWebView`; the result is written to `tokens.json`. |
| `RMGameSettings.m` | The Game settings screen and its `NSUserDefaults` keys (long-press time, camera speed, haptics). |
| `RMMemoryTrail.m` | Writes a line a minute of what the process's memory is made of, for Share logs. |
| `RMResidency.m` | Records why the last session ended (clean exit, idle release, suspected jetsam). |
| `GLRecon.m` | GPU capability probe; `recommendedRendererTier` picks the first-run renderer. |
| `RMKeyboardDismiss.m` | A Done bar for text fields and search bars, so an empty field can still close the keyboard. |
| `AboutViewController.m` | The About screen: unofficial-client and ban-risk disclosure, attributions. |

Three more sources are compiled into the app straight from `ios/dev-tools/`: `gpu-routec/app/RouteCBridge.m`,
`gpu-routec/jni/routec_gl_jni.m` (the GL forwarders behind RuneLite's GPU plugin) and
`gpu-zone/jni/routec_zone_jni.m` (the extra natives 117 HD needs). A change there is an app change.

[`ios/app/README.md`](../../ios/app/README.md) is a short map of that directory.

## The Xcode project

`project.yml` is the source of truth. Regenerate the project after changing it, and never edit
`RuneMobile.xcodeproj` by hand:

```sh
cd ios/app && xcodegen generate
```

### Configurations

| | Debug | Release |
|---|---|---|
| Plist | `Info-Debug.plist` (file sharing on) | `Info.plist` (no file sharing) |
| `DEBUG` macro | defined | not defined |
| On-device logs | `hello-shell.log`, `jvm-stdio.log`, `rl-capture/` in Documents | none (only `perf-probe.log` when the perf probe is armed) |
| RuneLite home (`.runelite`) | Documents | Library/Application Support |
| On-screen console | available | compiled out |

The deploy scripts default to Debug and take `CONFIG=Release`. The two plists must stay identical apart from the
file-sharing keys: Xcode's `INFOPLIST_KEY_*` settings don't merge into a hand-written `INFOPLIST_FILE`, so each
configuration swaps the whole file.

### Build phases

- **Check staged iOS shaded jar** (`scripts/check-staged-jar.sh`, pre-build) fails the build unless
  `jvm-resources/client-shaded.jar` is the GL-facade variant: exactly one `org/lwjgl/opengl/GLALL.class`, no
  `librlawt`, and a `runelite/index` with at least one assembled script. Both a pristine-jar copy and a jar
  missing its script index once shipped silently; this phase is why they can't again.
- **Re-sign embedded JRE** (`scripts/resign-jre.sh`, post-build) signs every Mach-O in the bundled `jre/` with
  the build's identity. For a Simulator build it first retags each one as an `iossim` binary with `vtool`, then
  signs ad hoc.

### Info.plist keys that matter

| Key | Why |
|---|---|
| `UIBackgroundModes: audio` | The background keepalive (see [Backgrounding](#backgrounding-and-residency)). |
| `NSMicrophoneUsageDescription` | Java Sound enumerates audio devices at startup. Without the string, iOS kills the app a few seconds after launch. |
| `NSAppTransportSecurity` → `NSAllowsLocalNetworking` | RuneLite's account login uses a loopback OAuth redirect. |
| `NSPhotoLibraryAddUsageDescription`, `NSPhotoLibraryUsageDescription` | Screenshots are saved to the photo library. |
| `CADisableMinimumFrameDurationOnPhone` | Lets the display link run above 60 Hz on ProMotion screens. |
| `UIRequiresFullScreen`, landscape-only orientations | The app is always full-screen landscape, on iPhone and iPad. |
| `UIApplicationSupportsMultipleScenes: false` | One window, no scene manifest. |

### Entitlements and signing

`RuneMobile.entitlements` holds a single entitlement, `com.apple.developer.kernel.increased-memory-limit`, which
raises the jetsam ceiling enough for a 1 GB Java heap. `get-task-allow`, which the JIT attach depends on, is not
in the file: it comes from the development provisioning profile at signing time. A distribution or TestFlight
signature drops it, and JIT stops working.

Signing is automatic. The team comes from `DEVELOPMENT_TEAM`, which the scripts read from
`ios/dev-tools/signing.env` (gitignored). Copy [`signing.env.example`](../../ios/dev-tools/signing.env.example)
and fill in your own team. A free Apple ID can sign a development build, with a 7-day profile; a paid account gets
1-year profiles. Neither changes JIT.

The released IPA is built by `tools/ci/build-release-artifacts.sh`, unsigned and then ad-hoc sealed, so it carries
no provisioning profile. SideStore or AltStore re-signs the whole bundle with the user's own development certificate
at install, which is what puts `get-task-allow` back. See [Upstream merges and releases](upstream-release.md).

`MARKETING_VERSION` in `project.yml` is the version a plain build shows (the Simulator, `/deploy`, an Xcode run).
It has to equal the Android build's semver (`verMajor`/`verMinor`/`verPatch` in `android/app/build.gradle.kts`),
which the release gate checks. CI passes that semver to `xcodebuild` itself, and `serve-ipa.sh` passes it with a
build counter appended.

### GL backend toggle

The GPU bridge can sit on Apple's EAGL (OpenGL ES 3, active) or on MetalANGLE (inactive). Both export the same
`gl*` symbols, so the `RC_BACKEND_ANGLE` macro, the linked frameworks and the ANGLE search paths in `project.yml`
must all agree. The comments there list every line to flip. Leave EAGL on unless you are working on the backend
itself.

## The embedded JRE

The app bundles a patched arm64 Mach-O OpenJDK 21 at `ios/dev-tools/jre/`, copied into the app as `jre/`. It is
not in git and cannot be rebuilt from a URL alone:

- The base is a third-party iOS build of jre21, pinned by SHA-256 in
  [`JRE21-INVENTORY.md`](../../ios/dev-tools/JRE21-INVENTORY.md), which also explains how to re-fetch it.
- [`patch-jre-txm.sh`](../../ios/dev-tools/patch-jre-txm.sh) patches `libjvm.dylib` so HotSpot always asks the
  debugger for executable memory (the `brk #0x69` request below), including on devices where its own detection
  would skip it or crash. The script checks the original bytes first and is safe to re-run.
- [`fake-xawt/build-libawt_xawt.sh`](../../ios/dev-tools/fake-xawt/README.md) adds a `libawt_xawt.dylib` that
  re-exports `libawt_headless`, because `Toolkit.loadLibraries` insists on loading it before Caciocavallo takes
  over.

Developers move the finished `jre/` between machines themselves; CI fetches it from a release asset. Android's
JRE is a bionic Linux build and will not load here.

## Staging the jars

The app bundles four jars from `ios/app/jvm-resources/`, all gitignored:

| Jar | Built by | What it is |
|---|---|---|
| `client-shaded.jar` | `ios/dev-tools/gpu-routec/stage-ios-gpu-jar.sh` | The shaded client with LWJGL and rlawt replaced by the GL facade. Every renderer boots from it. |
| `client-rlhd.jar` | `ios/dev-tools/gpu-zone/stage-ios-zone-jar.sh` | 117 HD's classes, shaders and resources, with iOS overrides applied. Always on the classpath. |
| `probes.jar` | `ios/app/build-probes.sh` | `DeviceHeadlessBoot`, Caciocavallo, and the activation shim. |
| `routec-l1.jar` | `ios/dev-tools/gpu-routec/l1/build-l1-probe.sh` | A small GL kill-test. `project.yml` needs the file, but the app has no control that boots it. |

Build them in the order [`ios/README.md`](../../ios/README.md) gives (the shaded jar first, since the others
build from it). [`PORTS.md`](../../PORTS.md) explains why the two ports bundle different jars.

Two traps:

- **Don't stage iOS with `tools/stage-mobile-runtime.sh`.** Without `--android-only` it copies the pristine
  shaded jar over `client-shaded.jar`, and `check-staged-jar.sh` then fails the build until
  `stage-ios-gpu-jar.sh` runs again.
- **Never write a versioned jar name.** The stagers read the RuneLite version from `gradle.properties`
  (`project.build.version`) to find `client-<version>-shaded.jar`, and write version-agnostic names into the
  bundle. Code, `project.yml` and scripts refer only to the agnostic names, so an upstream version bump needs no
  edit. A hard-coded versioned name breaks at the next merge.

After any change to shared Java, restage before you build; Xcode copies whatever is in `jvm-resources/`.

## Boot sequence

What happens between the app icon and the first frame, in order:

1. **Cover.** `ViewController` shows the Tap to Play cover. Its status line reads "Attach StikDebug to play…"
   until the JIT check below passes, then "Ready to play". A triple tap reveals the old debug panel.
2. **JIT check.** A 0.2 s timer calls `+[JVMLauncher isDebuggerAttached]`, which reads the process's
   `CS_DEBUGGED` flag with `csops`. In the Simulator it always returns YES.
3. **Renderer choice.** Tap to Play reads `rendererPref` (`cpu`, `gpu` or `117hd`) from `NSUserDefaults`. On a
   first run with no preference, `GLRecon` probes the GPU and picks `gpu`, or `cpu` if the probe fails. A crash cookie written before a GPU or
   117 HD boot reverts the next launch to CPU if the boot never finished, and sets `autoGpuFailed` so the probe
   doesn't promote again.
4. **Login check.** If the in-app login ran in this process, the app asks for a restart instead of booting (see
   [JIT traps](#traps)).
5. **Canvas size.** `onLaunch` works out the canvas (see [iPad](#ipad-and-foldables)), starts a 60 s boot-status
   deadline, opens a background task, and starts the display link, keepalive and PiP.
6. **JVM thread.** It starts an `NSThread` named `jvm-main`, with a 16 MB stack, which runs
   `-[JVMLauncher runProbesWithLog:]`.
7. **Load and prepare.** The thread `dlopen`s `jre/lib/server/libjvm.dylib` (`RTLD_NOW | RTLD_GLOBAL`) and builds
   the option list. Before the VM exists, `loadJagexTokens` maps `tokens.json` (in Library/Application Support)
   to `JX_*` environment variables, because HotSpot snapshots the environment at creation. It logs only whether
   each value is present. `RMEnsureResizableDisplayMode` seeds the game's `preferences.dat` with resizable mode,
   and the stale JNA unpack cache is deleted.
8. **Signals and exception ports.** The crash signals are reset to their defaults (wiping any handler another
   framework installed), the breakpoint exception port is handed back to the debugger if something else took it,
   and the Mach exception ports for bad access are cleared, so HotSpot's own `SIGSEGV` handler sees its implicit
   null checks.
9. **Create the VM.** `JNI_CreateJavaVM` runs with `ignoreUnrecognized = false`, so an unknown option fails the
   boot instead of being skipped. The app does not use `JLI_Launch`: libjli's Apple entry point re-runs `main`, which UIKit rejects.
10. **Natives.** The VM pointer is published atomically, `[coldstart] jvmCreated` is logged, and the GL natives
    (and the 117 HD ones, except in the kill-test) are registered with `RegisterNatives`.
11. **Main.** `DeviceHeadlessBoot.main` runs on the JVM thread. The engine starts its own threads.
12. **Bridge.** The UI thread attaches to the VM as a daemon the first time it needs the bridge, and caches the
    `JavaBridge` class and method IDs. `+[JVMLauncher bridgeReady]` is true from then on, and touch starts
    flowing.

Bridge calls from the UI thread only post work for the engine's client thread; they never read or change engine
state directly. The threading rules are in
[`headless/package-info.java`](../../runelite-client/src/main/java/net/runelite/client/headless/package-info.java).

### JVM options

The full list is in `runProbesWithLog:` in `JVMLauncher.m`. The groups:

| Group | Options | Notes |
|---|---|---|
| JIT and code cache (iOS only) | `-XX:+UnlockExperimentalVMOptions -XX:+MirrorMappedCodeCache -XX:+DisablePrimordialThreadGuardPages -XX:-UseCompressedClassPointers -XX:ReservedCodeCacheSize=64m` | Android drops all of these. |
| AWT | `-Djava.awt.headless=false`, the `--add-exports` / `--add-opens` set Caciocavallo needs | |
| Heap | `-Xmx1024m` (`kMaxHeapMb`), `-XX:+ExitOnOutOfMemoryError` | 256 MB ran 117 HD out of memory. |
| Bridge switches | `-Drunelite.bridge`, `mobileui`, `mobilechrome`, `menupeek`, `huddata`, `hudveneer` | Each turns on one bridge facade. |
| Plugins | `-Drunelite.nosafemode`, `-Drunelite.rendererpanel`, `-Drunelite.pluginhub.version=…`, `-Drunelite.forceEnablePlugins` / `forceDisablePlugins` | The renderer the user didn't pick is force-disabled. The hub version is pinned; `tools/shared-contract/check-hub-pin.sh` checks the pin. |
| Renderer | `-Drunelite.routecgpu=true` (GPU), plus `-Drunelite.routecrlhd=true -Drunelite.gfxIos=true` (117 HD) | |
| Canvas | `-Drunelite.headless.resize=WxH` | |
| Boot window | `-Dheadless.runSeconds=240`, `-Dheadless.captureTargetFrames=999` | See below. |
| Login | `autologin` + `autologin.manual`, when `tokens.json` exists | The player presses Play Now, unless Game settings > Auto-login adds `autologin.launch`. `-RMAutoLogin YES` (the `run-sim.sh` default; `--player-login` turns it off) swaps `.manual` for the unattended login. |
| Perf probe | `-Drunelite.fpsprobe=true -Xlog:gc,safepoint:…`, `-Drunelite.cpu.unlockfps`, `-Xms` | Armed by marker files; see [Logs](#logs-and-files-on-the-device). |

The bridge properties are listed with their meaning in the [bridge API reference](bridge-api-reference.md).

### Why the JVM thread parks forever

`DeviceHeadlessBoot.main` returns when its `headless.runSeconds` window ends, about 240 seconds into every
session, while the engine's non-daemon threads carry on. An earlier version cleaned up after `main` returned by
clearing the VM pointer. That turned `bridgeReady` off, and every tap was dropped from four minutes into each
session onward. Calling `DestroyJavaVM` instead races the engine's threads during unload. So after `main` returns,
the JVM thread logs `DeviceHeadlessBoot returned — parking jvm-main` and sleeps for the life of the process.

Don't add teardown after `main`. The VM lives until the process dies. (Android avoids the question by passing
`-Dheadless.runSeconds=86400`.)

## JIT on a device

### Why it needs a debugger

iOS lets a process create executable memory only while a debugger is attached, and on devices with Apple's
Trusted Execution Monitor (TXM) even that memory has to be mapped by the debugger. The patched JRE runs with
`-XX:+MirrorMappedCodeCache`: when HotSpot wants code-cache memory it executes `brk #0x69` with the size in `x0`.
StikDebug, the on-device debugger, runs [`runelite-jit.js`](../../ios/app/stikdebug/runelite-jit.js), which maps
an RX region of that size, prepares it for execution and returns its address. libjvm reserves the whole code
cache in that one call, so the script serves one request and then detaches;
[`patch-jre-txm.sh`](../../ios/dev-tools/patch-jre-txm.sh) patches libjvm so it always takes this path.
[`ios/app/stikdebug/README.md`](../../ios/app/stikdebug/README.md) has the protocol
details.

### What the user does each launch

1. Turn on LocalDevVPN (StikDebug talks to the phone's own debug service through it).
2. Open StikDebug, pick RuneMobile, and attach with `runelite-jit.js` assigned to it.
3. Back in RuneMobile, wait for "Ready to play" and tap **Tap to Play**.

The README's [StikDebug & the JIT script](../../README.md#stikdebug--the-jit-script) section is the user-facing
version.

`CS_DEBUGGED` is per process and stays set once the attach has happened. A session survives backgrounding as
long as the process lives. A process that iOS kills (jetsam) or the user closes needs a new attach. That is why
the [keepalive](#backgrounding-and-residency) matters so much on iOS.

### Traps

- **Opening the app without the attach waits on the cover forever.** That's by design: without the debugger
  there is no JIT, and booting would crash. Don't "fix" it in code.
- **A "Starting JIT" spinner in StikDebug that never resolves** is StikDebug mounting the Developer Disk Image,
  which happens before our script runs. Look at StikDebug and the VPN, not at RuneMobile.
- **One VPN at a time.** iOS runs a single VPN. SideStore's VPN is for installing and refreshing; LocalDevVPN is
  for the JIT attach. Turn off whichever you're not using
  ([`FRIEND-INSTALL-GUIDE.md`](../../ios/FRIEND-INSTALL-GUIDE.md), "If something's off").
- **The in-app login needs a restart.** Once the login's `WKWebView` has run, WebKit stays loaded in the process
  and stops StikDebug from servicing `brk #0x69`: the JVM would crash at code-cache setup. After a login (or an
  account switch) the app saves `tokens.json` and asks for a restart; the next launch goes straight to play.
- **No attach, no stack traces.** A crash before the attach leaves only `crash.log` (Objective-C exceptions)
  and the device's crash reports; there is no JVM output yet.
- **TrollStore is not an option.** It relies on a CoreTrust bug that was fixed in iOS 17.0.1. Installs go through
  SideStore or AltStore (or Xcode for development).

## Building and installing on a device

Install the tools in [Setup](setup.md), place the JRE, stage the jars, and generate the project. Then pick a
route:

| Route | When | Command |
|---|---|---|
| Xcode | A Mac on the phone's network, set up interactively | Open `RuneMobile.xcodeproj`, choose your team, run on the device |
| `remote-build.sh` | Scripted build and install from a Mac on the phone's network | `DEV=<device UDID> ios/dev-tools/remote-build.sh` (add `--with-jars` to rebuild the jars first, `CONFIG=Release` for Release) |
| `deploy-remote.sh` | Jars built on one Mac, app built and installed by another Mac on the phone's network | `ios/dev-tools/deploy-remote.sh` with `deploy-remote.conf` (copy the `.example`); see [`DEPLOY-REMOTE.md`](../../ios/dev-tools/DEPLOY-REMOTE.md) |
| `serve-ipa.sh` | Away from the phone's network | `ios/dev-tools/serve-ipa.sh` (add `--jars` after a Java change) |

**Why the network matters:** the phone's `lockdownd` answers on its LAN interface and resets the same request
when it arrives over a VPN. An install must start from a Mac on the phone's own network (or over a cable).
SideStore gets around this by talking to the phone over loopback.

**`serve-ipa.sh`** builds a development-signed IPA, refuses to serve one whose signature is broken, whose profile
has no devices or has expired, or that lacks `get-task-allow`, and then publishes two things over HTTPS on your
own private network: an install page (an `itms-services` manifest Safari can install from) and a
SideStore/AltStore source. Each build gets the next build number in `.serve-ipa/build.txt`, so its version sorts
above the release it replaces. `--build-only` skips serving and `--stop` removes only its own handler. The
static server is not a background service, so after a reboot run it again.

There is no CPU-only bundle: every renderer runs from the same staged jars and is chosen at runtime, so the
scripts refuse the old `MODE=cpu` / `--cpu` (it copied the pristine shaded jar, which `check-staged-jar.sh`
rejects).

### Check that the phone runs your build

A successful build or a push does not put anything on the phone. After installing, confirm the bundle holds your
change before you trust a test:

```sh
# Java: compare a class in the built bundle with your local build output
unzip -p build/dd-mui/Build/Products/Debug-iphoneos/RuneMobile.app/client-shaded.jar \
  net/runelite/client/headless/JavaBridge.class | md5
md5 < runelite-client/build/classes/java/main/net/runelite/client/headless/JavaBridge.class
```

In a Debug build the Objective-C code lives in `RuneMobile.app/RuneMobile.debug.dylib`, and the main
`RuneMobile` binary is a stub. Run `strings` on the dylib, not the stub. Then force-quit the app on the phone,
attach StikDebug again, and look for your change in the logs.

## The iOS Simulator

The whole app, all three renderers and real JIT run in the iOS Simulator on an Apple silicon Mac, with no
StikDebug. Use it for native UI and feature work before going to the phone.

```sh
ios/dev-tools/run-sim.sh                   # build, install, launch, press Play (CPU)
RENDERER=117hd ios/dev-tools/run-sim.sh    # cpu | gpu | 117hd
ios/dev-tools/run-sim.sh --jars            # restage the jars first, after a Java change
ios/dev-tools/run-sim.sh --no-build        # relaunch the last build
ios/dev-tools/run-sim.sh --from-phone      # copy a paired phone's settings and profile (never its login)
ios/dev-tools/run-sim.sh --desktop-login   # log in with the desktop harness's session (--logout undoes it)
```

Other flags: `--manual` (don't press Play), `--no-launch` and `--print-udid` (for scripts). `SIM_NAME` or
`SIM_UDID` picks the device. [`ios/README.md`](../../ios/README.md) covers each flag, and
[Testing and QA](testing-qa.md) covers the census, screen goldens, plugin sweep and `sim-gate.sh`.

How it works: `resign-jre.sh` retags the JRE as a Simulator binary, and under `TARGET_OS_SIMULATOR`
`JVMLauncher.m` installs a `SIGTRAP` handler around `JNI_CreateJavaVM` that answers `brk #0x69` itself, mapping
the memory with `vm_allocate` and `vm_protect`. None of this is compiled into a device build.

Launch arguments the scripts pass, which you can pass too. Apart from `-rendererPref` (an ordinary user default),
they exist only in Simulator builds:

| Argument | Effect |
|---|---|
| `-rendererPref cpu\|gpu\|117hd` | Sets the saved renderer. |
| `-RMAutoPlay YES` | Presses Tap to Play once the cover is up. |
| `-RMSkipLogin YES` | Uses an empty per-launch token file, so a logged-in Simulator stays on the login screen. |
| `-RMScreenDriver YES` | Lets `sim-screens.py` open native screens by writing `Documents/screen-cmd`. |
| `-RMBlankGame YES` | Covers the game picture, for stable screenshots. |
| `-RMAudioStats YES` | Logs a line of audio numbers every 5 s (`runelite.audio.stats`). |

What the Simulator shows and doesn't:

- **Cold cache.** A fresh install spends about 30 s downloading the game cache before the first draw. Logs
  showing `draws=0` during that time are not a hang.
- **117 HD stalls on first world entry.** Apple's software renderer compiles each shader program at its first
  draw, on the client thread. The freeze lasts a minute or more, the server drops the connection, and the app
  logs back in. That is the Simulator. `sim-gate.sh` boots 117 HD only to the login screen, and
  [`tools/shader-matrix/`](../../tools/shader-matrix/README.md) checks the shaders without a phone.
- **No memory numbers.** `os_proc_available_memory()` returns 0, so "0 MB free" lines in the Simulator are noise.
- **Not a phone.** Performance, the StikDebug path, the phone's GPU driver, multi-touch, backgrounding and PiP
  need the device.
- **Holds and drags** can be driven with `cliclick` on the Simulator window, for example
  `cliclick dd:X,Y w:1200 dm:X2,Y2 w:400 du:X2,Y2` for a hold, a drag and a lift. A press much shorter than the
  long-press time is still a tap.
- **One session per account.** `--desktop-login` shares the desktop harness's session; running both at once
  kicks one of them off. Use a throwaway Jagex account.

## Native UI

### The game view and touch mapping

The game picture is an `RMSceneView`, a `UIImageView` subclass with `contentMode` aspect-fit. `mapPoint:` turns a
view point into canvas pixels with the same aspect-fit maths. The view classifies taps from raw touches itself
rather than leaving it to UIKit's gesture recognizers, whose ~10 pt pan threshold used to steal taps and
long-presses.

| Constant / setting | Value | Meaning |
|---|---|---|
| `kSceneDragSlop` | 18 pt | How far a finger may roll and still be a tap or a hold. Also the long-press recognizer's `allowableMovement` and the camera pan's start threshold. |
| `kSceneTapHoldMargin` | 0.05 s | Grace past the long-press time for a tap's lift. |
| `touch.longPressMs` | 200–1000 ms, default 400 | Long-press time (Game settings). |
| `dragHoldMs` | min(long-press × 2/3, 150 ms) | How long a finger must rest on an inventory item before a drag picks it up. |
| `camera.sensitivity` | 0.1–4.0, default 2.0 | Camera drag gain; the gain is sensitivity / 2. |
| `kOrbTapPad` | 10 | Extra canvas pixels around each minimap orb's hit area. |

A tap commits at the point where the finger landed, not where it lifted. On touch-down the app arms the tap
(`armTap`), so the bridge moves the cursor and lets the engine resolve the hover while the finger is still down;
the lift then clicks without waiting. A drag past the slop, a second finger or a long-press cancels the arm.

A tap is routed in this order: the open world map window (precise click; its search box raises the keyboard),
the minimap orbs, the chat tab row, the chat message area, the dialogue box, and finally a world click.

A **long-press** opens the engine's right-click menu at the finger (haptic on open), highlights rows as the finger
slides, and commits on release. A tap-mode menu (submenus, shift-customise) stays open until a tap. A **one-finger
drag** pans the open world map, scrolls an engine list or the chat, drags an inventory or prayer/spellbook item
after the hold, or else turns the camera. Camera deltas are scaled from screen points to canvas pixels, multiplied
by the camera gain, and accumulated so slow drags still move. A **pinch** becomes mouse-wheel notches (zoom).
The arrow buttons in the pinned controls turn the camera while held, at fixed rates.

Android implements the same rules; keep the two in step (see [Android touch input](android.md#touch-input)).

### The world map transform

While the world map is open, `applyMapZoom` scales the game view with `self.screen.transform` (one uniform scale
plus a translation, nearest-neighbour filtering, black bands) so the map window fills the screen. Anything you
draw over the game in view coordinates has to go through that transform. `engineMenuRectInView` converts the
engine menu's rectangle with `[self.screen convertRect:toView:]`; a native overlay that skipped this would draw
away from the finger whenever the map was open.

### Keyboard

The game's text fields raise the soft keyboard on their own: about ten times a second the view controller reads
`+[JVMLauncher textInputKind]`, raises the keyboard when a field opens and drops it when it closes. Kind 2 (an
amount prompt) gets the number pad, everything else the ASCII keyboard. The ⌨︎ button at the top holds the
keyboard up for chat. A plugin panel's text field takes priority, so the game's poll never steals its keyboard.
`RMKeyboardDismiss` gives search fields a Done bar.

### Settings, pinned controls and the control editor

The ⚙ gear is always on screen. **Game settings** (`RMGameSettings`) holds the long-press time, camera speed,
idle-logout time, frame-rate cap (30 fps on a new install) and haptics; the game-dependent rows appear once the game
has loaded. Changes
post `RMGameSettingsDidChangeNotification`. Long-pressing the gear sets the **Interface size**, the canvas height
from 480 to 600 (default 540): a smaller canvas makes the HUD larger. It applies at the next launch.

**Pinned controls** are buttons the player puts in the corner: sticky Shift and Ctrl, Space, Enter, Esc, Tab,
F1–F12, number keys, held camera arrows, screenshot, PiP, the hotkey strip and the world map. The catalogue is
`allControlSpecs` in `ViewController.m`, and the pinned list is the `pinnedControls` default. **Edit controls**
(from Settings) dims the game and shows the full palette to add, remove and reorder them.

**Overlay edit mode** (`OverlayEditView`) shows a labelled handle for every movable RuneLite overlay and for the
native chat box and minimap cluster. A drag moves it, dropping near an edge snaps it to a corner, and each handle
can reset its overlay.

### Plugin screens

`PluginPanelsViewController` runs as a dock on the game screen: a plugin icon rail on the right edge (it can be
hidden in Settings) and the selected side panel drawn inline over the live game. A panel's Swing tree is rendered
headless into an image; taps, scrolls and text go back as Swing events. The plugin list, each plugin's config
screen (`PluginConfigViewController`), the Plugin Hub, Config Profiles and Infoboxes are reached from there. All
of them talk to `MobileUiBridge`; see [The bridge API](bridge-api.md).

### Haptics and accessibility

Four haptic triggers (operate, drag, menu open, menu hover) and a strength setting live in Game settings, and all
of them share one `UIImpactFeedbackGenerator`. The pinned controls and the plugin rail carry
`accessibilityLabel`s for VoiceOver. Give any new control one; a glyph such as ⇧ reads as nothing useful.

## Backgrounding and residency

Because JIT belongs to the process, losing the process means another StikDebug attach. iOS gives a backgrounded
app a few seconds before suspending it, so the app keeps itself running:

- **Silent audio.** The audio session is set to playback mixed with others, and an `AVAudioEngine` plays a silent
  source node. Handlers restart it after an interruption, a route change or a media-services reset, and a 15 s
  watchdog checks it.
  Game audio has an engine of its own and stops when the app leaves the foreground, so it can't hold the process
  awake past the idle release below, and nothing that happens to it can take the keepalive down.
- **Picture in Picture.** The game can keep running in a PiP window, fed from an `AVSampleBufferDisplayLayer`; a
  background pump feeds it about 15 times a second.
- **Idle release.** After 10 minutes backgrounded and logged out (`kBgIdleStopSeconds`, skipped while PiP is
  showing), the app stops the keepalive and lets iOS suspend it, rather than holding a session nobody is using.
- **Save on background.** Entering the background flushes RuneLite's config (`mobileFlushConfig`), so a later
  kill doesn't lose settings.

`RMResidency` records each session (`Documents/residency.plist`, with a history of the last 200 in
`Documents/residency-history.log`) and classifies how the previous one ended: clean exit, idle release, suspected
jetsam (free memory had dropped below 120 MB), or an unexpected end in the background or foreground.
[`ios/dev-tools/residency.py`](../../ios/dev-tools/residency.py) pulls the history from a connected phone
(`-v` for detail, `--self-test`). The verdicts are inferences: the ground truth is a `JetsamEvent` report in
Settings → Privacy & Security → Analytics & Improvements → Analytics Data, plus `jvm-stdio.log`.

**Memory.** The JVM heap is capped at 1 GB, which fits under the jetsam limit with the increased-memory-limit
entitlement. A Debug build (or a Release build with the perf probe armed) logs
`[memwatch t=…] avail=… footprint=… heapMB=… thermal=…` every 0.5 s for the first 30 s and every 5 s after.

## Logs and files on the device

| File | Where | Build | What |
|---|---|---|---|
| `hello-shell.log` | Documents | Debug | The app's own log: `[shell]`, `[jvm]`, `[boot]`, `[screen]` lines. Previous launch kept as `.prev`. |
| `jvm-stdio.log` | Documents | Debug | The JVM's stdout and stderr, unbuffered. Previous launch kept as `.prev`. |
| `perf-probe.log` | Documents | Release, probe armed | The perf probe's lines only. |
| `crash.log` | Documents (Debug), Application Support (Release) | both | Uncaught Objective-C exceptions. |
| `client.log` | `.runelite/logs/` under the RuneLite home | both | RuneLite's own log. |
| `residency.plist`, `residency-history.log` | Documents | both | See above. |
| `rl-capture/` | Documents | Debug | Headless frame captures. |
| `tokens.json` | Application Support | both | The Jagex session. Secret; never log or copy it. |

A Debug build exposes Documents in the Files app and Finder. From the command line:

```sh
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier dev.audaro.runemobile \
  --source Documents/jvm-stdio.log --destination ./jvm-stdio.log
```

Release builds write no diagnostic logs by design. To measure a build, arm the perf probe with
[`tools/perfprobe.sh`](../../tools/perfprobe.sh) (`tools/perfprobe.sh ios on`, or `marker cpufps N` /
`marker xms 384m` for A/B runs). The app reads `Documents/perfprobe` and the markers at the next launch;
`devicectl` can't delete a file in the container, so `off` writes the word "off" and the app treats it as
disarmed. [Debugging](debugging.md) has the symptom table and the tools for reading these logs.

## iPad and foldables

**iPad** is supported: `TARGETED_DEVICE_FAMILY` is `1,2`, and the app stays full-screen and landscape-only.

- **Canvas.** On a phone the canvas height is the Interface size (540 by default) and the width follows the
  screen's aspect. When the screen's short side is at least 600 pt (`kLargeScreenPt`), the height grows with the
  screen instead (setting × screen height / 440 pt, capped at the screen's pixels), so the HUD keeps its phone size
  and more of the world shows. The canvas is never narrower than 765 px (`kMinCanvasW`), the game's narrowest
  layout.
- **No side insets.** An iPhone in landscape has a safe-area inset on each side, which the plugin rail sits in.
  An iPad (or a home-button iPhone) has none, and the rail covered the tab grid's right column.
  `hudRightInset` is therefore `MAX(safe-area right, railStripWidth)`, and the HUD re-anchors when the rail's
  width changes. Use `hudRightInset`, not the safe area, for anything anchored to the right edge.
- **Resizable windows.** `UIRequiresFullScreen` keeps the iPad window full-screen. An SDK that ignores it would
  need UIScene support and live canvas resizing, which iOS doesn't have yet (Android does).

**Foldable iPhones:** nothing ships yet.

In the Simulator, an iPad that is standing in portrait shows the landscape-only app in a letterboxed band. Rotate
the Simulator window to landscape before taking screenshots.

## Before you commit an iOS change

1. Build for the Simulator and try the change there (`run-sim.sh`).
2. After a change to a JNI lookup or to shared Java, run the iOS bridge census:
   `ios/dev-tools/bridge-census/run-census-sim.sh --jars` (expect `IOS_BRIDGE_CENSUS_GREEN`).
3. After a native-UI change, run `ios/dev-tools/sim-screens/sim-screens.py` and look at any diff before you
   `--update` a golden.
4. Before a release, after an upstream merge, or after a shader or renderer change, run
   `ios/dev-tools/sim-gate.sh` (expect `SIM_GATE_GREEN`, about seventeen minutes).
5. For anything the Simulator can't show (touch feel, performance, the GPU driver, backgrounding), install on a
   phone and check the bundle as above.

[Testing and QA](testing-qa.md) has the full ladder, including the desktop checks that come before any of this.

## See also

- [`ios/README.md`](../../ios/README.md): layout, the staging order, the Simulator flags.
- [`ios/dev-tools/DEPLOY-REMOTE.md`](../../ios/dev-tools/DEPLOY-REMOTE.md): the two-Mac build and install loop.
- [`ios/app/stikdebug/README.md`](../../ios/app/stikdebug/README.md): how the JIT script works.
- [`ios/dev-tools/JRE21-INVENTORY.md`](../../ios/dev-tools/JRE21-INVENTORY.md): the embedded JRE.
- [Android port](android.md), [Architecture](architecture.md), [The bridge API](bridge-api.md),
  [Renderers](renderers.md), [Testing and QA](testing-qa.md), [Debugging](debugging.md), [Gotchas](gotchas.md).
