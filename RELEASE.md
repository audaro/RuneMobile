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
- **Backgrounding on Android can drop the game session.** In the background the Android app idles at a
  slow tick to save battery, and the connection may be cut; on return the automatic re-login runs, and the
  **first** resume-login can occasionally need one retry. iOS keeps the game running in the background
  (a silent audio session plus Picture-in-Picture) while you're logged in.
- **A hot phone runs lighter.** On iOS every renderer lowers its frame rate as the phone warms and goes
  back up once it cools; Low Power Mode holds it to 30 fps (by design — keeps the phone usable). The
  117HD renderer steps its scene-resolution scale down under thermal pressure and restores it on
  cooldown only when Game settings > Lower resolution when hot is on (both ports, off by default); on
  a hot phone with it off, a notice offers to turn it on, at most once a launch.
- **iOS can close a long session for using too much memory.** Seen twice on an iPhone 16 Pro on the GPU
  renderer, after about 50 minutes each time; the cause isn't known yet. Reopen the app and attach
  StikDebug as usual. A Share logs report made after it happens includes the memory readings that will
  help find it.
- **JIT attach (iOS only).** iOS requires re-attaching the debugger (StikDebug) per launch to enable
  JIT; this is an OS constraint, not a bug.
- **The CPU renderer slows as the phone heats up.** It draws the whole game in software, so its frame
  rate is set by how hot the phone is: on a Pixel 7a the same build ran at about 37 fps cool and about
  12 fps hot and charging. Use the GPU renderer where your phone supports it.

---

## Signing

Release builds are signed with a dedicated key (not the debug key). The signing certificate is:

- **Subject:** `CN=RuneMobile, O=RuneMobile`
- **SHA-256:** `45:E3:05:84:4D:53:A6:26:5D:C8:6E:B3:99:BE:99:7A:B3:FA:27:76:F9:0F:18:B1:6F:D4:EC:90:F4:3D:3C:9E`

Every published APK should carry this fingerprint (verify with
`apksigner verify --print-certs <apk>`); a build that doesn't is not a genuine release. **Update-in-place
only works between APKs signed by this same key** — see the rotation warning in
[`android/keystore.properties.example`](android/keystore.properties.example).
The key material lives outside the repo and is never committed; keep the keystore **and** its password
backed up (a lost key means future updates require users to uninstall + reinstall).

The build reads the key through `android/keystore.properties` (gitignored; copy the example and fill it in),
whose `storeFile` resolves relative to `android/`; without that file a release build falls back to the debug
key. In CI, `.github/workflows/release-hosted.yml` builds the APK with the debug key, then a separate `sign`
job that runs none of the build's code re-signs it from the `ANDROID_KEYSTORE_B64` and
`ANDROID_KEYSTORE_PROPERTIES` secrets and refuses an APK that doesn't carry the certificate above. A local
build does the same check with `REQUIRE_RELEASE_KEY=1` (`tools/ci/build-release-artifacts.sh`).

## Versioning

- `versionName` is semver (e.g. `0.1.0`); `versionCode` is derived monotonically
  (`major*10000 + minor*100 + patch`). See `CHANGELOG.md`.
- Every published release keeps its artifact downloadable on the releases page (do **not** delete old
  releases) so users can **roll back** — see recovery below.

## Update check

There is **no in-app update check**, but iOS has a **release feed** — an AltStore/SideStore source:

```
https://github.com/audaro/runemobile/releases/latest/download/altstore.json
```

Added to AltStore it shows the installed version against the newest release and installs updates in one
tap. This matters beyond convenience: AltStore's **"refresh" re-signs the build already installed and
does NOT change its version**, so someone who refreshes to clear a signing problem will believe they
updated when they have not — a stale build is indistinguishable from a fix that did not work. The feed
makes the real version visible on both sides.

The URL resolves to the newest **stable** release (`/releases/latest/` skips prereleases), so the
rolling per-merge builds are never offered as an update. Android has no equivalent feed — **check the
releases page manually**, especially after an OSRS weekly update (a stale client shows a black screen /
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
- [ ] `versionName` / `versionCode` bumped, with `MARKETING_VERSION` in `ios/app/project.yml` to match (the
      release gate checks); `CHANGELOG.md` updated.
- [ ] `PRIVACY.md` still accurate (re-check if any data flow changed).
- [ ] Built against the current OSRS revision (no `js5connect_outofdate`).
- [ ] **iOS Simulator gate green** — `ios/dev-tools/sim-gate.sh` ends `VERDICT: SIM_GATE_GREEN`: the
      simulator build, the iOS bridge census, the screen goldens, each renderer (CPU, GPU, 117HD) booted
      to the login screen, and a log scan with no unexpected lines and no shader errors
      (`ios/dev-tools/sim-gate/README.md`). It needs a Mac with Xcode; the goldens are local to that Mac,
      so a new Mac writes them first with `sim-screens.py --update`.
- [ ] **Shader matrix green** when the release moves the 117 HD pin or changes a shader override or a port's
      shader rewrite: `tools/shader-matrix/run-matrix.sh ios` and `run-matrix.sh android` both end
      `SHADER_MATRIX_GREEN` ([`tools/shader-matrix/`](tools/shader-matrix/README.md)).
- [ ] **Published with `tools/ci/publish-stable-release.sh <tag>`**, not a hand-written
      `gh release create`. The AltStore feed is served from whichever release is Latest, so a stable
      release published without `altstore.json` attached leaves every user pinned to the previous
      version while being told they are up to date. The script refuses to publish a tag that disagrees
      with the built version or a manifest describing a different release, and re-reads the live feed
      afterwards to prove it took. (The rolling publisher deliberately does not upload the manifest —
      prereleases must never be offered as updates.)
