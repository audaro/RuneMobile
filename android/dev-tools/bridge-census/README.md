# A-1 — bridge/flag census

The first Android phase (see `android/PORT-PHASING.md` §3 Phase A-1). Proves, before any UI is built, that the
shared Java seam the A0–A8 mainline rides on is actually present and callable — so "almost no new *shared* Java"
is evidence, not assumption. **Both halves are now GREEN: A-1a (below) proves *static resolution*; A-1b
(`../a1b-gatecensus`) proves each `-D` gate flips its bridge inert→active at runtime under a booted engine.**

Two halves:

## A-1a — static method census (no device; DONE / GREEN)
`BridgeCensus.java` loads each `net.runelite.client.headless.*` bridge **without running its static
initializer** (so no CACIO/AWT activation is needed) and checks that every method in the expected contract
resolves in the embedded shaded jar, matched by name + ordered parameter simple-type names.

Run on desktop OpenJDK 21 against the Android-staged jar:

```
./run-census-desktop.sh                 # defaults to android/app/src/main/assets/jvm/<client-shaded>.jar
./run-census-desktop.sh /path/to.jar    # or check any staged copy
```

**GREEN baseline (jar `client-1.12.29-SNAPSHOT-shaded`):**

```
BRIDGE_CENSUS verdict=GREEN resolved=79 missing=0 total=79
census_md5=fd2c599160bfe1da1323709f02378286
```

The sentinel md5 is over the sorted `RESOLVED/MISSING` block, so a jar update that changes the bridge surface
flips the md5 — re-run and reconcile. (Restaged 1.12.28→**1.12.29** on 2026-06-07; the md5 is **unchanged**,
confirming the bridge surface is identical across that bump. The runner globs `client-*-shaded.jar`, so it
follows the staged version automatically.) If the contract array in `BridgeCensus.java` falls behind the bridges,
the census under-reports; keep it in sync with `runelite-client/.../headless/*` (the source of truth).

## A-1b — runtime gate-flip census (emulator; DONE / GREEN)
The static half proves the methods exist; it does **not** prove each `-D` gate flips the bridge from inert to
active at runtime (that needs the booted engine with injected singletons). A-1b boots `DeviceHeadlessBoot` on
the `rl_arm64` emulator with the gates set and the `GateCensus` probe armed (`-Drunelite.gatecensus`), then
md5-gates an `isEnabled()`-true + first-read-OK readout per gate (normalized line, per §2.2).

**GREEN (2026-06-07): all six gates active** — `runelite.mobileui` / `menupeek` / `mobilechrome` / `huddata` /
`hudveneer` / `headless.autologin`:
```
ANDROID_GATE_CENSUS verdict=GREEN active=6/6
ANDROID_GATE_CENSUS_GREEN md5=be9883679f9cd8f542a6076fbcf807ff
```
`mobileui.listPlugins()` returns the full ~32 KB plugin-list JSON — the control plane is live the moment its
gate is set. See `../a1b-gatecensus/`. (`runelite.hub` + Quest/World `isAvailable()` are validated in A4/A5,
not here — `--safe-mode` disables external/hub plugins during this census.)
