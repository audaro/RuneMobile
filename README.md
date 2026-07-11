# RuneLite on Mobile — iOS & Android (unofficial)

[![License: BSD-2-Clause](https://img.shields.io/badge/license-BSD--2--Clause-blue)](LICENSE)
![Platform: iOS | Android](https://img.shields.io/badge/platform-iOS%20%7C%20Android-lightgrey)
![Distribution: sideload-only](https://img.shields.io/badge/distribution-sideload--only-red)
![Status: pre-release](https://img.shields.io/badge/status-pre--release-orange)
[![Third-party notices](https://img.shields.io/badge/licenses-third--party%20notices-informational)](THIRD-PARTY-NOTICES.md)

> ⚠️ **Unofficial fan project. Not affiliated with, endorsed, sponsored, or approved
> by Jagex Ltd or the RuneLite project.** This is a **sideload-only**, personal /
> technical build. It is **not** on Jagex's approved-client list and **not** on the
> App Store, Google Play, TestFlight, or F-Droid. Logging into live Old School
> RuneScape with an unapproved third-party client can **violate Jagex's Terms of
> Service and carries a real risk of an account ban** — use a **throwaway account
> you can afford to lose, never your main.** Provided **as-is, without warranty, at
> your own risk.** See [Legal notice](#legal-notice) and [Risk & disclaimer](#risk--disclaimer).

A native **iOS and Android** application that runs the **genuine RuneLite client** —
including the **full, unmodified plugin ecosystem** — on an **in-process, on-device
OpenJDK 21**. No streaming, no companion PC, no host machine: the real RuneLite
engine executes on your phone inside a second JVM, rendering **live OSRS**, wrapped
by a thin native shell that provides touch controls and mobile chrome styled after
the official Jagex OSRS Mobile app.

This is **not** a re-implementation, emulator, or skin. It is the authentic RuneLite
engine and its plugins, with a native mobile UI layered on top.

---

## Contents

- [How it works](#how-it-works)
- [Feature overview](#feature-overview)
- [Platform status & supported devices](#platform-status--supported-devices)
- [Expected behaviors (by design)](#expected-behaviors-by-design)
- [Install — Android](#install--android)
- [Install — iOS](#install--ios)
- [StikDebug & the JIT script](#stikdebug--the-jit-script)
- [Logging in](#logging-in)
- [Updating, rollback & recovery](#updating-rollback--recovery)
- [Troubleshooting](#troubleshooting)
- [Build from source](#build-from-source)
- [Architecture](#architecture)
- [Privacy & security](#privacy--security)
- [Legal notice](#legal-notice)
- [License & attribution](#license--attribution)
- [Risk & disclaimer](#risk--disclaimer)

---

## How it works

The mobile process (Android ART / iOS) hosts a **second HotSpot JVM**. Native C++
`dlopen`s the embedded `libjvm.so` / `libjvm.dylib`, calls `JNI_CreateJavaVM`, and
boots **RuneLite headless**. A [Caciocavallo](https://github.com/caciocavallosilano/caciocavallo)
AWT backend drives the engine's `Canvas` / `BufferProvider` off-screen; the rendered
frame is blitted to a native surface, and touch input is mapped back into AWT events.

A single shared Java bridge under `runelite-client/.../headless/` exposes the engine
to the native shell and is reused **verbatim** across the Android (Kotlin / Jetpack
Compose) and iOS (Objective-C / UIKit) ports — only the host shell is platform-specific.

The one meaningful platform difference is **how each OS grants Just-In-Time (JIT)
compilation**, which HotSpot needs to run at full speed:

| | Android | iOS |
|---|---|---|
| **JIT** | Granted by the OS — no extra tooling | Requires a per-launch debugger attach (**StikDebug**) |
| **Install** | Download the APK, install, done | Sideload the `.ipa` with your own Apple ID (SideStore/AltStore) |
| **Ceremony per launch** | None | One tap to attach StikDebug |

The iOS JIT requirement is an **operating-system constraint**, not a defect: Apple
does not permit runtime code generation for sideloaded apps unless a debugger is
attached. StikDebug is the community tool that provides that attach. See
[StikDebug & the JIT script](#stikdebug--the-jit-script).

---

## Feature overview

Everything below runs against the **real** RuneLite plugin models — these are native
UIs over the genuine engine, not mock-ups. Both ports share the same Java data layer,
so features land on both over time; a panel may exist on one port slightly ahead of
the other as parity is closed.

- **Precise engine-resolved touch targeting.** A literal-point tap routes to the
  exact pixel you touch; the engine's own model clickbox resolves the hit and a
  settle gate confirms the real outcome (red ring = interact, yellow = walk, item
  border = inventory). Long-press opens the authentic left-click menu.
- **Full RuneLite plugin ecosystem + native config panel.** The unmodified plugin
  set, with a searchable, touch-friendly bottom sheet: per-plugin toggles, pins,
  config screens, and an on-device **Plugin Hub** browser to install community plugins.
- **Three renderers, selectable in-app.** **CPU** (software), **GPU** (the RuneLite
  GPU plugin), and **117HD** (desktop-grade HD lighting, shadows, water, extended
  draw distance). Accelerated renderers are auto-promoted only after a live GPU
  capability probe, with automatic fallback to CPU on failure. Live quality levers
  (MSAA, scene-resolution scale, anisotropic filtering).
- **World map.** Finger-pan, pinch-zoom, precise tap-to-walk, edge-to-edge with
  chrome auto-hide.
- **Native HUD veneers.** Minimap, and HP / Prayer / Run / Spec orbs as enlarged
  one-tap touch targets; a top-relocated chat with channel pills
  (All / Game / Public / Private / Channel / Clan / Trade) and a real soft keyboard.
- **Native tab grid.** Open any interface tab (Inventory / Prayer / Combat /
  Spellbook / Clan / …) through the genuine menu action.
- **Native info screens.** XP tracker, infoboxes, Grand Exchange, Loot Tracker, time
  tracking, Quest Helper — all reading the real plugin models.
- **RuneLite-account sync (optional).** Sign in to runelite.net and your tuned
  desktop profiles, settings, and hub plugins load automatically.
- **Fast world hopping** via a relog-based hop.
- **Background survival.** iOS keeps a session connected while backgrounded via a
  picture-in-picture path + silent-audio keepalive.

---

## Platform status & supported devices

This is an early **`0.1.0` pre-release.** It is playable, but it is a
single-maintainer, best-effort build and may break after an OSRS weekly update until
a new build is published.

### Android

| | |
|---|---|
| **ABI / SDK** | `arm64-v8a` only · `minSdk 28` (Android 9) → `target 35` (Android 15) |
| **JIT** | Granted by the OS — no extra tooling |
| **Verified on** | Pixel 7a (Mali-G710) and the arm64 emulator, including a 16 KB-page kernel |
| **117HD validated** | Mali-G715 / G78 / G52 and Adreno 740 / 750 driver families |

### iOS

| | |
|---|---|
| **OS** | **iOS 17.4 or newer**, arm64 device, **passcode required** |
| **JIT** | Per-launch debugger attach via **StikDebug** |
| **Signing** | Free Apple ID = app expires every **7 days**, one-tap refresh (no charge, no jailbreak) |
| **Verified on** | iPhone 17 Pro Max (iOS 26.5) |

> On iOS the installed app icon is labelled **RuneMobile** — that is the name to look
> for on your Home Screen and in StikDebug's app list.

---

## Expected behaviors (by design)

A few things this build does deliberately that you might otherwise mistake for bugs:

- **Reconnect is a re-login.** After a disconnect the app automatically clicks back
  through the login flow (bounded attempts) rather than resuming the old session —
  you will see the login screen flash by. If it cannot get back in, a "session
  expired" card asks you to sign in again.
- **Backgrounding on Android can drop the session.** In the background the app idles
  at a slow tick to save battery, and Android/Jagex may cut the connection;
  foregrounding triggers the automatic re-login above. (iOS keeps the session alive
  in the background.)
- **117HD may reduce resolution when the phone runs hot (iOS).** Under sustained
  thermal pressure the HD renderer temporarily lowers its internal resolution scale
  and restores it once the device cools. This is intentional.

---

## Install — Android

Android is the simpler install: **download the APK, install it, done.** No companion
app, no JIT step.

1. **Download** the latest `RuneMobile-<version>.apk` from the
   [Releases page](../../releases).
2. **Allow installs from your source.** When you open the APK, Android prompts you to
   allow installing unknown apps from that browser/file manager — accept it
   (Settings → Apps → Special access → Install unknown apps).
3. **Install and open,** then continue to [Logging in](#logging-in).

**Verify the build is genuine (recommended).** Every official APK is signed with the
project's release key. Confirm the certificate fingerprint before installing:

```sh
apksigner verify --print-certs RuneMobile-<version>.apk
# Expected SHA-256:
# 45:E3:05:84:4D:53:A6:26:5D:C8:6E:B3:99:BE:99:7A:B3:FA:27:76:F9:0F:18:B1:6F:D4:EC:90:F4:3D:3C:9E
```

A build that does not show this fingerprint is **not** a genuine release — do not
install it. This check is only as trustworthy as where you got the fingerprint: read
the expected value from **this repository's own Releases page**, not from a mirror,
fork, or reposted link, so a tampered copy can't hand you a matching APK and
fingerprint together.

**Install via adb (alternative):**

```sh
adb install RuneMobile-<version>.apk
```

---

## Install — iOS

iOS has no store distribution, and Apple does not permit runtime code generation for
sideloaded apps by default. Expect a **one-time ~15-minute setup**, plus a **one-tap
JIT step each time you play.** No jailbreak is required.

### What you need

- An iPhone on **iOS 17.4+** with a **passcode set** (arm64).
- A **computer** (Windows / macOS / Linux) **once**, plus a USB cable.
- An **Apple ID** (a throwaway one is fine — free works).
- A **throwaway OSRS account.**
- From the [Releases page](../../releases): the app **`RuneMobile-<version>.ipa`** and
  the JIT script **`runelite-jit.js`**.

### One-time setup

1. **Make a pairing file** (computer, ~5 min). Plug your iPhone in via USB, run
   [`idevice_pair`](https://github.com/jkcoxson/idevice_pair) (or Jitterbug); it saves
   a small `.mobiledevicepairing` file. AirDrop or email it to your phone.
   ([Full walkthrough.](https://docs.sidestore.io/docs/advanced/pairing-file))
2. **Install [SideStore](https://sidestore.io)** (or AltStore) — the installer that
   signs apps with *your own* Apple ID. Enable **Developer Mode**
   (Settings → Privacy & Security; it prompts a restart), import the pairing file,
   install the **WireGuard VPN** it asks for, and sign in with your Apple ID.
3. **Install the app.** In SideStore, tap **＋** → choose **`RuneMobile-<version>.ipa`**.
   It signs and installs it; the icon (labelled **RuneMobile**) lands on your Home
   Screen.
4. **Install [StikDebug](https://github.com/StephenDev0/StikDebug)** (the JIT enabler)
   through SideStore the same way, plus **LocalDevVPN** (the loopback VPN it uses).
   Open StikDebug once, enter your passcode, and import the **same** pairing file.
5. **Assign the JIT script** — see [StikDebug & the JIT script](#stikdebug--the-jit-script)
   below. This app requires the custom script; StikDebug's default "just connect" will
   not boot it.

### Each time you play

1. Turn on the **LocalDevVPN** toggle.
2. Open **StikDebug**, pick **RuneMobile** (with `runelite-jit.js` assigned), and let
   it **attach** (its log shows `[rl-jit]` lines as JIT switches on).
3. Open **RuneMobile** and tap **Start JVM** — it boots into the game.

> Opening RuneMobile *without* attaching StikDebug first will simply wait — that is
> expected. Attach, and it continues.

### iOS upkeep

- **Every 7 days** (free Apple ID): open SideStore and **Refresh** RuneMobile (it can
  also auto-refresh over the VPN). If it will not open, it is usually just expired.
- **Every launch:** re-enable JIT via StikDebug (above).
- **Only one VPN runs at a time:** use SideStore's VPN to install/refresh, and
  LocalDevVPN to enable JIT — toggle whichever the task needs.

---

## StikDebug & the JIT script

**What StikDebug is.** [StikDebug](https://github.com/StephenDev0/StikDebug) is a
community, on-device debugger for iOS 17.4+. Attaching it to an app grants that app
the `CS_DEBUGGED` state, which is what unlocks JIT (runtime code generation) for a
sideloaded app. Without it, the embedded HotSpot JVM cannot generate executable code
and the client will not boot.

**Why this app needs a *custom* script.** On modern devices with Apple's Trusted
Execution Monitor (TXM), the app cannot map its own executable (RX) memory — the
attached debugger must do it on the JVM's behalf. HotSpot requests its code-cache
memory through a single thunk (`brk #0x69`); StikDebug's stock script only returns a
stub for that request, which HotSpot then tries to execute and crashes. The bundled
**`runelite-jit.js`** provides a real handler: it allocates an RX region of the
requested size, wires it up for TXM execution, returns the address HotSpot expects,
and (on TXM devices that fall back to instruction-abort faults) maps faulting code
pages on demand. It uses only StikDebug's documented builtins — no app-side native
glue.

### Getting the JIT script

The script is maintained in this repository at
[`ios/app/stikdebug/runelite-jit.js`](ios/app/stikdebug/runelite-jit.js) (with a
technical write-up in [`ios/app/stikdebug/README.md`](ios/app/stikdebug/README.md)).
For end users it is **published as a release asset alongside each `.ipa`** on the
[Releases page](../../releases), so you can download the app and the matching script
from one place. Always use the `runelite-jit.js` that ships with the build you
installed.

### Importing & assigning it (one time)

1. Get `runelite-jit.js` onto the phone: **AirDrop** it, or drop it into
   **Files → On My iPhone → StikDebug → `scripts/`**, or use StikDebug's in-app
   **"add / import script"** button.
2. In **StikDebug**, open the app list, select **RuneMobile**, and **assign**
   `runelite-jit.js` as its script. StikDebug stores this per-app mapping, so you only
   do it once.
3. Ensure **LocalDevVPN** is connected before attaching.

### What a healthy attach looks like

- StikDebug's log prints `[rl-jit] attached …`, then one or more
  `[rl-jit] #<n> brk#0x69 size=… -> RX 0x…` lines (one per code-cache reservation).
- RuneMobile reaches the game after you tap **Start JVM**.

If you see **no `[rl-jit]` lines**, the script was not assigned — redo the assignment
step. If StikDebug **won't list or select the script at all**, or the attach aborts
before any `[rl-jit]` line, the file is corrupted or malformed (a partial AirDrop /
edited copy): delete it from `StikDebug/scripts/` and re-import a fresh
`runelite-jit.js` from the release. See [Troubleshooting](#troubleshooting) for more.

---

## Logging in

On first launch, tap **Log in with Jagex**, sign in to your **throwaway account** in
the window that appears, and pick your character. **No credentials or tokens ship in
the app** — you authenticate on-device, and it stays logged in between launches.

Optionally, sign in to your **RuneLite account** (runelite.net — this is *not* your
Jagex login) from the plugins panel to sync your desktop profiles, settings, and hub
plugins.

---

## Updating, rollback & recovery

Updating **never wipes your data** — an in-place reinstall with the same signing
identity keeps your token, cache, config, and renderer choice.

- **There is no in-app update check.** Check the [Releases page](../../releases)
  manually, especially after an OSRS weekly update — a stale client shows a black
  screen / `js5connect_outofdate` until a build against the new revision is published.
- **Android update:** `adb install -r RuneMobile-<version>.apk` (or just open the
  newer APK). **Rollback:** `adb install -r -d RuneMobile-<older>.apk` (`-d` allows the
  version downgrade and keeps data).
- **iOS update / rollback:** reinstall the desired build through SideStore/AltStore
  with the same identity.

Full recovery steps (broken state, token backup, clearing app data, GPU-crash
recovery) are in [`RELEASE.md`](RELEASE.md).

---

## Troubleshooting

**iOS**

| Symptom | Cause / fix |
|---|---|
| App won't launch / just waits | JIT not enabled. Turn on LocalDevVPN, attach StikDebug, then tap **Start JVM**. |
| Attaches but crashes, no `[rl-jit]` log lines, or StikDebug won't list/select the script | Script not assigned, or the file is corrupted/malformed — delete it from `StikDebug/scripts/` and re-import a fresh `runelite-jit.js`, then re-assign it to RuneMobile. |
| "Unable to install" in SideStore | SideStore's VPN must be on and you must be signed into your Apple ID. |
| Can't enable Developer Mode | Set a device passcode first, then Settings → Privacy & Security. |
| App stopped opening after a while | Free-signing expired (7 days). Refresh in SideStore. |
| Two VPNs conflict | Only one runs at a time — SideStore's VPN to install/refresh, LocalDevVPN to enable JIT. |

**Android**

| Symptom | Cause / fix |
|---|---|
| "App not installed" | Enable "Install unknown apps" for your browser/file manager; ensure `arm64-v8a`. |
| Black screen / `js5connect_outofdate` | OSRS updated; the build is stale — install a newer release. |
| Session drops when backgrounded | Expected; foreground the app to trigger the automatic re-login. |

---

## Build from source

A fresh clone does **not** contain the embedded JRE or the client jars — they are
gitignored and regenerated by tracked, SHA-pinned staging scripts. The native
libraries build automatically from tracked C++ source via Gradle/CMake/Xcode.

> The embedded JDK is fetched from a single third-party host at a pinned SHA — mirror
> it if you depend on reproducible builds.

### Android

From the repository root, in order (order is load-bearing — see
[`android/README.md`](android/README.md)):

```sh
tools/stage-android-jre.sh                            # SHA-pinned arm64 OpenJDK 21 -> assets/jvm/jre
./gradlew :client:shadowJar                           # shaded client jar (gpu/rlhd/probes build from it)
( cd ios/app && ./build-probes.sh )                   # probes.jar (on the Android boot classpath)
android/dev-tools/gpu/stage-android-gpu-jar.sh        # -> client-<ver>-gpu.jar
android/dev-tools/gpu/stage-rlhd-zone-jar.sh          # -> client-<ver>-rlhd.jar  (117HD)
tools/stage-mobile-runtime.sh --no-build --android-only  # fold SHAs into runtime.tag
cd android && ./gradlew :app:assembleRelease          # never bare `assemble`
```

The GPU and 117HD jars are required — omitting them produces an un-bootable APK.

### iOS

See [`ios/README.md`](ios/README.md) for the full pipeline. In short: the iOS JRE is
Mach-O (separate from Android's bionic JRE), the Xcode project is produced by
`xcodegen` from `ios/app/project.yml`, and the jars come from the same staging scripts
as Android.

**Signing:** set your Apple Developer Team ID in `ios/dev-tools/signing.env`
(gitignored — `export DEVELOPMENT_TEAM=XXXXXXXXXX`); the build scripts source it and
`xcodegen` expands `${DEVELOPMENT_TEAM}` into the project.

---

## Architecture

```
 ART / iOS process
   └─ native shell (Kotlin+Compose / ObjC+UIKit) ── SurfaceView / CAEAGL host
        └─ C++ bootstrap: dlopen libjvm → JNI_CreateJavaVM
             └─ embedded OpenJDK 21 (HotSpot, JIT)
                  └─ stock RuneLite (headless) + Caciocavallo AWT
                       └─ headless/* bridge ──► shared verbatim across both ports
```

The native UI thread is **never** attached to the embedded JVM. R8 / minification is
intentionally off. The mobile project lives under `ios/`, `android/`, and the shared
`runelite-client/.../headless/` bridge package; the rest of the tree
(`runelite-client/`, `runelite-api/`, …) is upstream RuneLite, updated by merging
`runelite/runelite` and carried with a deliberately small set of additive fork seams
(the headless boot/UI override, bridge hooks in about a dozen upstream files, and the
mobile privacy gates described in [`PRIVACY.md`](PRIVACY.md)).

---

## Privacy & security

- **No telemetry, no analytics, no crash reporting, no maintainer backend.** Your
  account and gameplay data go only to **Jagex** (to play) and, *only if you opt in* —
  by signing into RuneLite-account sync or enabling the (default-off) Loot Tracker /
  Chat Commands plugins — to the **RuneLite project**. The client also makes a few
  read-only fetches (world list, item prices, runtime config) from RuneLite's CDN/API
  that carry no account data. See [`PRIVACY.md`](PRIVACY.md).
- Report security issues via the private channel in [`SECURITY.md`](SECURITY.md).

---

## Legal notice

This section is informational and is **not** legal advice.

- **No affiliation.** This project is an independent, unofficial work. It is not
  affiliated with, authorized, maintained, sponsored, or endorsed by **Jagex Ltd**,
  the **RuneLite** project, **Apple Inc.**, **Google LLC**, or any of their
  subsidiaries or affiliates.
- **Trademarks.** *RuneScape®* and *Old School RuneScape®* are trademarks of Jagex
  Ltd. *RuneLite* is a trademark of the RuneLite project. *Apple*, *iOS*, and
  *App Store* are trademarks of Apple Inc.; *Android* and *Google Play* are trademarks
  of Google LLC. All trademarks are the property of their respective owners and are
  used here **nominatively**, for identification and reference only; such use does not
  imply any endorsement or affiliation.
- **Game content is not licensed by this project.** RuneScape and Old School RuneScape,
  and all in-game art, audio, and data the client renders, are the intellectual
  property of Jagex Ltd and are **not** covered by this project's license. This
  repository ships **no** Jagex art or game assets; like the desktop client, the app
  streams that content live from your own authenticated game session at runtime.
- **Terms of Service.** Old School RuneScape is governed by Jagex's Terms of Service
  and EULA. Using an unapproved third-party client may breach those terms and result
  in **suspension or permanent banning** of the account used. **You alone are
  responsible** for how you use this software and for any consequences to your account.
- **Interoperability & purpose.** This project is provided for education, research,
  and personal interoperability with software the user already has a right to use. It
  contains no cheats, automation, or botting, and is not intended to circumvent any
  technological protection measure.
- **Your responsibility.** You are responsible for complying with all applicable laws,
  the terms of the game, and the terms of your app-signing and sideloading tools in
  your jurisdiction.
- **Rights-holder requests.** Good-faith requests from a rights holder regarding this
  repository can be sent through the contact in [`SECURITY.md`](SECURITY.md).
- **No warranty / no liability.** The software is provided **"AS IS", without warranty
  of any kind**, express or implied, including but not limited to the warranties of
  merchantability, fitness for a particular purpose, and non-infringement. In no event
  shall the author be liable for any claim, damages, or other liability arising from
  the software or its use. See [`LICENSE`](LICENSE).

---

## License & attribution

This project's own code is licensed under the **BSD 2-Clause License** (see
[`LICENSE`](LICENSE)). Bundled and build-time third-party components — including the
GPLv2-with-Classpath-Exception OpenJDK and Caciocavallo runtimes (fetched at build,
not in-tree) and the chat fonts — are listed in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).

RuneScape and Old School RuneScape, and the in-game art the client renders, are the
property of **Jagex Ltd** and are **not** covered by this license. RuneLite streams
that art live from the official game cache; it is not committed here. The native
mobile chrome (tab stones, skill icons, chat-tab buttons) is likewise **not**
committed — exactly like the desktop client, it renders those interface sprites from
your own live game cache at runtime, so no Jagex art ships in this repository.

---

## Risk & disclaimer

A self-built mobile client is an **unapproved third-party client** on live OSRS
(Jagex's approved list is desktop-only). Using it:

- **Risks account bans** (temporary to permanent). **Use a throwaway account, never
  your main.**
- Is **provided as-is**, best-effort, single-maintainer, **with no warranty**, and may
  break after any OSRS update until a new build is published.
- Is **sideload-only** — not on the App Store, Google Play, TestFlight, or F-Droid,
  and never will be. You install it yourself, on your own device, at your own risk.

This is a personal / technical-achievement project. Use it at your own risk.
