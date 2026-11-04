# The bridge API

The bridge is the Java package both native shells call into: every frame, tap, plugin toggle and HUD snapshot
crosses it. This page explains how the shells call it, the contract that pins it, the checks that keep the two
ports in step, what each class does, and the procedure for adding or changing a member without breaking the
other port. Read it before you touch `runelite-client/src/main/java/net/runelite/client/headless/` or any JNI
lookup in either shell.

For the member-by-member list (every method, JSON key and `-D` flag, with its Javadoc), see
[bridge-api-reference.md](bridge-api-reference.md). That page is generated from the source, so it is always
current. This page is the part that cannot be generated: the threading, the rules and the traps.

## What the bridge is

The package `net.runelite.client.headless` is plain Java that runs inside the embedded VM next to RuneLite. Its
host-facing API is the **public static methods** of its bridge classes. The shells never construct a bridge
object; they look up a class and a method by name and call it. [architecture.md](architecture.md)
explains where the package sits in the boot and frame paths.

### How the shells call it

Both shells follow the same three steps: find the class, resolve the method ids once and keep them as globals,
then call through them.

| | iOS | Android |
|---|---|---|
| Where the lookups live | `ios/app/RuneMobile/JVMLauncher.m` (`ensureBridge()`, plus an `ensure...` helper per facade) | `android/app/src/main/cpp/jvm_bootstrap.cpp` (`publishBridge()`, called once at boot) |
| JNI style | C: `(*env)->GetStaticMethodID(env, cls, "name", "sig")` | C++: `env->GetStaticMethodID(cls, "name", "sig")`, wrapped in `midOpt()` |
| When | lazily, from the main thread, until the VM and class are ready | eagerly, on the VM's main thread, right after `JNI_CreateJavaVM` |
| Who calls the bridge | the main thread and a few attached worker threads | the native render thread and the Kotlin `rl-bridge` executor; never the UI thread |
| How UI code reaches it | Objective-C class methods on `JVMLauncher` (declared in `JVMLauncher.h`) | `external fun native...` declarations in `JvmLauncher.kt`, implemented as `Java_dev_audaro_runemobile_JvmLauncher_native...` functions in `jvm_bootstrap.cpp` |

Android has two JNI hops: ART calls the C++ function through an ordinary `external` binding, and the C++ code
calls HotSpot through the cached method id. The two VMs are separate; nothing from ART is passed to HotSpot
except copied strings and primitives.

### Methods, not fields

The shells read bridge state only through static methods. No shell code reads a static field
(`GetStaticFieldID` appears only in the iOS census tooling). Keep it that way: a method is where a gate, a
`volatile` read or a lazy computation can live, and the contract scan does not pin fields at all.

Public **constants** are the exception that bites. Values such as `JavaBridge.TAP_KIND_WIDGET` or the
`TOUCH_DOWN`/`TOUCH_MOVE`/`TOUCH_UP` codes are copied by hand into each shell (`kTapKindWidget` in
`ViewController.m`, `TAP_KIND_WIDGET` in `MainActivity.kt`). Changing a constant's value is a breaking change
that no check catches. Add new values; do not renumber old ones.

### What crosses the boundary

| Shape | Used for | Examples |
|---|---|---|
| `int`, `long`, `boolean` | values read every frame or every tap, where a string would cost too much | `getFrameSeq`, `getLastTapKind`, `isTextInputOpen`, `getPublishSeq` |
| `int[]` | pixels and rectangles | `getFramePixels`, `getInventoryBounds`, `getPanelPixels` |
| JSON `String` | structured snapshots and command results | `MobileChromeBridge.getSnapshot`, `MobileUiBridge.listPlugins`, `XpTrackerBridge.getXpJson` |
| `void` | input intents and fire-and-forget commands | `onClick`, `onKeyStroke`, `setUiOpen` |

The bridges build their JSON by hand, through the package-private helpers in `BridgeJson`. Its three escaping
functions (`quoted`, `escaped`, `escapedDropControls`) differ on purpose, and the shells' parsers depend on each
behaviour byte for byte, so do not merge them. Write every JSON key as a literal (`"\"name\":"`) or as a
literal argument to an `append...` helper, so the contract scan can see it.

### Launch flags

Most bridges are inert unless the launcher passes their gate as a `-D` system property, and most read it once
into a `static final` field. A flag therefore has to be set when the VM is created; toggling it later has no
effect. A disabled bridge returns an empty sentinel (`{"active":false}`, `{"available":false}`, `0`) rather
than throwing, so a shell can probe for it safely. Each launcher builds its list in one place:
`runProbesWithLog:` in `JVMLauncher.m` and `bootJvm` in `MainActivity.kt` (plus `JagexTokens.loginOpts`).

| Group | Flags | Notes |
|---|---|---|
| Bridge gates | `runelite.bridge`, `runelite.mobileui`, `runelite.mobilechrome`, `runelite.menupeek`, `runelite.hudveneer`, `runelite.huddata`, `runelite.rendererpanel`, `runelite.bridge.scrollrects` | Both ports set the main gates. iOS sets `runelite.huddata` on every boot; Android only in its census mode. Android alone sets `runelite.bridge.scrollrects`. |
| Boot | `headless.runSeconds`, `headless.captureTargetFrames`, `runelite.nosafemode` | Read by `DeviceHeadlessBoot`. |
| Login | `runelite.headless.autologin` and its `.manual`, `.legacy`, `.eula`, `.world`, `.maxAttempts`, ... sub-flags | Read by `HeadlessLogin`. Both shells pass `.manual` for players: relogs stay automatic, the login does not. |
| Renderer | `runelite.routecgpu`, `runelite.routecrlhd`, `runelite.gfxIos`, `runelite.cpu.unlockfps` | Pick and start a renderer; see [renderers.md](renderers.md). |
| Sizes | `runelite.headless.resize`, `runelite.menupeek.maxEntries` | Initial canvas size; menu entries per snapshot. |
| Touch tuning | `runelite.touch.*` (slop, timeouts, settle), `runelite.key.pacing` | Defaults are tuned; leave them unset in normal launches. |
| Diagnostics | `runelite.touch.diag`, `runelite.gpuframedump`, `runelite.headless.capture.dir`, `runelite.fpsprobe`, `runelite.hudveneer.test.*`, `runelite.gatecensus`, `runelite.mobileui.smoke` | Development only. See [debugging.md](debugging.md). |

The reference page lists every flag the contract pins, with its description.

### The other direction: `RegisterNatives`

The GPU renderers need the opposite of a bridge call: Java `native` methods (on the GL facade classes that
replace LWJGL's) implemented by the shell. Each port registers them right after the VM starts, with
`RegisterNatives` tables:

- iOS: `RouteC_registerGLNatives` in `ios/dev-tools/gpu-routec/jni/routec_gl_jni.m` (generated by
  `ios/dev-tools/gpu-routec/gen/routec_jni_gen.py`) and `RouteC_registerZoneNatives` in
  `ios/dev-tools/gpu-zone/jni/routec_zone_jni.m`.
- Android: `RouteC_registerGLNatives` in `android/app/src/main/cpp/librlawt.cpp`, loaded with `dlopen` only in
  GPU and 117HD modes.

These tables are not part of the bridge contract and neither census checks them. A launch logs the result
(`RouteC_registerGLNatives rc=`); a signature mismatch fails there. [renderers.md](renderers.md) covers the
facades.

## Required and optional lookups

Not every lookup is fatal when it misses. The rule on both ports: the handful of methods needed to show a frame
and send a tap are required; everything else is optional, so an app built against a slightly older or newer jar
still boots with that feature turned off.

- **iOS.** `ensureBridge()` treats a short list of `JavaBridge` methods (frame size, sequence and pixels, the
  core touch, click, move, wheel, camera, text and key calls, `isTextInputOpen`, `clearHover`) as required: if
  any is missing it releases the class and tries again on the next tick. Optional lookups are checked one by one
  and set to `NULL` on a miss, and the wrapper that uses them returns a sentinel. Each other facade has its own
  `ensure...` helper that resolves it the first time a screen needs it.
- **Android.** `publishBridge()` fails the boot if `JavaBridge`'s essential methods do not resolve. Each other
  facade is all-or-nothing: its ids are resolved, and only if all of them resolve is a ready flag stored with
  release ordering (`g_mobileUiReady`, `g_questReady`, `g_worldReady`, ...). A facade's `native...` entry points
  check its flag with acquire ordering and return an empty sentinel while it is false. The four read-only data screens
  (XP, Loot, Grand Exchange, Time Tracking) share one helper, `registerDataPanel`, because they have the same
  shape: `isAvailable`, `setUiOpen` and a JSON getter.

A missing optional lookup is silent by design, which is why the censuses exist.

## The pending-exception trap

When a JNI lookup misses, HotSpot leaves a `NoSuchMethodError` pending on the thread. While an exception is
pending, **every later JNI lookup on that thread returns `NULL`**, whether or not the method exists. One missing
optional method in the middle of a batch therefore makes every lookup after it look missing too, and the
feature that broke is not the one that changed.

Clear the exception after every lookup that can miss:

```c
// Android: midOpt() in jvm_bootstrap.cpp does this for every optional id
jmethodID m = env->GetStaticMethodID(cls, name, sig);
if (!m && env->ExceptionCheck()) env->ExceptionClear();
```

```objc
// iOS: check and clear after each optional lookup
gMidFoo = (*env)->GetStaticMethodID(env, cls, "foo", "()I");
if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMidFoo = NULL; }
```

Do not add an optional lookup in the middle of a run of required ones without clearing after it. The iOS census
clears after every entry, so it reports each missing member on its own even where the app would not.

## The shared contract

A Java change can break the other port without touching any of its files: rename a method, and the shell that
still looks it up by the old name quietly loses the feature. The contract makes those changes visible at commit
time. It lives in [`tools/shared-contract/`](../../tools/shared-contract/README.md).

### What it pins

`extract-contract.py` scans a fixed list of source files (the host-facing bridges, `HeadlessLogin`,
`HeadlessResize`, `RLHDStarter`, `HeadlessSeams`, plus `DeviceHeadlessBoot` and `UnsafePokeActivation` from
`ios/dev-tools/awtsmoke/`) for methods and payload keys, and prints one sorted line per contract entry. It looks for
flags more widely: in every main-source file of the headless package as well, and in a few upstream files
(`Hooks`, `PluginManager`, `SplashScreen`, `RuneLiteProperties`), where `SEAM_FLAGS` pins just the properties the
hosts pass.
[`baseline.txt`](../../tools/shared-contract/baseline.txt) is the committed copy.

| Kind | Format | Example | Meaning |
|---|---|---|---|
| `METHOD` | `METHOD <Class>#<name>(<param types>) -> <return type>` | `METHOD MenuPeekBridge#getPublishSeq() -> long` | A public static method. Parameter names are dropped. The return type is kept, because the JNI descriptor a shell looks the method up by includes it. |
| `FLAG` | `FLAG <property>` | `FLAG runelite.menupeek` | A system property the Java reads (`getBoolean`, `getInteger`, `getLong`, `getProperty`) from a literal or a `static final String` constant, or a `runelite.*` literal handed to a helper that reads it. |
| `PAYLOAD` | `PAYLOAD <Class> <key>` | `PAYLOAD MenuPeekBridge active` | A JSON key the class emits, from `\"key\":` literals and `append...` helper call sites. |
| `PAYLOAD-DYNAMIC` | `PAYLOAD-DYNAMIC <Class> count=<n>` | `PAYLOAD-DYNAMIC HudVeneerBridge count=3` | How many keys in that class are assembled from variables. The scan cannot see those keys, so it pins their count as a tripwire. |
| `MISSING-FILE` | `MISSING-FILE <path>` | | A scanned file was renamed or deleted, which is itself a breaking change. |

### Checking and acknowledging a change

```sh
tools/shared-contract/check-contract.sh            # compare the source against baseline.txt
tools/shared-contract/check-contract.sh --update   # accept the current contract
```

| Exit | Output | Meaning |
|---|---|---|
| 0 | `shared contract: UNCHANGED` | Nothing host-facing changed. |
| 1 | `ADDED` lines only | Additive. The other port simply does not use the new entry yet. |
| 2 | `REMOVED / CHANGED` lines | Something a shell may look up is gone or has a new signature. |
| 3 | `no baseline yet` | `baseline.txt` is missing. |

`--update` rewrites `baseline.txt` and regenerates [bridge-api-reference.md](bridge-api-reference.md) from the
same scan. Stage both in the same commit as the Java change; that is the acknowledgement that you checked both
ports.

Three places enforce it:

- **The pre-commit hook** (`tools/git-hooks/pre-commit`). When staged files feed the shared jars
  (`runelite-client/`, `ios/dev-tools/awtsmoke/`, `tools/stage-*.sh`) it says so and runs the contract check.
  If the contract changed and `baseline.txt` is not staged, it blocks the commit. It also blocks a commit that
  leaves the reference page out of date, which includes a Javadoc edit on a contract member; regenerate it with
  `tools/shared-contract/gen-bridge-api.py`.
- **The release gate** (`android/dev-tools/ci/release-gate.sh`). Its first stage runs the contract check: exit 0
  and 1 pass, exit 2 fails the gate until both ports are verified and the baseline refreshed.
- **CI.** The hosted release workflow runs the gate's `--contract-only` pre-flight before it builds anything.

### What the contract cannot see

The scan reads source text, so it knows names, not meaning. It misses:

- **Behaviour.** A method that keeps its signature but changes thread, units, timing or semantics.
- **JSON shape.** Only key names are pinned. A value that changes type, nesting or units passes.
- **Keys and flags built from variables.** Keep both literal (a flag may sit in a `static final String`
  constant); a key assembled at run time only moves the `PAYLOAD-DYNAMIC` count.
- **Files outside the list.** Methods and keys are read only from `FILES`, so a new host-facing bridge class has to
  be added there in the same change. A host flag read in an upstream file that is not in `SEAM_FLAGS` is not
  pinned either; add the file and the flag when a host starts passing it.
- **Flags only a native host reads.** Android's `runelite.rlhdprobe` and `runelite.routec.smoke` boot modes are
  matched by `jvm_bootstrap.cpp` itself and read by probes in `android/dev-tools/gpu/`, not by the bridge.
- **Constants and fields**, and the `RegisterNatives` tables.

Behaviour is covered by the unit tests in `runelite-client/src/test/java/net/runelite/client/headless/`, which
run on a desktop JDK:

```sh
./gradlew :client:test --tests 'net.runelite.client.headless.*'
```

### Sibling checks

Two other files in `tools/shared-contract/` pin cross-port facts that are not Java:

- `auth-contract.json` and `check-auth-contract.sh` pin the Jagex OAuth wire constants (endpoints, client ids,
  scopes, response keys) across the iOS login screen, the Android login screen and the desktop token script.
  Exit 0 is clean and exit 2 is drift. Editing the JSON is the acknowledgement.
- `check-hub-pin.sh` stops a release once the RuneLite version moves past the last reviewed plugin hub pin.

## The censuses

The contract compares source to source. The censuses check the built jars against what each shell actually
looks up. Run both before calling a shared-bridge change done.

**Android: `android/dev-tools/bridge-census/run-census-desktop.sh`.** Compiles `BridgeCensus.java` and runs it
on a desktop JDK 21 against the shaded client jar for the current `project.build.version` (falling back to the
staged iOS jar). It loads each bridge class without initialising it and matches a hand-maintained list of
expected members by name and parameter types. It prints `ANDROID_BRIDGE_CENSUS_GREEN` (exit 0) or `_RED`
(exit 1), and exits 2 when the jar or `javac` is missing. The list is maintained by hand: when Android starts
using a new member, add it to `CONTRACT` in `BridgeCensus.java`. [Its README](../../android/dev-tools/bridge-census/README.md)
has the details.

**iOS: `ios/dev-tools/bridge-census/run-census-sim.sh --jars`.** `extract-lookups.py` lists every `FindClass`
and method or field lookup in the C-family sources the app target compiles, and stops with an error on any it
cannot resolve. The script restages the jars (`--jars`), builds and launches the Simulator app, which waits for
the client's first frame and then resolves every entry in the running VM, clearing after each one. It ends
with `VERDICT: IOS_BRIDGE_CENSUS_GREEN` (exit 0) or `_RED` (exit 1), takes about 20 seconds when the build is
current, and writes its output to `build/bridge-census/`. [Its README](../../ios/dev-tools/bridge-census/README.md)
has the details.

Neither census checks behaviour, and neither covers the other port.

**Port drift: `tools/port-drift/port-drift.py`.** Not a pass/fail check: a report of where the two ports
differ, including which contract methods each port binds. A method bound by one port only is either a feature
the other port lacks or the same feature reached another way, and both are worth a look. It has no verdict and
no baseline. [Its README](../../tools/port-drift/README.md) explains each section.

```sh
tools/port-drift/port-drift.py --out build/port-drift/report.md
```

## A tour of the package

The classes, grouped by job. "Client thread" means the engine thread; a method documented as client-thread-only
must never be called from a native thread. Every class's own Javadoc has the full story.

### Boot and plumbing

- **`RuneLiteHeadless`**: the Java entry point after `DeviceHeadlessBoot`. Points the session ping at a local
  sink, installs `HeadlessModule`, and calls `RuneLite.main`.
- **`HeadlessModule`**: the Guice override module that binds `ClientUI` to the window-less `HeadlessClientUI`.
- **`HeadlessSeams`**: the single dispatch point for the three `Hooks.java` seams (`draw`, `postComposite`,
  `drawScene`). Each bridge call is wrapped in a guard, so a throwing bridge is logged instead of killing the
  engine's frame. The order of calls in `draw` matters; read it before adding a tick.
- **`BridgeFaults`**: the rate-limited fault log the guard uses. It logs the first throw per call site with its
  stack under the tag `[bridge-fault]`, then suppresses repeats for five seconds and reports the count. The iOS
  shell mirrors it for exceptions it clears on the native side, with the same tag, so both halves show up in one
  search. Package-private.
- **`BridgeJson`**: the JSON escaping helpers described above. Package-private.
- **`package-info.java`**: the threading invariant. See [Threading](#threading-rules-for-bridge-code).

### Frames, input and menus

- **`JavaBridge`**: the core facade, gated by `runelite.bridge`. It owns the frame handoff (`snapshot`,
  `getFrameSeq`, `getFramePixels`, and the GPU readback pair `gpuFrameBackBuffer`/`gpuPublish`), every input
  intent (`onClick`, `onClickPrecise`, `onTouch`, `armTap`, `onMove`, `onWheel`, `onCameraDrag`, `onText`,
  `onKeyStroke`, `onKeybind`, modifier holds), and the per-tap answers the shells draw feedback from
  (`getLastTapKind` with `getTapKindSeq`, `getInteractTapSeq`). Input calls may come from any attached thread;
  they only enqueue, and `tapTick` drains them on the client thread.
- **`MenuPeekBridge`**: a read-only copy of the menu the engine would show at the point under the finger,
  refreshed as `onMove` streams the finger position. Both shells read it; iOS, for example, builds its native
  long-press menu from it. A choice is committed through `JavaBridge.selectMenuPoint` or `invokeMenuEntry`.
  Gated by `runelite.menupeek`.
- **`HeadlessResize`**: resizes the game canvas (`-Drunelite.headless.resize` at boot, `requestResize` later,
  for example when a foldable opens) and reads and sets the camera zoom.
- **`TapItemOutlineOverlay`, `TapWidgetOutlineOverlay`**: RuneLite overlays that briefly outline the item or
  icon just tapped. `JavaBridge` arms them on the client thread.

### HUD and screen layout

- **`MobileChromeBridge`**: a read-only snapshot of where the game's HUD pieces are (tab stones, side panel,
  minimap, orbs, chatbox, viewport), the open tab, and the login and reconnect state the shells overlay. It never
  changes the game. Gated by `runelite.mobilechrome`.
- **`HudVeneerBridge`**: the bridge that does change the game's HUD for the mobile layout: it relocates, hides
  or makes transparent the chatbox, tab stones, minimap and orbs, re-applying its changes every frame because
  the engine rebuilds them. It also publishes the orb, dialogue and world-map snapshots. Gated by
  `runelite.hudveneer`. The chatbox has two writers each frame (the tick after render and the pre-render
  listener); a change to one usually needs the same change in the other.
- **`HudDataBridge`**: read-only HUD content (chat lines, orb values, minimap state). Only iOS consumes it.
  Gated by `runelite.huddata`.
- **`GameLayoutSwitch`**: switches the account's "Game client layout" to Resizable - Modern through the game's
  own settings dropdown, since that setting lives on the server. Backs the shells' one-tap switch. Client
  thread, with `request` as the one cross-thread entry.

### Plugin control plane and native screens

- **`MobileUiBridge`**: the large control plane behind the native plugin, config, hub, panel, notes, hotkey,
  notification and game-settings screens. Reads return JSON. Writes are fire-and-forget: they return at once,
  and the shell can poll `getProcessedWriteId` to learn when one has been applied. Events for the shell
  (notifications, links, screenshots) are queued and polled. Work runs on two lanes: plugin start and stop on
  the event dispatch thread (`PluginManager` asserts it), config and game reads on the client thread. Gated by
  `runelite.mobileui`. On iOS, Grand Exchange is reached through its `ge...` methods.
- **`ConfigProfileBridge`**: lists and switches RuneLite config profiles. A switch runs on the client thread,
  or on a background executor for a profile synced to a RuneLite account.
- **`OverlayBridge`**: the overlay edit mode: list overlays, move, snap and reset them.
- **`InfoBoxBridge`**: the right-click menus of info boxes, by index; invoking one posts the same event a
  desktop click would.
- **`XpTrackerBridge`, `LootTrackerBridge`, `GrandExchangeBridge`, `TimeTrackingBridge`**: read-only data for
  the native XP, Loot, Grand Exchange and Time Tracking screens. Each builds its JSON on the client thread only
  while its screen is open (`setUiOpen`) and reports `available:false` if the plugin is missing or its internals
  have moved. XP and Loot reach package-private plugin state by reflection. Android binds `GrandExchangeBridge`
  directly; iOS goes through `MobileUiBridge`.
- **`QuestHelperBridge`**: reads the external Quest Helper hub plugin by reflection, with an
  `available:false` fallback when it is not installed.
- **`WorldSwitcherBridge`**: the world list, favourites and world hopping.
- **`RuneLiteAccountBridge`**: sign-in to a RuneLite (runelite.net) account for profile sync. Separate from the
  Jagex login.

### Login

- **`HeadlessLogin`**: clicks "Play Now" (and the EULA's Accept on a fresh install) once the `JX_*` session has
  authenticated, dismisses the post-login welcome screen, and runs the bounded reconnect after a dropped
  connection. Its state feeds the reconnect and session-expired fields in `MobileChromeBridge`'s snapshot.
  Gated by `runelite.headless.autologin`.

### Renderers

- **`RouteCGpuStarter`**: starts the base GPU plugin once in the world (`runelite.routecgpu`).
- **`RLHDStarter`**: loads and starts 117HD, which is not a core plugin and is never auto-discovered
  (`runelite.routecrlhd`).
- **`RendererPanelStarter`**: loads both GPU renderers without starting them, so they show in the plugin list
  (`runelite.rendererpanel`).
- **`CpuFpsStarter`**: an experiment, off by default, that lifts the CPU renderer's frame cap
  (`runelite.cpu.unlockfps`).

[renderers.md](renderers.md) explains how these fit together.

### Diagnostics and probes

All inert unless their flag is set.

- **`FrameStats`**: the frame-pacing probe behind `runelite.fpsprobe`, logging `[fpsprobe]`, `[frameprobe]`,
  `[framebins]` and `[framehist]` lines.
- **`HeadlessCapture`**: dumps engine frames to PNG (`runelite.headless.capture.dir`).
- **`MobileUiSmokeRunner`**: an on-device self-test of `MobileUiBridge` (`runelite.mobileui.smoke`) that prints
  markers for a verdict computed outside the VM.
- **`WelcomePlayProbe`, `ChatRelocateProbe`**: early bring-up probes for the desktop harness.

## Threading rules for bridge code

The invariant is in
[`package-info.java:32-66`](../../runelite-client/src/main/java/net/runelite/client/headless/package-info.java):
one writer (the client thread), one `volatile` publish, many lock-free readers; input as queued intents; values
copied across the boundary. For bridge code that means:

- A method a shell calls must not read live engine or plugin state. Build the answer on the client thread
  (in a `tick` or with `ClientThread.invoke`), store it in a `volatile` field, and return that field.
- A method that changes state enqueues the change for the client thread (or for the event dispatch thread, for
  plugin start and stop) and returns.
- Shells may call from any thread they have attached, except that Android never attaches its UI thread. Assume
  your method can be called concurrently with the client thread.
- A `volatile long` incremented only by the client thread is safe to use as a publish counter; it has one
  writer.

## Patterns to copy

### Snapshot on the client thread, read anywhere

`XpTrackerBridge` is the template. `tick` runs on the client thread (from `MobileUiBridge.tick`), reads the
plugin's state only while the native screen is open, and stores the JSON in a `volatile String`. `getXpJson`
returns that string and nothing else.

The iOS XP screen used to read `XpTrackerPlugin`'s state by reflection directly on the main thread. That breaks
the threading rule: the plugin mutates that state on the client thread, so a reader on another thread can see
a half-updated map or throw `ConcurrentModificationException`, and reflection on every refresh costs UI-thread
time. The port-drift report showed that Android already used the client-thread snapshot, and iOS was moved onto
the same one. If a native screen needs plugin data, give it a snapshot bridge; do not read the plugin from the
UI.

### Publish only on change

A shell that polls a snapshot every frame should not copy an unchanged string every frame. Bridges such as
`MenuPeekBridge` and `MobileChromeBridge` keep a publish sequence that advances only when the snapshot's content
changes:

```java
private static void publish(String json)
{
    if (!json.equals(snapshotJson))
    {
        snapshotJson = json;   // store the JSON first ...
        publishSeq++;          // ... then the sequence, so a reader that sees the new seq sees the new JSON
    }
}
```

Android's render thread compares the sequence with its last value (`snapSeqAdvanced`) and skips the copy when
it has not moved. Keep the sequence out of the JSON itself: a counter inside the payload makes every frame's
JSON different and defeats the check.

### Fingerprints for "is it still the same thing"

`MenuPeekBridge.getTopFingerprint` returns a short identity string for the current top menu entry (option,
target, type, ids, with colour tags stripped). It exists so a caller can check that the entry under the finger
did not change between the preview and the release, for example because an NPC walked away. Today only the unit
tests and the Android census reference it; neither shell binds it yet. When you need that kind of check,
compare a fingerprint built from the fields that matter rather than the whole snapshot string.

### Per-tap answers are a queue, not a variable

`JavaBridge.getTapKindSeq` advances exactly once per resolved tap, in the order the taps were made, and
`getLastTapKind` holds that tap's kind. When a player taps twice before the first tap resolves, two answers
arrive and each belongs to the oldest tap still waiting. Treat them as a FIFO: Android's `MainActivity` keeps a
queue of pending click markers and hands each sequence step to the oldest. Reading the value as a single
variable gives the newer marker the older tap's answer and leaves the older one wrong. Every tap that will bump
the sequence must be queued, even one whose marker you expect to discard.

### Fire-and-forget writes with an id

`MobileUiBridge`'s writes return immediately with a write id; `getProcessedWriteId` reports the last one applied.
A shell that needs to know a write has landed (before reading the config back, or before a restart) polls for
its id instead of blocking a thread on the bridge.

### Degrade, don't throw

Bridges that reflect into plugins (`XpTrackerBridge`, `LootTrackerBridge`, `QuestHelperBridge`) report
`available:false` and the shell falls back to the plugin's rendered Swing panel. Native wrappers on both ports
clear any pending exception and return a sentinel. A bridge must never let an exception reach the engine's
frame or the platform UI.

## Adding or changing a bridge member

Work through the whole list; most cross-port bugs have come from stopping halfway.

1. **Write the Java.** Add a public static method on the right class, decide which thread does the work (see
   [the threading rules](#threading-rules-for-bridge-code)), and gate it behind the class's flag. Keep JSON
   keys and flag names literal. Write its Javadoc: it becomes the entry on the reference page.
2. **Test it on the desktop.** Add or extend a test in
   `runelite-client/src/test/java/net/runelite/client/headless/` and run
   `./gradlew :client:test --tests 'net.runelite.client.headless.*'`.
3. **Update the contract.** Run `tools/shared-contract/check-contract.sh` and read the diff. For a `REMOVED /
   CHANGED` line, search both shells for the old name first (step 7). Then run `check-contract.sh --update`
   and stage `tools/shared-contract/baseline.txt` and `docs/dev/bridge-api-reference.md` with the change.
4. **Bind it on iOS.** Add the lookup in `JVMLauncher.m` (optional unless the app cannot work without it,
   cleared after a miss), a class method on `JVMLauncher` that calls it and handles a pending exception, and its
   declaration in `JVMLauncher.h`. Call it from the main thread only if it does not read engine state.
5. **Bind it on Android.** Resolve it with `midOpt` in `publishBridge` (inside the facade's all-or-nothing
   block if it belongs to one), add a `Java_dev_audaro_runemobile_JvmLauncher_native...` function in
   `jvm_bootstrap.cpp` that checks the facade's ready flag, and the matching `external fun` in `JvmLauncher.kt`.
   Call it from the render thread or through `JvmLauncher.onBridge`, never from the UI thread, and never block
   the UI thread on the `Future` that `onBridge` returns. Add it to `CONTRACT` in
   `android/dev-tools/bridge-census/BridgeCensus.java`.
6. **Run both censuses and read the drift report.**
   ```sh
   android/dev-tools/bridge-census/run-census-desktop.sh   # expect ANDROID_BRIDGE_CENSUS_GREEN
   ios/dev-tools/bridge-census/run-census-sim.sh --jars    # expect VERDICT: IOS_BRIDGE_CENSUS_GREEN
   tools/port-drift/port-drift.py --out build/port-drift/report.md
   ```
   A member only one port binds should be deliberate.
7. **Wire it into both shells and check every consumer.** Search both shells for every place that uses the
   behaviour you changed, not only the method name: gesture handlers, overlays, and any native view drawn over
   the same part of the screen. A bridge fix is only half a fix if a native view on the other port still
   covers the region and takes the touch first. One such case: an opaque Android chat view kept consuming taps
   over dialogue after the bridge side had been fixed.
8. **Run the gate.** `./android/dev-tools/ci/release-gate.sh --skip-build` runs the contract, lint and the
   headless unit tests. Then stage the jars and try the change on a device; [testing-qa.md](testing-qa.md) has
   the full checklist.

For a removal, work the other way round: take the lookup and every use out of both shells first, then delete
the Java side, in the same change or a later one. Each app bundles its own jars, so a release always pairs a
shell with the jar it was built against. The order matters for mixed builds (an older app with a freshly staged
jar), which keep working only if the removed member's lookup was optional.

## Logs and faults

- Java-side bridge faults log as `[bridge-fault] <site> threw`, with the stack, once per site per five seconds.
- iOS writes its native-side faults under the same tag to the VM's stdio log, followed by the Java exception
  (`ExceptionDescribe`).
- Android's native code logs to logcat under the `jvm-boot` tag.

A bridge that silently stops after an upstream merge (a moved widget id, a renamed plugin field) usually shows
up as a `[bridge-fault]` line long before anyone notices the frozen HUD element. Search for it first.
[debugging.md](debugging.md) explains how to pull the logs from each port.

## See also

- [bridge-api-reference.md](bridge-api-reference.md): every method, JSON key and flag, generated from the
  source.
- [architecture.md](architecture.md): where the bridge sits in boot, frames, input and threading.
- [`tools/shared-contract/README.md`](../../tools/shared-contract/README.md): the contract tooling.
- [`ios/dev-tools/bridge-census/README.md`](../../ios/dev-tools/bridge-census/README.md) and
  [`android/dev-tools/bridge-census/README.md`](../../android/dev-tools/bridge-census/README.md): the censuses.
- [`tools/port-drift/README.md`](../../tools/port-drift/README.md): the drift report.
- [gotchas.md](gotchas.md): traps, including the chatbox's menu actions.
