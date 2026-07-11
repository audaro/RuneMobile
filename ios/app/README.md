# ios/app — the native iOS app (W1 minimal JVM shell)

The Phase-1 **Prong B** shell: prove *our own* free-cert iOS app can load the embedded `jre21`,
`JLI_Launch` a trivial `Hello` on-device under StikDebug JIT, and read the verdict on-screen. Once green,
swap the main class to `JitProbe`/`Bench`/`GlyphSmoke` (`../dev-tools/jvmbench/`) for the definitive numbers.

This is a **deliberate experiment** built per the W1 audit verdict (`../AUDIT-BRIEF-w1-jvm-shell.md`): the
first run is expected to *teach us what breaks first*, not necessarily to reach `Hello.main`.

## Layout
| Path | Role |
|---|---|
| `project.yml` | xcodegen project (source of truth; the `.xcodeproj` is generated, gitignored) |
| `RuneMobile/JVMLauncher.{h,m}` | CS_DEBUGGED gate, RWX canary, `dlopen(libjli)`→`JLI_Launch` glue |
| `RuneMobile/ViewController.m` | on-screen console, wait-for-JIT poll, stdout/stderr capture |
| `RuneMobile/RuneMobile.entitlements` | `increased-memory-limit` only (see Claim D) |
| `scripts/resign-jre.sh` | build phase: re-sign every Mach-O in the embedded `jre/` (Claim A) |
| `jvm-resources/src/Hello.java` + `Hello.jar` | the payload (prints VM name / `mixed mode` / compile-ms verdict) |
| `../dev-tools/jre/` | the verified Amethyst `jre21` (gitignored; folder-referenced into the `.app` as `jre/`) |

## Build / run loop (you drive Xcode + StikDebug)
1. **Generate the project:** `cd ios/app && xcodegen generate`
2. **Open `RuneMobile.xcodeproj` in Xcode 26.5.** Set the target's **Team** to your free Apple ID, plug in the
   iPhone 17 Pro Max, **Build + Run** (or Archive → AltStore install). The `resign-jre` phase re-signs the
   bundled JRE dylibs with your cert.
3. **Assign the iOS-26 JIT script** to RuneMobile in **StikDebug** (the same universal TXM script used for
   Amethyst — see the crux note below).
4. **Launch RuneMobile.** It shows a console and `JIT: waiting…`. **Attach StikDebug.** When the kernel sets
   `CS_DEBUGGED`, the status flips green and **Start JVM** enables.
5. **Tap Start JVM.** Read the console; the full log is also at `Documents/hello-shell.log` (Files.app —
   `UIFileSharingEnabled`). Optional **RWX canary** button = naive `mprotect` RW→RX probe (diagnostic only).

### Rebuild `probes.jar` (Hello + JitProbe + Bench + GlyphSmoke)
The shell now runs the Rung-1 probes (`JitProbe`, `Bench`, `GlyphSmoke` from `../dev-tools/jvmbench/`) in one VM
via `JNI_CreateJavaVM`; tapping **Run probes** runs all three. GlyphSmoke writes `Documents/glyph-smoke.png`.
```sh
cd ios/app/jvm-resources
JH=/opt/homebrew/opt/openjdk@21
"$JH/bin/javac" --release 8 -d classes src/Hello.java \
  ../../dev-tools/jvmbench/JitProbe.java ../../dev-tools/jvmbench/Bench.java ../../dev-tools/jvmbench/GlyphSmoke.java
"$JH/bin/jar" --create --file probes.jar -C classes .
```
Pull results off-device after a run:
```sh
xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer \
  --domain-identifier dev.audaro.runemobile --source Documents/jvm-stdio.log --destination /tmp/jvm.log
# (same for Documents/glyph-smoke.png)
```

## How the W1 audit corrections are wired in
- **Claim A — re-sign vs dyld bypass (UNPROVEN → treated as experiment).** `scripts/resign-jre.sh` re-signs the
  ad-hoc JRE dylibs with our cert; `JVMLauncher` does a *plain* `dlopen` first. If iOS library validation
  rejects it, `dlerror()` is logged → the bypass is mandatory (we did **not** vendor Amethyst's GPLv3 bypass).
- **Claim B — always-attached vs JS-script (REFUTED → script-capable).** HotSpot's local `libjvm` carries
  `brk #0x69` / `[JIT26]` / `MirrorMappedCodeCache`, so it *asks* the debugger/script for JIT mappings. The run
  procedure therefore **requires an assigned StikDebug JIT script** — we do not assume bare attach suffices.
  First run is the A/B: no script (expect a break/abort before `main`) vs assigned script.
- **Claim C — minimal JLI args (SUPPORTED + tweaks).** `argv[0] = <javaHome>/bin/java`, `JAVA_HOME` exported,
  `-Djava.home`, `-Djava.library.path=<app>/Frameworks`, `+UnlockExperimentalVMOptions +MirrorMappedCodeCache
  +DisablePrimordialThreadGuardPages -UseCompressedClassPointers`. No AWT/GL/`-XstartOnFirstThread`.
- **Claim D — entitlements (SUPPORTED + correction).** Only `com.apple.developer.kernel.increased-memory-limit`.
  `get-task-allow` comes from the Development profile at sign time (not hardcoded); macOS `cs.*` keys omitted.
- **Claim E — wait-for-JIT (SUPPORTED → `CS_DEBUGGED`, not vibes).** `csops(CS_OPS_STATUS)` polled every 200 ms;
  JVM launch is gated on the flag. Optional RWX canary as the "extra certainty" preflight (may false-negative
  under MirrorMapped — documented inline).

## What breaks first (the things to watch on run 1)
- `dlopen(libjli)` fails → **Claim A refuted** (re-sign insufficient; bypass needed).
- `dlopen` succeeds but HotSpot aborts (EXC_BREAKPOINT/SIGTRAP/SIGILL) before the Hello banner with **no script
  assigned** → **Claim B confirmed** (JS-script machinery mandatory). Re-run with the script assigned.
- Reaches `=== RuneMobile: HotSpot reached main() ===` with `VERDICT = JIT ACTIVE` → **the whole Prong B gate is
  green**; swap `Hello` → `JitProbe` next.

Reference patterns (GPLv3 — read only, clean-room, never vendored): `AngelAuraMC/Amethyst-iOS`
`Natives/JavaLauncher.m`, `Natives/dyld_bypass_validation.m`, `Natives/utils.m` (`DeviceHasJITFlags`/`JIT26*`).
