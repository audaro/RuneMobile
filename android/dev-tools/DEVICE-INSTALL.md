# Android device install & run

How to put the app on a **physical Android phone** and run it. This is the "real-device wall" — everything up
to here (A1–A8) is emulator-GREEN; the device run is the end-to-end proof + the one true go/no-go (Q11, below).

Unlike the iOS build there is **no JIT-attach dance** — Android grants JIT for free, so it's just install + launch.

## 0. What you need

- An **arm64 (`arm64-v8a`) Android phone** — the APK ships **only** that ABI (`app/build.gradle.kts`
  `abiFilters += "arm64-v8a"`; the embedded HotSpot JRE is a bionic arm64 build). Any modern phone qualifies; a
  32-bit-only device will not install.
- **Developer options + USB debugging** on, and `adb` on PATH (`~/Library/Android/sdk/platform-tools`).
- A **throwaway Jagex account** (never a main — live OSRS on a self-built client carries ban risk).
- Disk: first launch unpacks the embedded JRE + jars (~a few hundred MB) into the app's private storage.

## 1. Build the APK

```
cd android
JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew :app:assembleDebug
#   debug   -> app/build/outputs/apk/debug/app-debug.apk      (verbose: pipes the VM's stdout/err to logcat)
# or, for a clean signed build:
JAVA_HOME=… ./gradlew :app:assembleRelease
#   release -> app/build/outputs/apk/release/app-release.apk  (debug-key signed; NO stdio/token-PII logging)
```

Use **debug for the first run** (you'll want the `jvm-boot` / `jvm-stdout` logs if anything goes wrong); switch
to **release** once it works. Both are no-minify — R8 stays OFF on purpose (the engine + headless bridges are
resolved by name via JNI `FindClass` and RuneLite leans on reflection internally, so shrinking would break it;
the size is dominated by the unshrinkable native JRE/jars anyway). Release is signed with the debug key — fine
for personal sideload (this build is never shipped to others); swap in a real keystore in the `release`
buildType if that ever changes.

## 2. Install + launch

```
adb install -r app/build/outputs/apk/debug/app-debug.apk     # plug in ONE device; -s <serial> if several
adb shell am start -n dev.audaro.runemobile/.MainActivity
```

First launch: `AssetInstaller` unpacks the JRE/jars to `filesDir` (a few seconds, one-time), then the native
layer `JNI_CreateJavaVM`s the embedded HotSpot VM and boots headless RuneLite. With no tokens yet you land on
the **login screen** (or the in-app login, step 3).

## 3. Log in

**Option A — in-app (the normal path).** With no `tokens.json`, the app routes to the on-device Jagex login
(WebView OAuth) before boot; or tap the **`⎆`** button to switch account. Complete the Jagex consent/login in
the WebView, pick the character — it writes `tokens.json` to internal `filesDir` and restarts into a clean boot
(`JNI_CreateJavaVM` snapshots the `JX_*` env at startup, so a restart is required after writing tokens).

**Option B — push tokens directly (dev shortcut, DEBUG builds only).** If you already have a `tokens.json`
(e.g. from `ios/dev-tools/fetch-shield-tokens.sh`):

```
# internal filesDir (works for debug AND release):
cat tokens.json | adb shell run-as dev.audaro.runemobile tee files/tokens.json > /dev/null
# OR the app's external files dir (DEBUG builds only — release ignores external storage by design):
adb push tokens.json /sdcard/Android/data/dev.audaro.runemobile/files/tokens.json
```

Then relaunch. Autologin arms when `session_id` + `chosen_account_id` are present.

## 4. The one real go/no-go — Q11 (filesDir dlopen on hardened HW)

The embedded VM is brought up by `dlopen`-ing `libjvm.so` **from the app's private `filesDir`**. On the emulator
and standard devices this is fine. Some hardened devices / SELinux or `execmem`/W^X policies can refuse to
execute code mapped from app-writable storage — that's the **A0-device go/no-go** the emulator cannot prove.
If the VM never comes up, this is the first thing to check (see the failure signature below). If it bites, the
fallback is staging the `.so`s where execution is permitted (e.g. the APK-extracted `nativeLibraryDir`), which is
a packaging change, not a code rewrite.

## 5. What "working" looks like (logcat, debug build)

```
adb logcat -c ; adb logcat | grep -E "jvm-boot|MainActivity|jvm-stdout"
```

- `jvm-boot: JNI_CreateJavaVM…` then `HotSpot VM up`
- `jvm-boot: bridge: JavaBridge facade published` (+ MobileUiBridge / HudVeneerBridge / MobileChromeBridge)
- `MainActivity: startJvm rc=0`
- once in-world: `ANDROID_A6_UI_GREEN native 2-col tab grid drawn …` and the chrome (2-col tab grid bottom-right,
  chat-at-top, minimap top-right) renders over the live scene.

A `--ez census true` intent extra additionally runs the A4/A5/A6 seam self-tests and prints
`ANDROID_A*_SEAM_GREEN` lines.

## 6. Troubleshooting

| Symptom | Likely cause / check |
|---|---|
| `INSTALL_FAILED_NO_MATCHING_ABIS` | device isn't `arm64-v8a` (32-bit only) — unsupported. |
| App installs, black screen, no `jvm-boot` VM-up | the VM didn't come up — check `dlopen` of `libjvm.so` (Q11 §4); confirm the JRE unpacked (`adb shell run-as dev.audaro.runemobile ls files/jvm/jre/lib/server/`). |
| Boots but stuck on login | no usable `tokens.json` (or release build can't see externally-pushed tokens — use the internal `run-as` push). |
| Release build: no logs at all | expected — release does **not** pipe the VM's stdout/err to logcat (A8 hardening). Use the debug build to debug. |
| Soft keyboard / haptics dead | check the `VIBRATE` permission is granted (it's in the manifest) and the IME shows on a chat tap. |

## 7. After it runs — the rest of A8

- **Soak:** leave it logged in for a few hours; watch memory/FPS under `-Xmx512m` (the VM is kept alive for the
  whole process). No leak/GC pathology = A8 soak GREEN.
- **Packaging:** the release APK is already signed + installable. For real distribution (not the plan) you'd add
  a dedicated keystore + first-run UX polish.
