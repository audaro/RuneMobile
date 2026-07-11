# Releasing & recovery

> Unofficial fan project. Not affiliated with, endorsed by, or sponsored by Jagex or the
> RuneLite project. This file is the source for each release page's disclosure text, the
> known-issues list, and the update/rollback/recovery procedure. It covers both ports;
> install/recovery steps differ by platform and are split below.

---

## Release-page disclosure (paste into every release)

> **This is an unofficial, fan-made client. It is not affiliated with, endorsed by, or sponsored
> by Jagex or the RuneLite project, and it is not on Jagex's approved-client list.**
>
> - **Account-ban risk.** Logging into live Old School RuneScape with an unapproved client can get
>   your account **banned**. Use a **throwaway** account you can afford to lose — never a main.
> - **Personal/technical project.** Provided as-is, best-effort, single-maintainer, **no warranty**.
>   It may break after any OSRS weekly update until a new build is published.
> - **You install it yourself** by sideloading. It is not on the App Store or Google Play and never
>   will be.
> - **Your data:** the app sends your account/gameplay data only to **Jagex** (to play) and, *only
>   if you opt in* (RuneLite-account sync, or enabling the default-off Loot Tracker / Chat Commands
>   plugins), to the **RuneLite project**. A few read-only fetches (world list, item prices, runtime
>   config) come from RuneLite's CDN/API and carry no account data. No telemetry, analytics, or
>   crash reports are sent, and the maintainer runs no server and collects nothing. See
>   **[PRIVACY.md](PRIVACY.md)**.
> - **Game content** (art, maps, audio) is Jagex's, streamed from your own game cache at runtime and
>   never redistributed by this project. RuneScape and Old School RuneScape are trademarks of Jagex.

## Known issues (keep current per release)

These are accepted, documented behaviors — list the ones true for the build being shipped:

- **Reconnect is a re-login, not a seamless resume.** A network drop beyond the in-game reconnect
  window returns you to the login screen; logging back in restores the session. No game state is lost
  server-side.
- **Backgrounding drops the game session.** Sending the app to the background (or locking the screen)
  pauses the client; on return you may need to log in again, and the **first** resume-login can
  occasionally need one retry.
- **Sustained heavy load lowers 117HD resolution.** Under thermal pressure the 117HD renderer steps
  its scene-resolution scale down and restores it on cooldown (by design — keeps the frame rate up).
- **JIT attach (iOS only).** iOS requires re-attaching the debugger (StikDebug) per launch to enable
  JIT; this is an OS constraint, not a bug.

---

## Signing

Release builds are signed with a dedicated key (not the debug key). The signing certificate is:

- **Subject:** `CN=RuneMobile, O=RuneMobile`
- **SHA-256:** `45:E3:05:84:4D:53:A6:26:5D:C8:6E:B3:99:BE:99:7A:B3:FA:27:76:F9:0F:18:B1:6F:D4:EC:90:F4:3D:3C:9E`

Every published APK should carry this fingerprint (verify with
`apksigner verify --print-certs <apk>`); a build that doesn't is not a genuine release. **Update-in-place
only works between APKs signed by this same key** — see the rotation warning in `keystore.properties.example`.
The key material lives outside the repo and is never committed; keep the keystore **and** its password
backed up (a lost key means future updates require users to uninstall + reinstall).

## Versioning

- `versionName` is semver (e.g. `0.1.0`); `versionCode` is derived monotonically
  (`major*10000 + minor*100 + patch`). See `android/CHANGELOG.md`.
- Every published release keeps its artifact downloadable on the releases page (do **not** delete old
  releases) so users can **roll back** — see recovery below.

## Update check

There is **no in-app update check** in this build (it would require a published release feed, which is
deferred while distribution stays sideload-only). **Check the releases page manually** for a newer
build, especially after an OSRS weekly update (a stale client shows a black screen /
`js5connect_outofdate` until rebuilt against the new revision).

---

## Update, rollback & recovery

Updating **never wipes your data** — the same-signature install upgrades in place; your token, cache,
config, and renderer choice persist. The embedded JVM/jars re-unpack incrementally (only changed jars
are recopied) on first launch after an update.

### Android

**Update:** install the newer APK over the old one (same signing key):
```
adb install -r RuneMobile-<version>.apk
```

**Roll back a bad update:** Android blocks installing an older `versionCode` over a newer one, so
downgrade explicitly:
```
adb install -r -d RuneMobile-<older-version>.apk      # -d allows version downgrade, keeps data
```
If `-d` is refused, uninstall **keeping nothing** is the last resort (see "full reset" — back up your
token first).

**Recover from a broken state** (won't boot, stuck black screen, corrupted unpack):
1. **Back up your token first** (so you don't have to re-login):
   ```
   adb exec-out run-as dev.audaro.runemobile cat files/tokens.json > tokens-backup.json
   ```
2. **Clear app data** (wipes cache/config/unpacked JVM, keeps the app installed):
   ```
   adb shell pm clear dev.audaro.runemobile
   ```
   > **Note:** clearing data also resets the renderer choice and the GPU-fallback history. A device
   > that had auto-fallen-back to the CPU renderer (after a GPU/117HD crash) will re-attempt the
   > GPU/117HD path on the next boot — and may crash once more before the first-boot watchdog
   > auto-falls-back again. **If a GPU/117HD crash is what you're recovering from, select the CPU
   > renderer** (plugins panel → renderer) right after clearing to avoid the retry.
3. Relaunch (it re-unpacks the JVM and re-downloads the cache on first login). To skip re-login on a
   debug build, push the backup token back:
   ```
   adb push tokens-backup.json /sdcard/Android/data/dev.audaro.runemobile/files/tokens.json
   ```
4. If still broken, **reinstall the previous known-good APK** from the releases page (`-r -d`).

### iOS

**Update:** reinstall the newer build through your sideload tool (AltStore / SideStore); an in-place
reinstall with the same signing identity keeps app data.

**Roll back a bad update:** reinstall the previous known-good build from the releases page through the
same tool. Keeping the app installed preserves the token and cache.

**Recover from a broken state:** delete and reinstall the app via AltStore/SideStore. (This clears
app-sandbox data, so you will re-login and re-download the cache.) Re-attach the JIT debugger on the
next launch as usual.

---

## Pre-publish checklist

- [ ] Release artifact built and **kept downloadable** (prior releases left intact for rollback).
- [ ] **Signing verified** — `apksigner verify --print-certs <apk>` shows SHA-256
      `45:E3:05:…:3C:9E` (matches the **Signing** section above). A build that doesn't is not a
      genuine release; do not promote it. (The release pipeline refuses to publish on a cert
      mismatch — `REQUIRE_RELEASE_KEY=1` — but verify independently by hand regardless.)
- [ ] Disclosure block (above) pasted into the release notes.
- [ ] Known-issues list trimmed to what's true for this build.
- [ ] `versionName` / `versionCode` bumped; `android/CHANGELOG.md` updated.
- [ ] `PRIVACY.md` still accurate (re-check if any data flow changed).
- [ ] Built against the current OSRS revision (no `js5connect_outofdate`).
