# Port drift

Lists where the iOS and Android ports differ, read from their source. Each comparison is made against something
both ports share, so a difference is a place where one port has moved and the other hasn't:

```sh
tools/port-drift/port-drift.py --out build/port-drift/report.md
tools/port-drift/port-drift.py --ios-log <Documents>/hello-shell.log \
    --android-log logcat.txt      # adb logcat -d -v threadtime -s 'jvm-boot:*' > logcat.txt, after a launch
```

The report is Markdown, on stdout unless `--out` names a file. A one-line summary follows it (on stderr when the
report goes to stdout):

```
PORT_DRIFT overrides: 16 one-port, 4/18 both-but-different; options: 4 differ, 11 iOS-only, 9 Android-only; bridge: 21 iOS-only, 17 Android-only, 65 neither of 236
```

It lists differences and doesn't judge them. Many are deliberate (iOS GLES 3.0 has no texture buffers, so iOS
overrides files Android doesn't need to), so there is no green or red, and no baseline to update. Read it after an
upstream or RLHD bump, after porting a feature from one side to the other, and before a release. Plain `python3`
(3.9 or later), no packages.

Exit 0 with a report, or 2 when an input is missing or the source has a shape the extractors don't handle. They
stop rather than leave something out: a report that silently skipped a lookup would look like agreement.

## 1. RLHD overrides

Both ports lay their own GLSL and Java files over the same pinned 117HD tree (`RLHD_REV` in each port's stager)
before building `client-rlhd.jar`:

| Port | GLSL | Java |
|---|---|---|
| iOS | `ios/dev-tools/gpu-zone/ios-overrides` | `ios/dev-tools/gpu-zone/java-overrides` |
| Android | `android/dev-tools/gpu/shader-overlay` | `android/dev-tools/gpu/java-overlay` |

Files only one port overrides are listed with how far they are from the pinned RLHD file and the commit that last
changed them. Files both ports override are compared with each other: identical, the same code with different
comments, or different code (lines added and removed, comments and blank lines left out).

It needs each port's `rlhd-src` checkout, at the pinned revision and with no local edits, because that is what the
override is measured against. A missing or moved tree stops the run; the stager provisions it.

Both ports also rewrite shader source at compile time (iOS `downportShaderSource` in `RouteCBridge.m`, Android
`rc_downport` in `librlawt.cpp`), so two files that differ here can still compile to the same shader. Check the
rewrite tables before calling a difference a bug.

## 2. JVM options

The options each port's boot path can pass:

- iOS: `runProbesWithLog:` in `JVMLauncher.m`;
- Android: `bootJvm` in `MainActivity.kt`, `loginOpts`, `playerLoginOpts` and `devAutologinOpts` in `JagexTokens.kt`
  and `jvmThreadMain` in `jvm_bootstrap.cpp`.

Options are compared by key (`-Dname`, `-XX:Name`, `-Xmx`, ...), so `-Dx=1` and `-Dx=2` are one option with two
values. A value the code builds at run time shows as `{expr}`; Kotlin `const val`s are filled in. The tables are:
both set it to different values; both compute it at run time (the source can't say whether they agree); only one
port sets it; contract flags (`FLAG` lines in `tools/shared-contract/baseline.txt`) that neither port sets. Options
set outside the boot path (Android's GPU smoke and RLHD probe modes) are counted, not compared, and an option
string the native code only tests for (`o == "-D..."`) is left out.

A launch log marks each value that launch really passed with ✓ and shows a computed one's value. An option in the
log that the scan didn't find stops the run, because the scan would then be missing something.

## 3. Bridge bindings

The Java members each port's native code looks up through JNI, matched to the contract's public-static bridge
methods (`METHOD` lines in `baseline.txt`):

- iOS: `ios/dev-tools/bridge-census/extract-lookups.py`, the same list the iOS census resolves in the simulator;
- Android: `android/app/src/main/cpp`, the files `CMakeLists.txt` builds. The extractor follows class variables
  through `NewGlobalRef`, globals, the `midOpt` wrapper and helpers that take the class name or return it through an
  output parameter (`registerDataPanel`), and resolves each helper call at its call site. It reads the C++
  `env->Name(...)` form; a lookup written any other way (C's `(*env)->Name(env, ...)`) stops the run.

The report counts each bridge class's methods bound by both, one or neither port, lists the one-port ones, and the
lookups outside the contract. A method bound by neither is usually one the Java side calls itself (`init`, `tick`).
One bound by one port can be a feature the other lacks, or the same feature reached through a different method,
which is the kind of drift worth reading closely.

Not covered: `RegisterNatives` tables and other calls from Java into native code, and lookups whose class or name
comes from data (Android's main class), which are listed as skipped.

## Tests

```sh
python3 -m unittest discover -s tools/port-drift -p 'test_*.py'
```

The lexer, option keys, placeholders, JNI descriptors, the Android extractor on synthetic C++, and a run of the
whole report on this tree (skipped when an `rlhd-src` checkout is missing).
