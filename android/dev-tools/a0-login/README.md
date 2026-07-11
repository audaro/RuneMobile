# A0 — autologin to LOGGED_IN

GREEN gate for Phase A0 (see `android/PORT-PHASING.md`): from a pushed `tokens.json` (the JX_* launcher
handoff) with **no manual taps**, the engine drives `gameState` all the way to `LOGGED_IN`.

## How it works
`JagexTokens.kt` locates `tokens.json`, sets `JX_SESSION_ID` / `JX_CHARACTER_ID` / `JX_DISPLAY_NAME` /
`JX_ACCESS_TOKEN` / `JX_REFRESH_TOKEN` via the native `nativeSetEnv` bridge **before** `JNI_CreateJavaVM`
(HotSpot snapshots the environment at startup), then `MainActivity` appends the `runelite.headless.autologin.*`
opts. `HeadlessLogin` (already in the shared jar) clicks EULA→Play Now and selects the world.

## tokens.json (secret — never committed)
Minted with `ios/dev-tools/fetch-shield-tokens.sh` (throwaway Jagex account only). The **same** `tokens.json`
the iOS port uses is reusable as-is — identical key mapping (`session_id`→`JX_SESSION_ID`, etc.). Push it to
the app's files dir (debug build):

```
adb shell mkdir -p /sdcard/Android/data/dev.audaro.runemobile/files
adb push ios/dev-tools/tokens.json /sdcard/Android/data/dev.audaro.runemobile/files/tokens.json
```

`JagexTokens` checks the internal `filesDir` first, then this external dir. No `tokens.json` → login-screen
render only (autologin disabled).

## Verify (md5-gated)
```
adb logcat -c
adb shell am force-stop dev.audaro.runemobile && adb shell am start -n dev.audaro.runemobile/.MainActivity
# wait for boot + autologin, then:
./check-loggedin.sh                 # live `adb logcat -d`
./check-loggedin.sh saved.txt       # or a saved dump (e.g. a cloud-device run)
```

The gate extracts the normalized `gameState X -> Y` chain (no timestamps/pids/draw#/display-name → stable,
no secret) and md5s it.

**GREEN baseline (emulator `rl_arm64`, 2026-06-04):**

```
gameState null -> LOGIN_SCREEN -> LOGGING_IN -> LOADING -> LOGGED_IN
ANDROID_LOGGEDIN_GREEN md5=8aa7314f8d7b70116a5a3ad2e05b7d69
```

## Status / follow-up
- Emulator LOGGED_IN: **DONE / GREEN** (above).
- Real-device confirm + the `filesDir` dlopen question (PORT-PHASING §5 Q11): **TODO** on a cloud device
  (§4.5). The emulator already logged `avc: granted { execute }` for `libjvm.so` under `files/` — promising,
  but emulator-only.
