# A-1b — runtime gate-flip census

The runtime half of Phase A-1 (see `android/PORT-PHASING.md` §3 Phase A-1). A-1a (`../bridge-census`) proved every
bridge method **resolves** statically in the shaded jar. A-1b proves the next thing on a real boot: that each
`-D` gate actually flips its bridge **inert → active at runtime** under a booted, LOGGED_IN engine — turning the
plan's central "A3–A8 is host/UI work, not engine work" claim into captured, md5-gated evidence.

## What it proves
With `-Drunelite.<gate>=true` set at launch, for each bridge: `isEnabled()` is `true` **and** a first read
returns without throwing. The read works because the gate is what wires the bridge into `Hooks.draw`'s
per-frame `tick(client)` — so by LOGGED_IN the bridge is publishing a live snapshot, not sitting inert. No host
JNI wiring is involved; the activation is entirely engine-side, which is exactly the point.

## How it works
- **`GateCensus`** (`ios/dev-tools/awtsmoke/GateCensus.java`, folded into `probes.jar`) — reflection-based,
  like the A-1a static census. Armed by `-Drunelite.gatecensus=true`; `DeviceHeadlessBoot` calls
  `GateCensus.runOnce(true)` once when the poll loop first sees `state==LOGGED_IN`. Emits one deterministic
  sentinel per gate plus a verdict.
- **Census mode** — launch the app with the intent extra `--ez census true`; `MainActivity` then adds the
  remaining read-surface gates (`mobileui`/`mobilechrome`/`huddata`/`hudveneer`; `menupeek` + autologin are
  always on) and `gatecensus`. A normal launch sets none of this and the probe is a no-op.

## Run (arm64 emulator)
```
# build + install the census-capable APK
( cd android && JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew :app:assembleDebug )
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
adb shell am force-stop dev.audaro.runemobile ; adb logcat -c
adb shell am start -n dev.audaro.runemobile/.MainActivity --ez census true
# after it reaches LOGGED_IN (a tokens.json must be pushed for autologin):
./check-gates.sh                 # live `adb logcat -d`
./check-gates.sh saved.log       # or a saved/cloud-device dump
```
`check-gates.sh` extracts the per-gate sentinel lines (`GATE_CENSUS <gate> enabled=<b> live=<b>`, detail
stripped), sorts them, and md5-gates the result.

## GREEN baseline (emulator `rl_arm64`, 2026-06-07)
```
GATE_CENSUS autologin    enabled=true live=true   # loggedIn=true
GATE_CENSUS huddata      enabled=true live=true   # getSnapshot=len572
GATE_CENSUS hudveneer    enabled=true live=true   # getChatSnapshot=len18
GATE_CENSUS menupeek     enabled=true live=true   # getSnapshot=len277
GATE_CENSUS mobilechrome enabled=true live=true   # getSnapshot=len289
GATE_CENSUS mobileui     enabled=true live=true   # listPlugins=len32230
ANDROID_GATE_CENSUS verdict=GREEN active=6/6
ANDROID_GATE_CENSUS_GREEN md5=be9883679f9cd8f542a6076fbcf807ff
```
The `mobileui` read returns the full ~32 KB plugin-list JSON — concrete proof the plugin control plane (A4) is
live the moment its gate is set, with no host code yet calling it.

## Not covered here (deliberate)
- **`runelite.hub`** — the Plugin Hub gate needs network + drops `--safe-mode`, and the repo `1.12.29-SNAPSHOT`
  has no published hub manifest (404). It's exercised as part of **A4** (pin `runelite.pluginhub.version` to a
  published rev), not in this read-only census.
- **Quest Helper / World Switcher** activate via `MobileUiBridge.init` but their `isAvailable()` is `false`
  under `--safe-mode` (external plugins disabled); they're validated in **A5**.
