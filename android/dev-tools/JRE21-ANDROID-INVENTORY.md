# Android bionic JRE 21 — inventory & provenance

> The Android twin of [`ios/dev-tools/JRE21-INVENTORY.md`](../../ios/dev-tools/JRE21-INVENTORY.md). The embedded
> JRE is the **one artifact that gates even the Milestone-A smoke** and is **gitignored** (large, generated),
> so this file is its tracked provenance: where it comes from, how it's pinned, and the two hard rules for
> staging it. Single source of truth for the mechanics is [`tools/stage-android-jre.sh`](../../tools/stage-android-jre.sh).

## What it is
A **bionic arm64 OpenJDK 21** (HotSpot, JIT-capable). Not glibc, not Mach-O — it links the Android
`/system/bin/linker64` and needs the **unversioned** `libc.so` / `libm.so` / `libdl.so` (NOT glibc's
`libc.so.6`). The iOS Mach-O JRE is unusable here; the JVM family is the same (OpenJDK 21 HotSpot), the ABI
is not.

## Pinned source (primary)
| Field | Value |
|---|---|
| Project | `AngelAuraMC/angelauramc-openjdk-build` (PojavLauncher / Amethyst lineage) |
| Release / asset | tag `download_jre21` → `jre21-android-arm64.tar.xz` (~28 MB) |
| URL | `https://github.com/AngelAuraMC/angelauramc-openjdk-build/releases/download/download_jre21/jre21-android-arm64.tar.xz` |
| SHA-256 | `8d41ec401ee59f7722df60ed991f81ad146e130452804bfdd8a05d3436f7bbfe` |
| Verified by | `tools/stage-android-jre.sh` (pinned-SHA check + a bionic-aarch64 structural check) |

GitHub release assets are immutable per tag, so the URL + SHA pin is durable. `--no-verify-sha` skips the
hash (the structural check still runs); `--force` re-downloads.

**Alternative (interchangeable):** the QuestCraftPlusPlus fork's `JRE-21.zip` also boots HotSpot here. It hits
the `jniLibs`/`libawt` trap below **identically**, so it is not a workaround for that — just a second source.

## How it's staged (one command)
```sh
tools/stage-android-jre.sh        # download (cached) + verify SHA + bionic check + stage + build fake-xawt
tools/stage-mobile-runtime.sh     # then stage the shared client/probes jars (see ../../PORTS.md)
```
`stage-android-jre.sh` unpacks the **whole** tree into `app/src/main/assets/jvm/jre/`, builds the missing
`libawt_xawt.so` into `dev-tools/fake-xawt/`, and removes any stray JRE `.so` from `jniLibs` (the trap below).
At runtime `AssetInstaller` unpacks `assets/jvm/jre/` → `filesDir/jvm/jre` on first launch;
`JAVA_HOME=filesDir/jvm/jre`, `java.library.path=filesDir/jvm/jre/lib`.

## Two hard rules (do not relearn these the painful way)

1. **The JRE `.so` set goes in `assets/` ONLY — never mirror it into `jniLibs/`.** The native bootstrap
   (`librunemobile.so`, loaded from the app's legit native-lib dir) `dlopen`s `libjvm.so` and preloads the
   rest of `lib/*.so` by **absolute path** from `filesDir`. Mirroring the JRE `.so` into
   `app/src/main/jniLibs/arm64-v8a/` makes the linker resolve `libawt.so` **by soname** from
   `/data/app/.../lib/arm64/`, so `libawt`'s `JNI_OnLoad` gets a non-absolute `dli_fname`, its `realpath()`
   fails, the toolkit-path `malloc` is handed a garbage length, and the VM aborts
   **`FATAL ERROR in native method: Could not allocate library name`** in `java.awt.Toolkit.<clinit>` —
   before CACIO can take over. Reproduced identically across two independent bionic jre21 builds; the cure is
   **filesDir-only**. `jniLibs/` holds only the CMake-built `librunemobile.so` (Gradle places it there).

2. **The API-29 `filesDir`-dlopen question is still emulator-only (PORT-PHASING Q11).** The native-initiated
   absolute-path `dlopen` of `libjvm.so` from writable `filesDir` works on the arm64 emulator (SELinux logged
   `avc: granted { execute }`), but Android nominally forbids dlopen from writable app storage for API-29+
   targets. **Unproven on hardened real hardware** — the A0-device / AG0 gate retires it; the fallback is to
   ship the JRE `.so` under a native-lib dir or lower `targetSdk`.

## Caveats (plugin-level, not JRE-level)
- Plugins bundling **native** libs won't load on this JRE without an Android-native rebuild (the GPU track's
  `librlawt` is the worked example — see `BLUEPRINT.md` Track G). Pure-Java plugins are fine.
- Any plugin assuming **glibc-only** native behaviour (e.g. ICMP/raw-socket tricks, JNA dispatch against a
  glibc layout) needs per-case checking against bionic — re-verify on device, don't assume.

## See also
- [`../README.md`](../README.md) — the bring-up gotchas (`allowNativeHeapPointerTagging`, `java.io.tmpdir`,
  CACIO CTC activation order, the fake-xawt backend).
- [`../../PORTS.md`](../../PORTS.md) — the shared client/probes jar staging (separate from the JRE).
- [`../BLUEPRINT.md`](../BLUEPRINT.md) / [`../PORT-PHASING.md`](../PORT-PHASING.md) — where the JRE fits in the phase plan.
