# Firebase Test Lab driver — the FREE real-device path ($0, no expiry)

The zero-cost alternative to `../browserstack/` for the Android port's real-device gates. Firebase Test Lab's
**Spark plan is free: 5 physical-device runs/day, no billing account** — enough for our cadence (each gate is
one short run). Same idea as the BrowserStack harness: run the APK on a real device, pull the **logcat**, and
verify it by REUSING the emulator md5 gates (`../a0-login/check-loggedin.sh`). Just a different driver
(`gcloud firebase test`, no Appium) and $0 instead of a trial/subscription.

## When to use which
- **Firebase (here):** the default free path for **A0-device** (login → LOGGED_IN, retires the API-29
  `filesDir`-dlopen Q11) and **AG0** (GLES recon). Free forever at 5 runs/day.
- **BrowserStack (`../browserstack`):** when you need things Robo can't do — notably the **A-1b census**
  (needs the `--ez census true` intent extra; Robo only launches the default activity). Census is already
  GREEN on the emulator, so this is rarely needed.

## One-time setup — ONE command, ONE browser sign-in
```sh
android/dev-tools/firebase/fb-setup.sh
```
That's it. `fb-setup.sh` installs the Google Cloud SDK (if missing), opens your browser **once** to sign in
with your Google account (the only manual step), creates/picks a **free Spark-plan project (no billing)**,
enables the Cloud Testing APIs, and verifies a real device is reachable. Idempotent — re-run any time. Auth
lives in gcloud's own config — **no key file in this repo** to manage (unlike BrowserStack's access key).

If the verify step says the project isn't "Firebase-enabled", add Firebase to it (free, 2 clicks):
<https://console.firebase.google.com> → Add project → pick the existing project → skip Analytics → re-run.

## Run
```sh
# login (A0-device): build the main app, then run it on a real device.
( cd ../../.. && cd android && JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew :app:assembleDebug )
./fb-gate.sh login     # A0-device — pushed tokens.json -> autologin -> LOGGED_IN, gated by check-loggedin.sh

# recon (AG0, Track G): build the standalone GLES-recon app, then run it on a real device.
( cd ../../.. && cd android && JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew :recon:assembleDebug )
./fb-gate.sh recon     # AG0 — real GLES tier/extensions/compute readout -> ANDROID_AG0 VERDICT
```
A GREEN run prints the same `ANDROID_LOGGEDIN_GREEN md5=…` sentinel as the emulator — real device, identical gate.

Pick a device id with `gcloud firebase test android models list` (default here: `shiba` = Pixel 8, api 34 —
a GLES 3.1+ arm64 target).

## Files
- `fb-setup.sh` — the one-shot setup (install gcloud → sign in → project → enable APIs → verify a device).
- `fb-gate.sh` — `gcloud firebase test android run --type robo` (push tokens via `--other-files`) → pull
  logcat from the results bucket (`gsutil`) → reuse the emulator md5 gate.

## First-live-run checklist (scaffold — `gcloud` syntax doc-confirmed, not yet run against a real project)
- **gcloud auth + a Spark project** reachable, and the free 5-runs/day quota covers it.
- **Device model id** (`gcloud firebase test android models list`) — `shiba`/34 is a guess; confirm an
  available GLES 3.1+ device.
- **`--other-files` push timing** — that `/sdcard/Android/data/<pkg>/files/` exists at push time on a fresh
  Test Lab device; if not, fall back to `/sdcard/Download` + widen `JagexTokens`' search path.
- **logcat retrieval** — the `gs://…/**/logcat` path under Test Lab's default results bucket (the script
  greps gcloud's printed `gs://` path, then `gsutil cp`s the first `logcat`).
Once a real run is green, replace this checklist with the confirmed device + the GREEN md5.
