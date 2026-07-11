# RuneLite on iOS — the iOS port

This directory is the **iOS half** of the mobile project: an **Objective-C / UIKit**
shell that hosts **real RuneLite** on an embedded, on-device **OpenJDK 21 with JIT**
(per-launch StikDebug attach), rendering live OSRS with the full plugin ecosystem.

- **What the app is, features, risk, privacy:** see the [root `README.md`](../README.md).
- **Installing a released build on a phone** (SideStore/AltStore + StikDebug):
  root `README.md` → **Install — iOS**. The JIT script the guide references is
  tracked at [`app/stikdebug/runelite-jit.js`](app/stikdebug/runelite-jit.js).

## Layout

```
ios/
  app/                     the native app (xcodegen project.yml → RuneMobile.xcodeproj)
    RuneMobile/            Objective-C shell (ViewController, JVMLauncher, panels, login)
    jvm-resources/         staged jars (generated/gitignored: probes.jar, client-shaded.jar, client-rlhd.jar)
    build-probes.sh        builds probes.jar (headless boot entry + CACIO folded in)
    stikdebug/             the per-launch JIT attach script (runelite-jit.js)
  dev-tools/               build/dev tooling (see its subdirectory READMEs)
    JRE21-INVENTORY.md     provenance of the patched arm64 iOS JRE (what jre/ must contain)
    jre/                   the embedded iOS JRE (gitignored; fetched/placed per machine)
    serve-ipa.sh           builds + serves RuneLite.ipa for on-phone sideload install
    DEPLOY-REMOTE.md       remote build-Mac → phone deploy loop
```

## Build from source (macOS)

Prerequisites: **Xcode** (with an Apple ID for signing — a free one works),
**xcodegen** (`brew install xcodegen`), **OpenJDK 21** (`brew install openjdk@21`),
and an arm64 iPhone on **iOS 17.4+**.

1. **Place the iOS JRE.** The embedded runtime is a patched arm64 **Mach-O**
   OpenJDK 21 (iOS needs the `MirrorMappedCodeCache` JIT patch; Android's bionic
   JRE will not work). It is gitignored; put it at `ios/dev-tools/jre/` and check
   it against [`dev-tools/JRE21-INVENTORY.md`](dev-tools/JRE21-INVENTORY.md).
2. **Build + stage the Java runtime** (shaded client jar + `probes.jar`, staged
   into `app/jvm-resources/`) from the repository root:
   ```sh
   tools/stage-mobile-runtime.sh --ios-only
   ```
   (This runs `./gradlew :client:shadowJar` and `app/build-probes.sh` for you.
   `build-probes.sh` fails loudly if the shaded jar is missing — build it first.)
3. **Stage the 117HD renderer jar** (required for the 117HD renderer option):
   ```sh
   ios/dev-tools/gpu-zone/stage-ios-zone-jar.sh      # → app/jvm-resources/client-rlhd.jar
   ```
4. **Generate the Xcode project and build:**
   ```sh
   cd ios/app && xcodegen generate                   # project.yml is the source of truth
   ```
   Open `RuneMobile.xcodeproj`, set your own signing team, and build to the
   device — or build an installable `RuneLite.ipa` with
   `ios/dev-tools/serve-ipa.sh` and install it through SideStore/AltStore.
5. **Enable JIT each launch.** Attach **StikDebug** with
   `app/stikdebug/runelite-jit.js` assigned (root README → *Install — iOS* →
   *Each time you play*). Launching without the attach just waits — that is the
   expected iOS constraint, not a bug.

## Keeping current with upstream RuneLite

```sh
git fetch upstream && git merge upstream/master
```

After an OSRS weekly update the client revision goes stale
(`js5connect_outofdate` / black screen at boot) until this merge + a rebuild.
The fork keeps its additions additive — the shared bridge lives in
`runelite-client/.../headless/`, and the handful of upstream-file seams are
deliberately one-liners — so the merge is normally clean.

## Note

Personal / technical project. A self-built iOS client is **not on Jagex's
approved-client list** for live OSRS — use a **throwaway account**. Full risk,
privacy, and license detail: root `README.md`, `PRIVACY.md`, `SECURITY.md`,
`THIRD-PARTY-NOTICES.md`.
