# Testing and QA

RuneMobile has no single test command. It has a ladder of checks, from hooks that finish in seconds to a
manual session on a real phone, and each rung answers a question the rungs below it cannot. This page walks
the ladder from the fastest and narrowest check to the slowest and broadest, says what each one proves, and
ends with a table of what to run for which kind of change.

Most of these checks run on a Mac with no phone attached. Run the cheap rungs first and climb only as far as
the change needs: a failure low on the ladder is quicker to read and cheaper to fix.

## The ladder at a glance

| Check | What it answers | When to run | Time | Verdict / exit | Command |
|---|---|---|---|---|---|
| Pre-commit hooks | Is anything secret, ignored or misattributed staged? Did the cross-port contract change without being acknowledged? | Every commit (automatic) | Seconds | Exit 1 blocks the commit | `tools/git-hooks/install.sh` once |
| Bridge unit tests | Does the bridge's Java still emit the shapes and timing the ports rely on? | Any change under `headless/` | Minutes | Gradle pass/fail | `./gradlew :client:test --tests 'net.runelite.client.headless.*'` |
| Contract checks | Did a public static the ports call change? Do the three OAuth implementations agree? Is the plugin-hub pin reviewed? | Bridge, login or version changes | Seconds | 0 clean; see [below](#3-contract-checks) | `tools/shared-contract/check-contract.sh` |
| Bridge censuses | Does every JNI lookup each port makes resolve in the jars it ships? | Bridge or native lookup changes | Under a minute (Android), ~20 s plus a build (iOS) | `*_BRIDGE_CENSUS_GREEN` | `run-census-desktop.sh`, `run-census-sim.sh` |
| Desktop headless harness | Does real RuneLite boot, log in and draw the HUD correctly with the bridge in it? | Behaviour changes in the bridge, overlays, HUD | 45 s to ~3 min | `VERDICT: GREEN`, exit 0 | `ios/dev-tools/headless/run-*.sh` |
| Harness MCP server | The same harnesses, callable as tools with parsed results | Whenever you drive the harnesses repeatedly | As the harness | JSON per tool | `tools/mcp/harness_server.py` |
| iOS Simulator | Do the native screens, plugin panels and each renderer still work? | iOS native UI, release, upstream merge | ~10 s to ~10 min | `SIM_GATE_GREEN` and friends | `ios/dev-tools/sim-gate.sh` |
| Shader matrix | Do the 117 HD shaders compile for each port's GL after rewriting? | Shader, RLHD or downport changes | Minutes | `SHADER_MATRIX_GREEN` | `tools/shader-matrix/run-matrix.sh ios` |
| Log scan | Did a launch log anything not on the known-noise list? | After any device or simulator launch you want to trust | Seconds | `LOG_SCAN_GREEN` | `tools/log-scan/log-scan.py --sim LOG` |
| Port drift | Where do the two ports' JVM options, bridge bindings and RLHD overrides differ? | Before porting a fix across, after a merge | Seconds | A report, exit 0 | `tools/port-drift/port-drift.py` |
| Release gate | The whole Android gate in one verdict | Before calling a bridge change done; before a release | Seconds to a long build | `GATE PASS`, exit 0 | `android/dev-tools/ci/release-gate.sh` |
| Android harnesses | Does a specific Android seam work on a device or emulator? | Android shell changes | Minutes | Per-script verdict | `android/dev-tools/a*/check-*.sh` |
| Device QA | Does it work in your hand? | Before you say a change works | As long as it takes | You | Manual |

## 1. Pre-commit hooks

The hooks live in `tools/git-hooks/` and are enabled per clone with:

```sh
tools/git-hooks/install.sh          # sets core.hooksPath=tools/git-hooks
git config core.hooksPath           # should print tools/git-hooks
```

`pre-commit` runs in stages and blocks the commit (exit 1) at the first one that fails:

- **Hygiene.** It refuses staged token files (`tokens.json`, `legacy_login.json`), keystores and
  `keystore.properties`, the generated `ios/app/jvm-resources/probes.jar`, private-key material, and any file
  that is git-ignored but was force-added. It scans added lines against the attribution denylist (skipped while
  a merge is in progress). If they are installed, it also runs gitleaks, shellcheck on staged `.sh` files,
  ktlint on staged Android Kotlin, and an incremental clang-format check on changed native lines.
- **Auth contract.** When a staged file is one of the three OAuth implementations or the contract itself, it
  runs `tools/shared-contract/check-auth-contract.sh`.
- **Bridge API reference.** When a staged file is a bridge source or the generator, it checks that
  [`bridge-api-reference.md`](bridge-api-reference.md) still matches what the sources generate.
- **Cross-port contract.** When a staged file lands in the jars both ports embed (`runelite-client/`,
  `ios/dev-tools/awtsmoke/`, `tools/stage-*.sh`), it runs `check-contract.sh`. Any change blocks the commit
  unless the refreshed `tools/shared-contract/baseline.txt` is staged with it.

`commit-msg` scans the message with the same attribution scan.

The denylist is kept outside the repo, at `~/.config/rune-mobile/attribution-denylist` (override with
`RUNEMOBILE_ATTRIBUTION_DENYLIST`). A missing list only prints a notice; a list that exists but can't be read,
or holds a bad pattern, blocks the commit. On a new machine, check that the list exists.

`git commit --no-verify` bypasses everything. Treat it as an emergency exit, not a workflow: the release gate
re-runs the contract stages and will fail later instead.

See [CONTRIBUTING.md](../../CONTRIBUTING.md) for the linters and the hook setup.

## 2. Bridge unit tests

The bridge's own tests live in `runelite-client/src/test/java/net/runelite/client/headless/` (JUnit 4,
hamcrest, mockito). They don't boot the engine: where a test needs the client, it mocks it, so the suite runs in
the normal Gradle test task. They cover what the contract check structurally cannot see: not the method shapes, but the bytes and
timing those methods produce. Among other things they pin down:

- the JSON a snapshot publishes (menu peek, HUD data, the Grand Exchange and XP tracker panels);
- the log-line shapes the harness and `fps-measure.sh` parse (`FrameStats`);
- input timing: key and press timing, the pointer stream, the text-input kind;
- frame double-buffering and the GPU warm-up hold;
- the login state machine's give-up and reconnect latches;
- what the layout switch is allowed to press.

```sh
./gradlew :client:test --tests 'net.runelite.client.headless.*'
```

Two traps when you edit the bridge:

- **Reflection.** Several tests reach private fields and helpers by name (for example
  `GrandExchangeBridgeTest` calls private static parsers, and other tests read private queues and state).
  Rename one and update the test in the same change; otherwise it fails as "reflective call ... failed",
  which looks like a test bug rather than a rename.
- **Gate flags.** The bridge reads its `-Drunelite.*` flags once, when a class loads. A test that needs a flag
  sets it in a static initialiser before the class under test is touched. Static state is shared between tests
  in the same JVM, so a test that passes alone can fail after another one ran first.

## 3. Contract checks

Three small scripts in `tools/shared-contract/` guard what neither compiler can see. See its
[README](../../tools/shared-contract/README.md).

```sh
tools/shared-contract/check-contract.sh         # the public statics both ports resolve by name
tools/shared-contract/check-auth-contract.sh    # the Jagex OAuth values the three logins share
tools/shared-contract/check-hub-pin.sh          # the RuneLite api/plugin-hub version pins
```

| Script | 0 | 1 | 2 | 3 |
|---|---|---|---|---|
| `check-contract.sh` | unchanged | additive only | an entry was removed or changed | no baseline yet |
| `check-auth-contract.sh` | clean | — | a pinned value drifted | — |
| `check-hub-pin.sh` | OK | needs review | — | — |

For `check-contract.sh`, an additive change is safe for the other port (it simply doesn't call the new member
yet). A removed or changed entry can break the other port at runtime, silently. Verify both ports (the
censuses below), then acknowledge the new contract with `check-contract.sh --update` and stage
`baseline.txt` (and the reference page it regenerates) in the same commit.

The contract covers method signatures only. A changed JSON key inside a published snapshot passes it cleanly
and still breaks the other port's parser. That is what the unit tests in rung 2 are for.

`check-hub-pin.sh` fails when `project.build.version` in `gradle.properties` moves past the version recorded
as reviewed in `tools/shared-contract/hub-pin.ack`. The ledger's header explains how to review and move the pin.
[upstream-release.md](upstream-release.md) covers it in the merge procedure.

## 4. Bridge censuses

The contract check compares signatures with a baseline. The censuses go further: they resolve every lookup
against compiled jars in a running JVM. The Android census loads the shaded client jar that the Android jars are
built from; the iOS census runs the iOS app's own jars, inside the app's own VM, in the Simulator.

**Android, on the desktop:**

```sh
android/dev-tools/bridge-census/run-census-desktop.sh            # expect ANDROID_BRIDGE_CENSUS_GREEN
android/dev-tools/bridge-census/run-census-desktop.sh path/to.jar
```

It defaults to the shaded jar of the current version under `runelite-client/build/libs/`, falling back to
`ios/app/jvm-resources/client-shaded.jar`. It exits 0 on GREEN, 1 on RED and 2 when the jar or `javac` is
missing. Its list of expected lookups is kept by hand in `BridgeCensus.java`, so it can miss a lookup someone
added to the native code without adding it there. See its [README](../../android/dev-tools/bridge-census/README.md).

**iOS, in the Simulator:**

```sh
ios/dev-tools/bridge-census/run-census-sim.sh --jars     # after a Java change: restage the jars first
ios/dev-tools/bridge-census/run-census-sim.sh --no-build # reuse the last simulator build
```

Its list comes from the native source itself (`extract-lookups.py`), so a lookup added to `JVMLauncher.m` is
checked from the next run on. The app runs the census inside its own VM once the client has drawn a frame,
logged out, on the CPU renderer (every renderer has the same classpath). It prints
`VERDICT: IOS_BRIDGE_CENSUS_GREEN` and exits 0, or `_RED` and exits 1. Output lands in `build/bridge-census/`.
See its [README](../../ios/dev-tools/bridge-census/README.md).

Neither census covers `RegisterNatives` tables (the GPU bridge registers its GL natives that way; a GPU launch
logs `RouteC_registerGLNatives rc=`), and neither checks behaviour.

## 5. Desktop headless harness

The harness boots real RuneLite, with the bridge in it, on desktop OpenJDK 21 under the same Caciocavallo
toolkit the ports use, and captures the engine's frames to PNG. It is the fastest way to see the bridge
behave without a device. Develop on the desktop first; deploy once it passes here.

```sh
./gradlew :client:shadowJar                                   # rebuild after EVERY bridge edit
bash ios/dev-tools/headless/run-headless-cacio.sh             # boot to the login screen, no OS window
bash ios/dev-tools/headless/run-headless-login-cacio.sh       # autologin into the game
```

The scripts build the shaded jar only when it is missing, so a stale jar is the most common false result:
rebuild it yourself after every edit. They read the version from `gradle.properties`, use a JDK 21 (Homebrew
`openjdk@21` by default; set `JAVA_HOME` to override), and wipe their output directory (`out/`, `out-login/`,
...) at the start of each run. Copy any frame you want to keep before the next run.

The `run-*.sh` probes each drive one feature (the chat veneer, HUD isolation, the minimap, the layout switch,
the menu peek, ...), and most pair with a `*-verdict.sh` that reads the log. The verdict scripts share their
exit codes:

| Exit | Meaning |
|---|---|
| 0 | GREEN |
| 1 | the log is missing (some scripts also use 1 for RED) |
| 2 | the probe never emitted |
| 3 | inconclusive |
| 4 | RED |

Every verdict is computed in bash from the markers the run printed, never from a success line the JVM prints
about itself. Keep it that way when you add one: a JVM that dies early must not be able to print GREEN. See the
harness [README](../../ios/dev-tools/headless/README.md) for each probe.

### Before you trust a capture

A run that exits 0 is not necessarily a run that worked. Check the log and the frames:

- frames were captured, and none came from a null `Graphics`;
- no exception or `ERROR` lines in the JVM log;
- the log shows the game state you expected. `LOGIN_SCREEN -> LOGGING_IN -> LOGIN_SCREEN` is a rejected login,
  usually expired tokens (see [Accounts](#15-accounts));
- overlays composite only once the client is `LOGGED_IN`, so a login-screen run can't show them.

A login-screen run takes about 45 s (`RUN_SECONDS`). An in-game run needs about two minutes. There are no
golden frames in the repo; to compare two renders, crop to the region you care about and diff with a threshold
(the harness MCP server's `image_diff` does this).

The character's position comes from the server, not from the tokens: log the throwaway account out standing
where you want to test.

### Keep your real RuneLite profile out of it

The harness runs the real client, which reads and writes `~/.runelite`. A probe that changes config (the HUD
veneer releasing an overlay it owned, for example) changes your desktop profile, and saved overlay positions
from that profile leak into the renders. Run against a scratch home instead:

```sh
mkdir -p "$SCRATCH/rlhome/.runelite"
ln -s "$HOME/.runelite/jagexcache" "$SCRATCH/rlhome/.runelite/jagexcache"   # reuse the game cache
cp "$HOME/.runelite/random.dat" "$HOME/.runelite/jagex_cl_oldschool_LIVE.dat" "$SCRATCH/rlhome/.runelite/"
JAVA_TOOL_OPTIONS="-Duser.home=$SCRATCH/rlhome" bash ios/dev-tools/headless/run-headless-login-cacio.sh
```

RuneLite resolves its directory from `user.home` (`RuneLite.RUNELITE_DIR`), so everything else it writes lands
in the scratch home. Note an md5 of your real profile files before the first run if you want proof afterwards
that nothing touched them.

### Reading widgets on the desktop

To inspect the engine's widget tree (ids, bounds, hidden flags) without a device, write a throwaway main in a
scratch directory, outside the repo:

1. Start `DeviceHeadlessBoot.main` (`ios/dev-tools/awtsmoke/DeviceHeadlessBoot.java`) on a daemon thread.
2. Run with `-Drunelite.bridge=true`, or the bridge never captures the client and its client thread.
3. Read `JavaBridge`'s private `client` and `clientThread` fields by reflection, wait until
   `JavaBridge.cameraZoom()` returns a value of 0 or more (the client is live), then
   `clientThread.invoke(...)` your dump. Widgets may only be read on the client thread.
4. Compile against the shaded jar plus the Cacio jars the harness uses.

Expect the login to take about a minute before the dump has a world to read.

### Tiers: what the desktop can and can't test

It helps to tag each check you plan by what it needs:

- **[L] no account.** Works at the login screen. The largest group, and the cheapest.
- **[A] any logged-in account.** Needs autologin with a throwaway account's tokens.
- **[B] an account that can reach a bank or the Grand Exchange.** A fresh tutorial-island account can't.
- **[D] device only.** Real touch, JIT, the phone's GPU driver, thermals, backgrounding. Not testable here.

Some [A] probes change the account: `run-layout-switch.sh` switches the game's display layout and always ends
on Resizable - Modern. Know what a probe writes before you point it at an account.

### Desktop reference

`ios/dev-tools/run-desktop-reference.sh` launches the fork's normal desktop RuneLite with its usual window, as
ground truth for "is this an engine behaviour or ours?"

## 6. The harness MCP server

`tools/mcp/harness_server.py` is a small stdio [MCP](https://modelcontextprotocol.io) server that exposes the
harnesses as callable tools with parsed, structured results: `headless_render`, `image_diff`, `run_verdict`,
`android_fps`, `ios_sim_census`, `ios_sim_screens` and more. It runs under `/usr/bin/python3`, because
`image_diff` and the simulator screenshot tools need Pillow and numpy. It is registered by a gitignored
`.mcp.json` at the repo root (an example is in its [README](../../tools/mcp/README.md)).

Two things to know:

- `headless_render`'s `ok` is only the script's exit code, and the scripts exit 0 even when Java dies. Gate on
  the markers it returns (`frameCount`, `nullGraphics`, `exceptionLines`, `errorLines`, a non-null `jvmLog`),
  not on `ok`.
- `run_verdict` returns the verdict from the script's last `VERDICT:` line and a `consistent` flag that
  cross-checks it against the exit code. Treat `consistent: false` as a broken verdict script.

Its parsers have tests:

```sh
/usr/bin/python3 -m unittest discover -s tools/mcp -p 'test_*.py'
```

## 7. iOS Simulator

The full iOS app runs in the Simulator on an Apple silicon Mac, with the JIT and no StikDebug: the simulator
build services HotSpot's code-cache breakpoint itself. It is the right place for native UI and feature work.
[ios.md](ios.md) and [ios/README.md](../../ios/README.md#run-in-the-ios-simulator-no-phone) cover setup.

```sh
ios/dev-tools/run-sim.sh                    # build, install, launch, press Play (CPU)
RENDERER=117hd ios/dev-tools/run-sim.sh     # cpu | gpu | 117hd
ios/dev-tools/run-sim.sh --jars             # restage the jars first, after a Java change
ios/dev-tools/run-sim.sh --desktop-login    # log in with the desktop harness's session (--logout undoes it)
```

`SIM_NAME` (or `SIM_UDID`) picks the simulator. On a fresh install the game cache downloads before the first
frame, so the first launch draws nothing for a while. That is not a hang.

### Screens

```sh
/usr/bin/python3 ios/dev-tools/sim-screens/sim-screens.py            # expect SIM_SCREENS_GREEN
/usr/bin/python3 ios/dev-tools/sim-screens/sim-screens.py settings plugins
/usr/bin/python3 ios/dev-tools/sim-screens/sim-screens.py --update   # write new goldens
```

It launches the app logged out with the game picture covered, opens each screen in `screens.json` through the
same entry point as its button, and compares a screenshot with a golden. Goldens are kept per Mac, per simulator
model and per way the window faces (`LandscapeLeft` or `LandscapeRight`), under `ios/app/evidence/sim-golden/`,
outside git. On a new Mac every screen reports `NO_GOLDEN`: look at the shots in
`ios/app/evidence/sim-screens/<stamp>/` by eye first, then write them with `--update`. Do the same after a UI change
you meant to make. The `hub` screen needs the network and runs only when named.

The Simulator window must be in landscape (turn it once with Device > Rotate Left), and it can come back facing
the other landscape way. If every screen fails by about the same share of pixels, the window has turned, not
the UI: the Dynamic Island moved with it. See its [README](../../ios/dev-tools/sim-screens/README.md).

### Plugin sweep

```sh
/usr/bin/python3 ios/dev-tools/sim-screens/plugin-sweep.py            # expect PLUGIN_SWEEP_GREEN
/usr/bin/python3 ios/dev-tools/sim-screens/plugin-sweep.py --only panels
```

No goldens: it opens every plugin's settings screen and every side panel, and fails one that doesn't open,
shows nothing, logs a bridge or JSON fault, or shows a config group twice. It switches on what it needs to reach
hidden panels and puts the profile back at the end. It earns its time: it is how a plugin whose only setting is
hidden (Notes) was found to get a settings screen holding nothing but "Reset all settings", which wiped the notes
(see [gotchas.md](gotchas.md#a-plugin-settings-screen-must-show-something)).

### The simulator gate

```sh
ios/dev-tools/sim-gate.sh                       # expect VERDICT: SIM_GATE_GREEN, ~10 min
ios/dev-tools/sim-gate.sh --jars                # restage the jars first
ios/dev-tools/sim-gate.sh --skip sweep          # skip any of: census,screens,sweep,renderers
RENDERERS="cpu gpu" ios/dev-tools/sim-gate.sh
```

It builds once, then runs the census, the screens, the sweep, a boot of each renderer to the login screen
(surviving `DWELL` seconds there), and the log scan over every launch, which must find no shader errors. Every
launch is logged out. It exits 0 on GREEN, 1 on RED and 2 on bad arguments, and keeps every step's log under
`build/sim-gate/<stamp>/`. Run it before a release, after an upstream merge, and after any shader or renderer
change. See its [README](../../ios/dev-tools/sim-gate/README.md).

### What the simulator can't tell you

Performance, the StikDebug JIT path, the phone's GPU driver (GPU modes draw with Apple's software renderer),
real multi-touch, and background or picture-in-picture behaviour. On 117 HD the first entry into the world
freezes for a minute or more while shaders compile, and the connection drops and reconnects once; that is the
simulator. Reaching the login screen proves at most that the shaders compiled, not that they draw correctly.

## 8. Shader matrix

The 117 HD shaders are written for desktop GL and rewritten for each port's GL ES at load time. The matrix
dumps them with the real RLHD sources, applies each port's rewrite rules (read from the port's own source), and
validates every variant with `glslangValidator`:

```sh
tools/shader-matrix/run-matrix.sh ios        # expect SHADER_MATRIX_GREEN (ios, <n> variants)
tools/shader-matrix/run-matrix.sh android
```

It needs `glslangValidator`, a JDK 21, `/usr/bin/python3`, and the work directory a previous run of the port's
RLHD stager left behind. RED exits 1; a usage error exits 2. Run it for both ports after any change to shaders,
the shader overlays or a downport rule, and after an upstream or RLHD bump. See its
[README](../../tools/shader-matrix/README.md) and [renderers.md](renderers.md).

## 9. Log scan

`tools/log-scan/` reads a launch's logs and reports every error-shaped block that isn't on its known-noise list:

```sh
tools/log-scan/log-scan.py --sim <Documents>/jvm-stdio.log --sim <Documents>/hello-shell.log
tools/log-scan/log-scan.py --phone ios/app/evidence/device-pull/<stamp>/jvm-stdio.log
adb logcat -d -v threadtime -s 'jvm-stdout:*' > pixel.txt && tools/log-scan/log-scan.py --android pixel.txt
tools/log-scan/log-scan.py --desktop ios/dev-tools/headless/out/run-cacio.log
```

Each source flag takes a log file and can repeat; any mix of sources works in one run. `--suggest` prints a
draft noise entry under each new signature, and `--json FILE` writes the whole result. It prints
`VERDICT: LOG_SCAN_GREEN` (exit 0) or `_RED` (exit 1, or 2 when an input is missing, empty or the wrong kind of
log). Every entry in `known-noise.json` must say why it is harmless (`reason` is required), and shader errors can
never be excused. A Release Android build sends almost nothing to logcat, so scan a Debug build.
`sim-gate.sh` runs the scan over every launch it makes. See its [README](../../tools/log-scan/README.md).

## 10. Port drift

The two ports reimplement the same host in different languages, so they drift.
`tools/port-drift/port-drift.py` compares their JVM options, their bridge bindings and their RLHD overrides, and
writes a report. It is a report, not a verdict: it exits 0, or 2 when an input is missing or the source has a
shape it doesn't handle.

```sh
tools/port-drift/port-drift.py
tools/port-drift/port-drift.py --ios-log hello-shell.log --android-log jvm-boot.log
```

Read it before porting a fix from one port to the other, and after a merge. It does not cover `RegisterNatives`
tables. See its [README](../../tools/port-drift/README.md).

## 11. Release gate

`android/dev-tools/ci/release-gate.sh` is the one runnable gate. It names the stage that failed and exits non-zero.

```sh
android/dev-tools/ci/release-gate.sh --contract-only      # the contract stages only (what CI runs)
android/dev-tools/ci/release-gate.sh --skip-build         # everything except the release build and signing
android/dev-tools/ci/release-gate.sh                      # the full gate
android/dev-tools/ci/release-gate.sh --with-device-smoke  # plus a Firebase Test Lab boot smoke
```

In order, it runs:

1. the cross-port contract (a removed or changed entry fails; an additive one passes) and the bridge API
   reference freshness check;
2. the auth contract;
3. the hub-pin review (`--contract-only` stops here);
4. shellcheck, ktlint and detekt (each is required here, not optional);
5. the bridge unit tests;
6. `:app:assembleRelease` and the signing check (skipped by `--skip-build`);
7. `:app:lintRelease`;
8. the opt-in device smoke.

Run `--skip-build` before calling a shared-bridge change done, together with both censuses. Run the full gate
before a release. The hosted release workflow runs only `--contract-only`, so the rest is yours to run. See
[RELEASE.md](../../RELEASE.md) for the pre-publish checklist and [upstream-release.md](upstream-release.md).

## 12. Android harnesses and device farms

`android/dev-tools/` holds a harness per Android milestone. Each is a script that drives a device or emulator
over adb and prints a verdict; most need a Debug build. Read the README before running one.

| Directory | Script | Checks |
|---|---|---|
| [`a0-login`](../../android/dev-tools/a0-login/README.md) | `check-loggedin.sh` | autologin to `LOGGED_IN` from a pushed `tokens.json` + `autologin.mode` marker (debug builds) |
| [`a1-input`](../../android/dev-tools/a1-input/README.md) | `check-input.sh` | input parity with the bridge |
| [`a1b-gatecensus`](../../android/dev-tools/a1b-gatecensus/README.md) | `check-gates.sh` | the bridge gates resolve on device (`ANDROID_GATE_CENSUS_GREEN`) |
| [`a2-menupeek`](../../android/dev-tools/a2-menupeek/README.md) | `check-menupeek.sh` | the long-press menu |
| [`a3-login`](../../android/dev-tools/a3-login/README.md) | `set-legacy-login.sh` | the on-device Jagex login |
| [`a4-pluginplane`](../../android/dev-tools/a4-pluginplane/README.md) | `check-a4seam.sh` | the plugin config plane |
| [`a5-panels`](../../android/dev-tools/a5-panels/README.md), [`a5-tier2`](../../android/dev-tools/a5-tier2/README.md) | `check-a5.sh`, `check-a5-tier2.sh` | plugin side panels |
| [`a6-chrome`](../../android/dev-tools/a6-chrome/README.md) | `check-a6seam.sh`, `check-a6ui.sh` | the native HUD chrome |
| [`gpu`](../../android/dev-tools/gpu/README.md) | `check-ag1a.sh`, `fps-measure.sh` | the GPU smoke, frame-rate capture |

For devices you don't own, [`firebase/`](../../android/dev-tools/firebase/README.md) runs a boot smoke on
Firebase Test Lab (`fb-gate.sh`, the release gate's opt-in stage) and [`browserstack/`](../../android/dev-tools/browserstack/README.md)
runs the same md5-gated checks on BrowserStack App Automate. Both need your own account and credentials, kept
outside the repo. The free Firebase plan allows only a few runs a day, so don't loop on it.

## 13. Device QA

Everything above is evidence. The phone is the answer. A compile, a staged jar or a push is not "on the phone":
the change is on the phone when you've installed it, launched it, and watched it work. On Android, force-stop the
app after installing (`adb shell am force-stop dev.audaro.runemobile`) and launch it fresh, so you know the process
you're testing started from the new APK.
[ios.md](ios.md) and [android.md](android.md) cover install and launch.

### What only a device shows

Performance and thermals, the JIT path (on iOS, the StikDebug attach), the phone's own GPU driver, real
multi-touch, haptics, and what happens when the app goes to the background and comes back. None of the rungs
above can answer for those.

### Smoke checklist

Run this after any change that reaches the device, on each port the change touches:

- [ ] **Boot.** The app launches (on iOS: LocalDevVPN connected, StikDebug attached, `[rl-jit]` lines in
      StikDebug's log) and the login screen draws.
- [ ] **Login.** The throwaway account logs in and reaches the world.
- [ ] **World.** Tap to walk; long-press opens the menu and an option fires; a one-finger drag turns the camera;
      pinch zooms. The inventory, equipment and prayer tabs open and their items respond.
- [ ] **Renderer switch.** Switch to each renderer you touched (CPU, GPU, 117 HD), relaunch, and check it draws.
- [ ] **Plugin panel.** Settings and the plugin list open; a plugin's side panel opens; a setting you change
      sticks across a relaunch.
- [ ] **Chat and dialogue.** The keyboard types into the chat; an NPC dialogue continues, and its options answer.
- [ ] **Bank and Grand Exchange.** Both open; the GE item search takes typing and a result can be picked.
- [ ] **World map.** It opens full screen, the HUD doesn't paint over it, and a long-press menu on it opens
      under the finger.
- [ ] **Background and foreground.** Leave the app and come back. On Android the session may drop and log back
      in; that is expected.
- [ ] **Reconnect.** After a dropped connection the app logs itself back in (you'll see the login screen flash
      by), or shows the "session expired" card when it can't.
- [ ] A log scan of the launch is GREEN.

Then exercise the change itself, on the screen and in the situation where it matters. A bank or GE check needs
an account that can reach one; a fresh tutorial-island account can't.

### Performance tools

| Tool | What it does |
|---|---|
| `tools/perfprobe.sh android\|ios on\|off\|status` | arms the frame and memory probes for the next launch; `marker NAME VALUE` sets a one-off marker |
| `android/dev-tools/gpu/fps-measure.sh [-s SERIAL] [-d SECONDS]` | captures fps, frame pacing, GC, thermal and GPU time from logcat; `--from-file LOG` parses a saved log, including the desktop harness's |
| `ios/dev-tools/residency.py` | summarises why each iOS session ended, from logs pulled off the phone |

For a desktop frame-rate baseline, run the harness with the probe on and parse its log the same way:

```sh
RUN_SECONDS=35 JAVA_TOOL_OPTIONS=-Drunelite.fpsprobe=true bash ios/dev-tools/headless/run-headless.sh
android/dev-tools/gpu/fps-measure.sh --from-file ios/dev-tools/headless/out/run-native.log
```

Phone frame rates are thermal. The same build can run at a fraction of its cool frame rate when the phone is
hot or charging, so check the thermal state (on Android, `adb shell dumpsys thermalservice`) before you call a
slowdown a regression. [debugging.md](debugging.md) covers pulling logs off each device.

## 14. What to run for which change

| You changed | Run at least |
|---|---|
| Docs only | Nothing beyond the hooks (docs-only pushes don't build a release) |
| Bridge Java (`headless/`) | Unit tests, `check-contract.sh`, both censuses, `release-gate.sh --skip-build`, the harness probe for the behaviour |
| A published snapshot's JSON | All of the above; the contract check won't see it, so the unit tests and both ports' parsers must |
| A native JNI lookup (iOS `.m`, Android `.cpp`/`.kt`) | That port's census; the device |
| iOS native UI | `sim-screens.py`, `plugin-sweep.py` if plugin UI is involved, the device for touch |
| Android shell (Kotlin) | `release-gate.sh --skip-build` (ktlint, detekt, lint), the matching `a*` harness, the device |
| Overlays or the HUD veneer | The headless probes for the HUD (`run-hud-isolation.sh`, `run-edge2edge.sh`, `run-hud-data.sh`, ...), the simulator, both devices |
| Shaders, shader overlays, downport rules, RLHD Java overrides | `run-matrix.sh ios` and `android`, `sim-gate.sh`, both devices on 117 HD |
| Login or OAuth code | The auth contract (the hook runs it), a real login on each port touched |
| A staging script | `tools/stage-mobile-runtime.sh --check`; the iOS build's staged-jar check; both censuses |
| An upstream merge | Hub pin, contract, unit tests, both censuses, shader matrix, `sim-gate.sh`, port drift, a device smoke on both ports |
| A release | The full `release-gate.sh`, `sim-gate.sh`, the shader matrix, and the checklist in [RELEASE.md](../../RELEASE.md) |

## 15. Accounts

Use a **throwaway Jagex account**, never a main. A self-built client is not on Jagex's approved-client list,
so any account you log in with risks a ban; see the risk section of the [README](../../README.md).

There are three separate token stores, and they never sync:

| Where | Holds | Comes from |
|---|---|---|
| The desktop harness | `ios/dev-tools/tokens.json` (gitignored) | `ios/dev-tools/fetch-shield-tokens.sh`, run interactively |
| The phone | the app's private storage | the in-app login on that phone |
| The iOS Simulator | the session ID and chosen character only | `run-sim.sh --desktop-login`, copied from the desktop harness's tokens |

The harness scripts read `TOKENS` (default `ios/dev-tools/tokens.json`). On Android, a Debug build also accepts
a `tokens.json` pushed to the app's external files directory; a release build keeps tokens internal only.

Tokens expire. When an in-game run bounces from `LOGGING_IN` back to the login screen, mint new ones. If a
freshly minted file still bounces, the launcher's access and refresh tokens are the usual cause: run with a copy
of `tokens.json` that has `access_token` and `refresh_token` blanked (`TOKENS=path/to/copy`).

One session per account at a time. Logging the same account in on the harness, the simulator and a phone kicks
whichever session was there first, which reads as a disconnect bug in the other.

## See also

- [debugging.md](debugging.md): logs, crash cookies and what to read when a check is RED
- [gotchas.md](gotchas.md): traps that cost real time, by area
- [bridge-api.md](bridge-api.md): the contract these checks protect
- [upstream-release.md](upstream-release.md): the merge and release procedure
- [CONTRIBUTING.md](../../CONTRIBUTING.md) and [RELEASE.md](../../RELEASE.md)
