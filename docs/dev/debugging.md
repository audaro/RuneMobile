# Debugging

Most RuneMobile bugs can be reproduced somewhere cheaper than a phone, and most of the rest leave a line in a log
if you know which log to read. This page covers where to reproduce a problem, where each platform's logs live and
how to pull them, the tools for scanning them, the JVM and bridge diagnostics, and a table of symptoms with their
usual causes.

Before you start, remember the account rule from the [README](../../README.md#risk--disclaimer): every live test
runs against the real OSRS servers, so use a throwaway Jagex account, never a main.

## Method: desktop first, then the Simulator, then a phone

Both ports embed the same Java code (RuneLite plus the `headless` bridge package) on OpenJDK 21. The JVM family on
a phone is the same as on a Mac, so a bug in Java code almost always reproduces on desktop, where a run takes
seconds and you have every tool. Move to slower targets only for what the faster ones cannot show.

| Question | Cheapest place to answer it |
|---|---|
| Does the Java side do the right thing (bridge logic, plugin loading, game state, overlays)? | Desktop, headless harness |
| What does stock RuneLite do here? | Desktop, `run-desktop-reference.sh` |
| Does the iOS UI, the native-to-Java bridge, or a renderer boot work? | iOS Simulator |
| Is it fast enough, does memory fit, does the JIT path work, does a real GPU driver accept it, does touch feel right, does it survive backgrounding? | A phone (or, for some Android questions, the arm64 emulator) |

### Desktop

`ios/dev-tools/headless/` boots real RuneLite with the desktop Swing UI replaced by the headless one, on a desktop
JDK 21, and captures the engine's frames to PNG. The CACIO variants run with no OS window at all, which is the
closest desktop proxy for a phone:

```sh
cd ios/dev-tools/headless
./run-headless-cacio.sh          # to the login screen; frames and run-cacio.log land in out/
./run-headless-login-cacio.sh    # logs in and plays; frames and run-cacio-login.log land in out-login/
```

The login variant needs `ios/dev-tools/tokens.json` (gitignored), minted with
`ios/dev-tools/fetch-shield-tokens.sh` for a throwaway account. `RUN_SECONDS` sets the run length.
[ios/dev-tools/headless/README.md](../../ios/dev-tools/headless/README.md) explains the harness and the other
`run-*.sh` scripts there, each of which exercises one bridge with its own `*-verdict.sh`.

For ground truth, `ios/dev-tools/run-desktop-reference.sh` launches the fork's stock RuneLite client with its normal
desktop window on JDK 21. If the bug also happens there, it is upstream behaviour, not ours.

Two cautions:

- The harness uses your normal RuneLite home (`~/.runelite`), including its profile and config. If you also play
  RuneLite on the same Mac, point it elsewhere for the run (for example
  `JAVA_TOOL_OPTIONS="-Duser.home=$PWD/build/rlhome"`).
- One Jagex session per account. A desktop harness run and a phone or Simulator logged in to the same account at
  the same time will kick each other off.

The bridge's unit tests also run on desktop and are the quickest check of all:

```sh
./gradlew :client:test --tests 'net.runelite.client.headless.*'
```

What desktop cannot tell you: anything about the GLES shader rewrite (desktop GL compiles the original shaders;
see [renderers.md](renderers.md)), touch, the native shells, memory limits, or the device JIT.

### iOS Simulator

`ios/dev-tools/run-sim.sh` builds the iOS app for the Simulator, installs it, launches it and presses Play. No
phone and no StikDebug: the Simulator build services HotSpot's JIT breakpoint itself.

```sh
ios/dev-tools/run-sim.sh                    # build Debug, install, launch, Play
ios/dev-tools/run-sim.sh --jars             # rebuild and stage the jars first, after a Java change
RENDERER=117hd ios/dev-tools/run-sim.sh     # cpu (default) | gpu | 117hd, this launch only
ios/dev-tools/run-sim.sh --desktop-login    # log the Simulator in with the desktop harness's session
```

The script's header lists every option. Per its own header, the Simulator does **not** tell you about performance
(Mac CPU, no memory cap, no thermals), the device JIT path, GPU driver quirks (its GPU modes draw with Apple's
software renderer), real multi-touch, or background and Picture-in-Picture behaviour.

### Phone or emulator

Use a phone for everything in the last row of the table above. On Android the arm64 emulator covers a lot of
bring-up and UI work, but not GPU driver behaviour or real performance. [ios.md](ios.md) and
[android.md](android.md) cover building and installing on each.

## Logs

### iOS

| File (in the app's container) | Written by | When |
|---|---|---|
| `Documents/hello-shell.log` | the native shell (`[shell]`, `[jvm]`, `[login]` and similar lines) | Debug builds |
| `Documents/jvm-stdio.log` | the JVM's stdout and stderr, unbuffered | Debug builds |
| `Documents/*.log.prev` | the same two files from the previous launch | Debug builds |
| `Documents/perf-probe.log` (+ `.prev`) | the perf probe's lines only | Release builds with the perf probe armed |
| `.runelite/logs/client.log` | RuneLite's own rolling log | Debug: under `Documents/`. Release: under `Library/Application Support/` |

`jvm-stdio.log` is written with an unbuffered `dup2`, so it survives a crash; it is the first file to read after
one. The previous launch's logs are kept as `.prev` because the launch that died is usually the one you need, and
the launch you start to investigate it would otherwise overwrite it. **Release builds write no shell or JVM log**
(only `perf-probe.log` when the probe is armed), so debug with a Debug build.

`client.log` is cumulative and can name the account. Redact it before sharing.

Pull a file from a phone with `devicectl` (the phone must be paired and unlocked; no JIT attach is needed):

```sh
xcrun devicectl list devices
xcrun devicectl device copy from --device <UDID> \
    --domain-type appDataContainer --domain-identifier dev.audaro.runemobile \
    --source Documents/jvm-stdio.log --destination ./jvm-stdio.log
```

A SideStore install may use its own bundle ID; use that as the domain identifier. In the Simulator the container is
on your Mac:

```sh
DATA="$(xcrun simctl get_app_container booted dev.audaro.runemobile data)"
less "$DATA/Documents/jvm-stdio.log"
```

The app's on-screen console shows the same shell lines, and its Share action exports the full file.

### Android

The embedded JVM's stdout and stderr go to logcat under the tag `jvm-stdout`. In a **debug** build that is
everything the VM prints. A **release** build forwards only the perf probe's lines and drops the rest, so the
engine's output never leaks into a shared log; debug with a debug build.

| Tag | Source |
|---|---|
| `jvm-stdout` | the JVM's stdout/stderr (RuneLite, the bridge, HotSpot) |
| `jvm-boot` | `jvm_bootstrap.cpp`: VM start, the CPU render thread, pause and resume |
| `librlawt` | the GL bridge: context creation, present path, shader dumps, `[shadowmap]`, `[gpuprobe]` |
| `MainActivity` | the Kotlin shell, including renderer decisions and the thermal governor |
| `JagexLogin`, `JagexTokens`, `LegacyCreds` | login and token storage |
| `AssetInstaller` | first-run extraction of the JRE and jars |
| `KeepaliveService` | the background-session foreground service |

```sh
adb logcat -c                                                   # clear, then launch the app
adb logcat -v threadtime -s 'jvm-stdout:*' 'jvm-boot:*' 'librlawt:*' 'MainActivity:*'
adb logcat -d -v threadtime -s 'jvm-stdout:*' > pixel.txt       # dump for the log scan
```

The logcat ring buffer rolls over within minutes when the perf probe is chatty. For a complete record read
RuneLite's own log from the app's private files (`user.home` is the app's files dir), which works on a debug build:

```sh
adb shell run-as dev.audaro.runemobile cat files/.runelite/logs/client.log > client.log
```

A few Android facts that cost time when forgotten:

- `adb install -r` keeps the old process alive. Run `adb shell am force-stop dev.audaro.runemobile` and launch
  again, or you are testing the previous build.
- After changing anything under `android/app/src/main/cpp/`, run
  `./gradlew :app:externalNativeBuildDebug --rerun-tasks` before assembling, or the APK can ship the old `.so`.
- Many phones doze with the screen off and drop `adb`. While working, `adb shell dumpsys deviceidle disable` and
  (while plugged in) `adb shell svc power stayon true`; restore both with `enable` and `false` afterwards.

### Desktop

The harness writes `out/run-cacio.log` or `out-login/run-cacio-login.log` under `ios/dev-tools/headless/`, and
RuneLite writes its usual `client.log` under the RuneLite home.

## Scanning a log

[`tools/log-scan/`](../../tools/log-scan/README.md) sorts a run's warnings, errors and exceptions into known noise
and new problems. It reads all four kinds of log and any mix of them in one run:

```sh
tools/log-scan/log-scan.py --sim "$DATA/Documents/jvm-stdio.log" --sim "$DATA/Documents/hello-shell.log"
tools/log-scan/log-scan.py --phone ./jvm-stdio.log
tools/log-scan/log-scan.py --android pixel.txt
tools/log-scan/log-scan.py --desktop ios/dev-tools/headless/out/run-cacio.log
```

It ends with `VERDICT: LOG_SCAN_GREEN` (exit 0), `_RED` (exit 1), or exit 2 when an input is missing, empty or the
wrong kind. New signatures are listed by logger in the order they first appeared, because the first new line is
usually the cause. `--suggest` prints a noise-entry stub for each new signature; an entry in `known-noise.json` must
say why the line is harmless. Shader errors are counted on their own and cannot be excused as noise.
`ios/dev-tools/sim-gate.sh` runs the scan over every launch it makes.

## Bridge faults

The bridge runs code from the engine's render loop and from native code on every frame. A fault there must neither
escape (a throw out of `Hooks.draw` crashes the frame) nor vanish (a swallowed exception after an upstream merge
looks like a frozen HUD or a dead tap, with nothing in the log). Both halves log with the same tag, so one grep finds
both:

- **Java**: `BridgeFaults.note` logs `[bridge-fault] <site> threw` with the stack the first time a site faults, then
  suppresses repeats for 5 seconds and reports the suppressed count in the next window.
- **iOS native**: the per-frame and per-poll calls into the bridge clear a pending exception through
  `bridgeNoteClear` (`JVMLauncher.m`), which prints the same `[bridge-fault]` tag with the exception's description to
  stderr, under the same 5-second rate limit, and returns a safe empty value so the fault cannot reach UIKit. iOS also logs `[json-fault]` when a snapshot the Java side published fails to parse.
- **Android native**: optional method lookups go through `midOpt` in `jvm_bootstrap.cpp`, which clears the
  `NoSuchMethodError` a failed lookup leaves pending. A pending exception that is not cleared makes the *next* JNI
  call fail in an unrelated place, which is one of the most confusing bugs this codebase has had; clear or check
  after every lookup that may fail.

When a `[bridge-fault]` appears after an upstream merge, the stack usually names a widget, interface or API that
changed. Two tools catch the related class of bug, a native lookup of a Java name that no longer exists, before a
phone does:

```sh
android/dev-tools/bridge-census/run-census-desktop.sh      # expect ANDROID_BRIDGE_CENSUS_GREEN
ios/dev-tools/bridge-census/run-census-sim.sh --jars        # expect IOS_BRIDGE_CENSUS_GREEN
tools/shared-contract/check-contract.sh                     # exit 0 unchanged, 1 additive, 2 removed or changed
```

[bridge-api.md](bridge-api.md) describes the contract these protect.

## JVM tools

### Heap and out-of-memory

The heap is capped by the launcher: `-Xmx1024m` on iOS (`kMaxHeapMb` in `JVMLauncher.m`) and `-Xmx512m` on Android
(`MAX_HEAP_MB` in `MainActivity.kt`). Both pass `-XX:+ExitOnOutOfMemoryError`: a JVM that has run out of heap is not
worth keeping alive in a half-working state, and a clean exit lands in each shell's crash fallback and relaunch flow
instead of a frozen game.

To try a different initial heap without a rebuild, set the `xms` marker (Android debug builds, or iOS):

```sh
tools/perfprobe.sh android marker xms 384m
```

On iOS the process can also be killed by the system (jetsam) for its total footprint, which the Java heap is only
part of. The app logs `[memwatch ...]` lines with the jetsam headroom, the footprint, the Java heap and the thermal
state. [`ios/dev-tools/residency.py`](../../ios/dev-tools/residency.py) pulls the app's record of how each session
ended and adds up the causes over many sessions; the ground truth for a jetsam kill is a `JetsamEvent-*.ips` report
under Settings → Privacy & Security → Analytics & Improvements → Analytics Data.

Those `[memwatch]` lines only exist in a Debug build or with the perf probe armed, so a player's phone keeps a memory
trail instead: a line a minute of the footprint, the headroom, graphics, media and malloc memory, the Java heap and the
thread count ([`RMMemoryTrail.h`](../../ios/app/RuneMobile/RMMemoryTrail.h) says what each one covers). Share logs
carries it in **Memory trail**, kept across the kill, and **Recent sessions** says how the last eight sessions ended.
The trail's last session may not be the one that wrote the report, so go by its opening line.

### GC and safepoint logging

Arming the perf probe also runs the VM with `-Xlog:gc,safepoint` to stdout, next to the per-second frame probes:

```sh
tools/perfprobe.sh android on      # or ios; takes effect at the next launch
```

A GC pause or a long safepoint lines up with a `[frameprobe]` max or a `[framebins]` outlier in the same second.
[renderers.md](renderers.md#measuring-performance) describes the probe lines and the `fps-measure.sh` summary.

### Java Flight Recorder (Android)

```sh
tools/perfprobe.sh android marker jfr 120     # record 120 s, starting a minute after launch
adb shell am force-stop dev.audaro.runemobile  # then launch and play through the window
adb exec-out run-as dev.audaro.runemobile cat files/jfr/rec.jfr > rec.jfr
jfr summary rec.jfr                            # or open it in JDK Mission Control
```

The recording uses the `profile` settings and is capped at 600 seconds. This marker is Android-only and needs a debug
build. On desktop, add the usual `-XX:StartFlightRecording` options to a harness run.

### System-property switches

The bridge reads a set of `-D` switches. Every one is listed as a `FLAG` line in
[`tools/shared-contract/baseline.txt`](../../tools/shared-contract/baseline.txt), so the list cannot drift from the
code silently. The ones that help when debugging:

| Flag | What it does |
|---|---|
| `runelite.touch.diag` | Logs every in-world tap's geometry, the settle-gate result and the menu entry the engine consumed (`[touchdiag]`). iOS Debug builds set it. |
| `runelite.hudveneer.ifacedump` | Logs the open interface roots (`[ifaces]`), to find which group a window uses. Costly; off by default. |
| `runelite.huddata.dumpSnapshot` | Dumps the full HUD data snapshot. It includes recent chat lines, **private messages too**, so it is opt-in and the output must not be shared unredacted. |
| `runelite.gatecensus` | Logs `GATE_CENSUS <gate> enabled= live=` once logged in, proving each bridge gate is actually active. Android's census mode sets it. |
| `runelite.gpuframedump` (+ `.dir`) | Writes each composited in-world GPU frame as a PNG. Android debug builds set it for GPU boots. |
| `runelite.audio.stats` | Logs each open audio line every 5 s: whether it reaches an output, seconds played, loudest sample. Android debug builds set it from an `audio.stats` marker in the app's external files, iOS from `-RMAudioStats YES`. |
| `runelite.audio.capture` | `=<file>` writes the game's audio to a WAV instead of a device. On desktop this is how to hear what a phone would play. |
| `runelite.audio.muted` | Starts with Game sound off. The launchers set it from the saved setting. |
| `runelite.hover.text` | Restores the desktop hover label, which mobile hides because a touch screen has no hover. |
| `runelite.key.pacing` | Keyboard pacing for typed input; on by default. |
| `runelite.headless.autologin.*` | The desktop harness's synthesized login (world, click point, attempts). On a phone `.manual` leaves the login to the player; for an unattended one use `-RMAutoLogin YES` (iOS) or an `autologin.mode` marker in the external files dir (Android debug builds). |

On desktop, add a flag to the harness's `java` command line. On a phone, the launchers build the argument list in
`JVMLauncher.m` (iOS) and `MainActivity.kt` (Android); add the flag there in a debug build, and don't commit it on.

## Native crashes

- **JVM crash (HotSpot)**: HotSpot prints `A fatal error has been detected by the Java Runtime Environment` to
  stderr, which lands in `jvm-stdio.log` (iOS Debug) or `jvm-stdout` (Android debug), and writes an
  `hs_err_pid<pid>.log`. Before reading an `hs_err` file, check that its timestamp and `java.home` belong to the build
  you are debugging: old ones linger in app containers and build directories.
- **iOS native crash**: the system writes a crash report. Find it in Xcode's Devices and Simulators window (View
  Device Logs), or on the phone under Settings → Privacy & Security → Analytics & Improvements → Analytics Data.
  The previous launch's `jvm-stdio.log.prev` shows what the JVM was doing.
- **Android native crash**: the backtrace is in logcat's crash buffer, and the full tombstone is in a bug report:

  ```sh
  adb logcat -b crash -d
  adb bugreport bugreport.zip
  ```

- **A GPU boot that died**: the shell's crash cookie reverts to CPU at the next start (see
  [renderers.md](renderers.md#the-crash-cookie)). Android records the details in `files/gpu-fail.txt`
  (`adb shell run-as dev.audaro.runemobile cat files/gpu-fail.txt`); on iOS read the `.prev` logs.

## The harness tool server

[`tools/mcp/harness_server.py`](../../tools/mcp/README.md) is a small stdio server that exposes the harness scripts
above as callable tools to any client that speaks the Model Context Protocol, so a render or QA loop can be driven
from an editor or a script instead of by hand. It is optional; every tool wraps a script you can also run directly.
Registration goes in a gitignored `.mcp.json`, and the image tools need a Python with PIL and numpy. The useful
ones when debugging:

| Tool | Use |
|---|---|
| `headless_render` | Run a desktop harness capture and get frames plus parsed markers. |
| `image_diff` | Compare two PNGs numerically, with a heatmap. |
| `ios_pull_logs` | Pull `jvm-stdio.log` or `perf-probe.log` (and optionally `client.log`) from an iPhone, with an `fps-measure.sh` summary. |
| `ios_sim_run`, `ios_sim_wait` | Launch in the Simulator and wait for a frame or a game state; fails at once on a `FATAL`. |
| `android_fps` | A timed `fps-measure.sh` capture with thermals. |
| `run_verdict` | Run any `*-verdict.sh` against a log and cross-check its verdict with its exit code. |

**`headless_render`'s `ok` is only the script's exit code.** A run can exit 0 and still never have reached
`LOGGED_IN`, have drawn nothing, or have logged exceptions. Read `gameStateProgression`, `nullGraphics`,
`exceptionLines` and `lastFrame` before trusting a run, and look at the frame.

## Symptoms

| Symptom | Usual cause | What to do |
|---|---|---|
| iOS: the app hangs at launch | No JIT. The app waits for the StikDebug attach by design. | Connect LocalDevVPN, attach StikDebug with the JIT script. See [ios/app/stikdebug/README.md](../../ios/app/stikdebug/README.md). |
| iOS: StikDebug's "Starting JIT" spinner never resolves | The developer disk image mount, which happens before the JIT script runs | Not an app problem. Check the VPN; iOS runs one VPN at a time, so SideStore's VPN must be off. |
| Black screen, `js5connect_outofdate` in the log | OSRS updated and the build's game data is stale | Merge upstream RuneLite and re-stage both ports; see [upstream-release.md](upstream-release.md). |
| GPU or 117 HD was selected but the app came up on CPU, with an alert or toast | The crash cookie: the last GPU boot never presented a frame | Read the previous launch's log (`*.prev` on iOS, `files/gpu-fail.txt` on Android). Re-select the renderer in the plugin panel to try again. |
| Android: launched with the screen off, `[boot] poll ... draws=0` forever and `render paused (backgrounded)`; the next launch is on CPU | No surface means no frames, so the GPU watchdog ran out and left the cookie armed | Wake the screen first (`adb shell input keyevent KEYCODE_WAKEUP`), remove the stale cookie (`adb shell run-as dev.audaro.runemobile rm -f files/auto-gpu-armed`), and re-select the renderer if it was reverted. |
| Simulator, first launch: tens of seconds of `draws=0` | The game cache is downloading | Wait. Not a hang. |
| Simulator, 117 HD: the first entry into the world freezes for minutes, then `CONNECTION_LOST` and a reconnect | 117 HD compiling its scene shaders on Apple's software renderer | Expected in the Simulator only. Not a phone performance signal. |
| 117 HD: the whole scene is dark with no sun shadows | A shadow-map depth texture was rejected, so every lookup reads "in shadow" | Look for `[shadowmap]` (Android) or `SHADOW-FIX` (iOS); see [renderers.md](renderers.md#platform-limits-and-the-fixes-for-them). |
| Shader errors in the log, but the app reached the login screen | Most programs compile lazily, and a failed compile is not fatal | Run `tools/shader-matrix/run-matrix.sh` for the port; reaching `LOGIN_SCREEN` proves nothing about shaders. |
| Android only: one-frame geometry glitches in GPU or 117 HD | Usually an Android bridge entry point missing a fix iOS already has | Diff `librlawt.cpp` against the iOS bridges; record the screen and score every frame ([renderers.md](renderers.md#the-android-gl-bridge-lags-ios)). |
| A frozen HUD element, dead taps or a missing panel after an upstream merge | A changed widget id, interface or method; look for `[bridge-fault]` | Read the fault's stack. Run both bridge censuses and the contract check. |
| A change shows up on one port and not the other | That port is running an old jar or an old native library | Re-stage both ports after a `headless/` change; on Android force-stop after installing, and rebuild native code with `--rerun-tasks`. `tools/port-drift/port-drift.py` lists where the two ports' sources differ. |
| Android: CPU renderer fps far lower than yesterday | Thermal throttling, or charging | Check `adb shell dumpsys thermalservice` and the CPU frequency caps before calling a regression. |
| Android: a 117 HD setting changed with `SET_HD_CONFIG` is gone after a restart | Live flips reach disk only on RuneLite's periodic config save; a force-stop before it loses them. Day/night is also re-forced off every launch. | Wait for the save, or set the value in the plugin panel. Verify on disk with `run-as`. |
| A session drop ends on "Session expired" although the session was still valid | Reconnect retries ran out while the network was still down (the JVM caches a failed host lookup for about 10 s) | Retries now back off over a few minutes. Reproduce with the network cut below. |
| All Simulator golden screenshots fail by the same percentage | The Simulator window faces the other landscape direction | Goldens are kept per facing; rotate the window (Device → Rotate Left) or record goldens for that facing. |
| Residency log says "0MB free" in the Simulator | The Simulator has no memory cap, so the available-memory call returns 0 | Ignore it in the Simulator. |

## Network and login

### Login

The game client never sees a password. The in-app **Log in with Jagex** flow runs Jagex's OAuth sign-in and stores
the resulting session in the app's private storage. At the next start the shell exports it as the `JX_*`
environment variables the official launcher would set, which the game reads when the VM is created. Two parts of
the flow look like bugs but are platform limits:

- **A restart follows a fresh login.** The variables are read once, at VM creation. On iOS there is a second
  reason: the sign-in page uses WebKit, which cannot be unloaded from a process, and the JVM cannot start cleanly
  next to it. The saved session means the restarted app goes straight to play.
- **Android signs in through a Chrome Custom Tab**, because the embedded WebView does not get through the sign-in
  page's bot check, and the sign-in only redirects to a bare `http://localhost/...` link that cannot be routed back
  into the app. You copy that link, and the app reads it from the clipboard (with a paste field as a fallback).

For login problems on Android read the `JagexLogin` and `JagexTokens` tags; on iOS the `[login]` lines in
`hello-shell.log`. The desktop harness logs in from `tokens.json` instead, by mapping it to the launcher environment
variables the game reads (`JX_*`); see [setup.md](setup.md).

### Disconnects and reconnects

After a connection drop the client re-logs in by itself: it clicks through the game's own login screens with a
bounded, backing-off number of attempts, and shows a "session expired" card if it cannot get back in. To reproduce
a drop on Android without losing `adb`, cut only the app's network (supported by `cmd connectivity` on recent Android
versions):

```sh
PKG=dev.audaro.runemobile
adb shell cmd connectivity set-chain3-enabled true
adb shell cmd connectivity set-package-networking-enabled false $PKG
# ... wait for CONNECTION_LOST in the log, then restore:
adb shell cmd connectivity set-package-networking-enabled true $PKG
adb shell cmd connectivity set-chain3-enabled false
```

Run the restore even if the test is interrupted (in a script, put it in a `trap ... EXIT`). Debug builds also accept
broadcasts that force the reconnect overlay on or off for screenshots:

```sh
adb shell am broadcast -a dev.audaro.runemobile.SET_RECONNECT_OVERLAY --es show on    # on | off | clear
```

## Getting help

If you are stuck, open a [discussion](https://github.com/audaro/runemobile/discussions) for questions, or an issue
for something clearly broken. As [CONTRIBUTING.md](../../CONTRIBUTING.md) asks, include:

- the port (iOS or Android), the device and OS version, and the renderer;
- the build: the release tag, or the commit you built from;
- what happened, what you expected, and how to reproduce it;
- the relevant log excerpt, **redacted**: remove tokens, session IDs, display names and private chat (`client.log`
  and a HUD snapshot dump can contain all of them).

Report a security problem privately through the repository's security advisories, not in a public issue.

## See also

- [setup.md](setup.md): getting a working build and the desktop harness.
- [renderers.md](renderers.md): renderer choice, the crash cookie, shaders and performance measurement.
- [testing-qa.md](testing-qa.md): the gates and what each one proves.
- [gotchas.md](gotchas.md): traps that cost time.
- [ios.md](ios.md) and [android.md](android.md): each port's build, install and layout.
- [tools/log-scan/README.md](../../tools/log-scan/README.md), [tools/mcp/README.md](../../tools/mcp/README.md),
  [ios/dev-tools/headless/README.md](../../ios/dev-tools/headless/README.md)
