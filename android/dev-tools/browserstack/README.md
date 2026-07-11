# BrowserStack driver — real-device gates, API-driven

Drives the Android port's **real-device** gates on BrowserStack **App Automate** end-to-end, with no manual
clicking, then md5-verifies them by reusing the emulator gate scripts on the fetched logcat. This is how
A0-device, A-1b-on-device, and the GPU track's AG0 get run once a key is available — the emulator covers
everything else (see `../../BLUEPRINT.md` §G: emulator-first; BrowserStack only for the AG0 tier truth,
real-driver confirmation, the API-29 `filesDir`-dlopen question (Q11), and perf).

> **App Automate, not App Live.** App Automate is API/script-driven (Appium + REST) — that's what lets this
> run hands-free. App Live is interactive-only (a human clicks in a browser) and can't be driven by this.

## What it does (per session)
1. **Upload** the APK — `POST https://api-cloud.browserstack.com/app-automate/upload` → a `bs://…` app_url.
2. **Drive** the device over Appium (`hub-cloud.browserstack.com/wd/hub`): push `tokens.json` (arms
   autologin), then launch the app — `census` mode passes the `--ez census true` intent extra, exactly like
   the emulator's `adb shell am start … --ez census true`.
3. **Pull** the device logs (logcat) back via REST
   (`…/app-automate/builds/<build>/sessions/<session>/devicelogs`, `deviceLogs` cap on).
4. **Gate** the fetched logcat with the *same* md5 scripts the emulator uses — no new verification logic:
   - `login`  → `../a0-login/check-loggedin.sh`     (A0-device: autologin → LOGGED_IN)
   - `census` → `../a1b-gatecensus/check-gates.sh`   (A-1b on real hardware)
   - `recon`  → GLES tier grep                       (AG0; needs the recon APK, not built yet)

## Setup
```sh
cp bs-credentials.env.example bs-credentials.env     # fill in username + access key (gitignored)
source bs-credentials.env
pip install "Appium-Python-Client>=3"
```

## Run
```sh
# build the APK first (or pass a path as the 2nd arg)
( cd ../../.. && cd android && JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew :app:assembleDebug )

./bs-gate.sh login     # A0-device  — pushed tokens.json -> autologin -> LOGGED_IN on a real device
./bs-gate.sh census    # A-1b       — the 6/6 runtime gate-flip census, on real hardware
```
A GREEN run prints the same `ANDROID_LOGGEDIN_GREEN` / `ANDROID_GATE_CENSUS_GREEN md5=…` sentinels as the
emulator — so "real device" is just a different target for the identical gate.

## Files
- `bs-run.py`  — the Appium session driver (push tokens, launch w/ intent extras, wait, fetch logcat).
- `bs-gate.sh` — orchestrator: upload → run → fetch → reuse the emulator md5 gate.
- `bs-credentials.env.example` — copy to `bs-credentials.env` (gitignored).

## Secret discipline
`bs-credentials.env` (your access key) and `bs-devicelogs-*.txt` are **gitignored** here and never committed
(same rule as `tokens.json`). The key is read from the environment only.

## First-live-run checklist (scaffold — confirmed against the docs, not yet against a real key)
The REST endpoints (`/upload`, `/…/devicelogs`) and the `deviceLogs` capability are doc-confirmed. These few
Appium/BrowserStack specifics are best-effort until the first real run nails them:
- **Outbound HTTPS from this machine** to `*.browserstack.com` (a `curl` to the upload endpoint confirms it).
- **`mobile: startActivity` arg key** for the intent extra (`optionalIntentArguments` vs `intentArguments`) —
  `bs-run.py` falls back to a plain launch if it errors; only `census` mode needs it.
- **`getSessionDetails` field names** (`device_logs_url` / `build_hashed_id` / `hashed_id`) used to locate the
  logcat — `bs-run.py` tries the field, then builds the documented REST URL from the ids.
- **Plan limits** (concurrent sessions / minutes) and whether `--ez` extras require `mobile: shell` (the
  `startActivity` path avoids raw shell).
Once a real run is green, replace this checklist with the confirmed device/OS + the GREEN md5s.
