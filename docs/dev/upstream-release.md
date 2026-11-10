# Upstream merges and releases

Rune Mobile is a fork of RuneLite, and it stops working on live OSRS soon after each game update until upstream
RuneLite is merged and new game files ship, either as a game-update set (0.10.0 and later, below) or in a new
build. This page covers that merge from start to push, the checks
that prove it worked, and how builds become releases: the rolling prerelease every push to `master` produces, and
the tagged stable releases the AltStore feed follows.

It assumes a machine set up as in [setup.md](setup.md). The full gate ladder is in [testing-qa.md](testing-qa.md);
this page lists only the steps a merge or a release needs.

## Where the versions live

Several versions move independently. Read each from its source; any number written into a doc, this one included,
goes stale with the next merge.

| What | Where it is set | How to read it |
|---|---|---|
| RuneLite base version | `project.build.version` in `gradle.properties` | `sed -n 's/^project\.build\.version=//p' gradle.properties` |
| Game revision | Upstream's `cache: rev NNN` and `Update GameVals to ...` commits | `git log -1 --format='%h %s' --grep='^cache: rev' HEAD` (and `--grep='^Update GameVals'`) |
| App version (both ports) | `verMajor`, `verMinor`, `verPatch` in `android/app/build.gradle.kts` | Read the file; `CHANGELOG.md` names each released version. |
| 117 HD (RLHD) source | `RLHD_REV` in both 117 HD stagers | `grep -h '^RLHD_REV=' android/dev-tools/gpu/stage-rlhd-zone-jar.sh ios/dev-tools/gpu-zone/stage-ios-zone-jar.sh` |
| Plugin Hub version | `runelite.pluginhub.version` in `runelite-client/src/main/resources/net/runelite/client/runelite.properties` | See [The Plugin Hub pin](#the-plugin-hub-pin). |

Run the game-revision query against `upstream/master` instead of `HEAD` to see what a merge would bring in.

**Why the base version matters.** The client loads the injected game client published for its own
`project.version` (`runtimeOnly("net.runelite:injected-client:${project.version}")` in
`runelite-client/build.gradle.kts`). The game revision a build speaks is fixed when it is built. After a weekly game
update the server refuses the old revision, and every existing build stops at the login screen with
`error_game_js5connect_outofdate`, which looks like a black screen. No setting fixes it; only a merge and a new build
do.

## When to merge

- **After an OSRS weekly update**, as soon as upstream has the new revision. The symptom on a phone is the black
  screen or `js5connect_outofdate` in the log.
- **When the `upstream-sync` workflow fails.** `.github/workflows/upstream-sync.yml` polls `runelite/runelite` every
  six hours and fails, which emails the repository owner, whenever upstream `master` is ahead. It only notifies. It
  never merges and holds no token, on purpose: an automatic merge feeding a build that decodes the release signing
  key would let a single unreviewed upstream commit reach that key. The merge is a reviewed manual step.
- **Otherwise, regularly.** Small merges are easier to review and to bisect than one large one.

## Shipping a revision without a release

From 0.10.0 on, both apps take a signed set of new game jars made for their exact build (iOS
`RMGameUpdate.m`, Android `GameUpdate.kt`), so a revision bump that needs no native change ships without a
release. A set is keyed by the full commit the release was built from, which the apps stamp at build time and
the stable release's tag names.

1. In a worktree at the latest stable release (`git worktree add ../rm-update v0.10.0`), merge upstream, stage
   both ports and run the gates exactly as in the steps below.
2. Build and sign the manifest (the signing key stays on the maintainer's Mac):
   `tools/game-update/make-manifest.py --out DIR --revision N --required --base-url
   https://github.com/audaro/runemobile/releases/download/game-update/ --ios-shell <release commit>
   --android-shell <release commit>`. `N` must be above the live manifest's revision: a phone refuses
   anything older than what it has seen. The jars come from the worktree's staged ones. If the merge moved the
   Plugin Hub pin, add `--hub-pin <version>`: iOS sets the pin from native code, while Android reads it from the
   client jar.
3. `tools/game-update/publish.sh DIR` checks everything and says what it would change; `--apply` uploads the
   jars, then the manifest, and reads the live copy back.

Phones check at launch, and every five minutes while the "Old School RuneScape has updated" card is up. Each
start re-checks the signature and every jar's hash, and a set that twice fails to reach its first frame is
dropped for the jars the app shipped with. Test a set first against a debug build with
`tools/game-update/serve-local.sh`.

## The merge, step by step

Run everything from the repository root on `master`.

### 0. Preflight

```sh
git status --short                  # must be clean
git config core.hooksPath           # expect tools/git-hooks; else run tools/git-hooks/install.sh
sed -n 's/^project\.build\.version=//p' gradle.properties    # note the version you start from
```

### 1. Merge

```sh
git fetch upstream
git merge upstream/master
```

While a merge is in progress the pre-commit hook skips its added-line text scan (that text is upstream's), but it
still runs the shared-contract check when `runelite-client/` files are staged, and blocks on a contract change
without a refreshed baseline.

### 2. Resolve conflicts and fix API breaks inside the merge commit

Look at the upstream files this fork edits first; they are where conflicts land:

```sh
git diff --name-status upstream/master...HEAD -- runelite-client
```

If upstream renamed or changed an API the bridge uses, fix the bridge in the merge commit itself, so every commit on
`master` builds. A past example: upstream's `http-api` dropped `World.getLocation()` for a `WorldRegion` enum, and
the merge commit carried the matching `WorldSwitcherBridge` change (`getRegion().getId()`, which keeps the same
wire value).

### 3. Build and run the bridge tests

```sh
./gradlew :client:shadowJar
./gradlew :client:test --tests 'net.runelite.client.headless.*'
```

A clean compile is not proof the merge is right; see [A clean compile is not proof](#a-clean-compile-is-not-proof).

### 4. Check the cross-port contracts

```sh
tools/shared-contract/check-contract.sh        # 0 unchanged, 1 additive, 2 removed or changed
tools/shared-contract/check-auth-contract.sh
```

If the bridge surface changed, run both bridge censuses before you accept the new baseline. They prove that every
JNI lookup the native code makes still resolves against the new jar:

```sh
android/dev-tools/bridge-census/run-census-desktop.sh       # expect ANDROID_BRIDGE_CENSUS_GREEN
ios/dev-tools/bridge-census/run-census-sim.sh --jars        # expect IOS_BRIDGE_CENSUS_GREEN
tools/shared-contract/check-contract.sh --update
git add tools/shared-contract/baseline.txt
```

[`tools/shared-contract/README.md`](../../tools/shared-contract/README.md) explains the exit codes and how to clear a
breaking change. [bridge-api.md](bridge-api.md) explains the contract itself.

### 5. Review the Plugin Hub pin

```sh
tools/shared-contract/check-hub-pin.sh
```

It fails once the base version passes the last reviewed one. [The Plugin Hub pin](#the-plugin-hub-pin) says what to
do.

### 6. Re-stage Android, by hand

```sh
( cd ios/app && ./build-probes.sh )
android/dev-tools/gpu/stage-android-gpu-jar.sh
android/dev-tools/gpu/stage-rlhd-zone-jar.sh
tools/stage-mobile-runtime.sh --no-build --android-only
```

Don't rely on the Gradle build to do this. Its self-staging tasks skip whenever a jar named for the current version
exists, so a merge that stays on the same `-SNAPSHOT` would ship last week's jars with no error
([setup.md](setup.md#androids-gradle-self-staging-and-when-it-lies)). The Android stagers delete jars of other
versions themselves.

### 7. Re-stage iOS

```sh
( cd ios/dev-tools/gpu-routec && ./stage-ios-gpu-jar.sh )
( cd ios/dev-tools/gpu-zone && ./stage-ios-zone-jar.sh )
( cd ios/dev-tools/gpu-routec/l1 && ./build-l1-probe.sh )
tools/stage-mobile-runtime.sh --check
```

Never run `tools/stage-mobile-runtime.sh` without `--android-only` or `--check` here: it would overwrite the iOS
`client-shaded.jar` with the pristine jar and kill the iOS GPU renderer
([setup.md](setup.md#ios)). Step 6 already rebuilt `probes.jar`, which both ports share.

If either 117 HD stager fails, see [117 HD after a merge](#117-hd-after-a-merge).

### 8. Run the gates

```sh
./android/dev-tools/ci/release-gate.sh --contract-only    # what the hosted pipeline runs first
./android/dev-tools/ci/release-gate.sh --skip-build       # contracts, hub pin, linters, bridge tests, lintRelease
ios/dev-tools/sim-gate.sh                                  # expect VERDICT: SIM_GATE_GREEN (about 10 minutes)
```

The Simulator gate builds the iOS app from the jars you just staged, reruns the iOS census, checks the screen
goldens and the plugin sweep, boots the CPU, GPU and 117 HD renderers to the login screen, and fails on any log line
not on the known-noise list or any shader error. A merge that changes something the shaders depend on usually shows
up there first. If the merge touched anything the 117 HD shaders read, also run the shader matrix for both ports:

```sh
tools/shader-matrix/run-matrix.sh ios         # expect SHADER_MATRIX_GREEN
tools/shader-matrix/run-matrix.sh android
```

Run the full `release-gate.sh` (it also builds and verifies a signed release APK) before any release.

### 9. Check on a device

Install on a phone of each port and log in with a throwaway account. The client must reach the logged-in game, not
stop at `js5connect_outofdate`. The Simulator can log in too (`ios/dev-tools/run-sim.sh --desktop-login`), but a
phone is the check that counts for a release.

### 10. Changelog and version

Add a `CHANGELOG.md` entry under `## [Unreleased]` that names the RuneLite version the build now reports and anything
user-visible upstream brought in. For example:

```markdown
- **Rebuilt on RuneLite 1.13.5-SNAPSHOT,** the line following Release 1.13.4. The Plugin Hub list moves up to the
  1.13.4 release, so plugins updated for it install.
```

Bump `verPatch` in `android/app/build.gradle.kts` when the merge is going out as a release on its own, and
`MARKETING_VERSION` in `ios/app/project.yml` to match (the release gate fails until the two agree).

### 11. Push

Push `master` to the public repository. That push is the release: it builds both apps and publishes a rolling
prerelease ([Rolling prereleases](#rolling-prereleases)). If you keep a private working remote as well, pushing there
builds nothing.

### Conflict hot-spots

The fork's edits to upstream files are small, but upstream edits the same files. These are the ones to look at
first in any conflict:

| Area | Files |
|---|---|
| Client boot and UI | `RuneLite.java`, `ui/ClientUI.java`, `ui/SplashScreen.java`, and the fork's own `ui/HeadlessClientUI.java` (which subclasses `ClientUI`, so it breaks when `ClientUI` changes) |
| Engine callbacks | `callback/Hooks.java` |
| Plugins and config | `plugins/PluginManager.java`, `config/ConfigManager.java`, `plugins/entityhider/EntityHiderPlugin.java` |
| Overlays | `ui/overlay/OverlayRenderer.java`, `ui/overlay/SnapCorner.java` |
| Platform seams | `Notifier.java`, `util/LinkBrowser.java`, `rs/RSAppletStub.java`, `account/AccountClient.java` |
| Build and resources | `runelite-client/build.gradle.kts`, `runelite.properties`, `config/checkstyle/suppressions.xml` |
| Repository files | `.github/workflows/CI.yml`, `.github/CONTRIBUTING.md`, `.github/ISSUE_TEMPLATE/*`, `README.md`, `LICENSE` |

All paths under `runelite-client/src/main/java/net/runelite/client/` unless shown otherwise. The diff command in step
2 lists the current set; this table goes stale as edits come and go.

When you resolve one of these, keep the fork's side as small as the original edit was. If a conflict tempts you to
move logic into the upstream file, put it in `headless/` and leave a one-line seam instead.

### A clean compile is not proof

Upstream sometimes changes what an API means without changing its shape. In game revision 239, the camera
`getMapAngle` accessor became `getCameraYaw`, and yaw widened from 11 to 14 bits. The rename alone compiled, and
every camera-dependent value was wrong by a factor of eight: the bridge needed `getCameraYaw() >> 3`, and the
sensitivity, pitch clamp and wrap mask had to scale with it. 117 HD's alpha sorting needed the same fix in both
ports' overlays until 117 HD read the fixed-point angles itself.

So after a merge that touches anything the bridge reads (camera, widgets, menus, scene), look at the upstream commit
messages and diffs for those APIs, not only at whether the build is green. The bridge unit tests and the censuses
catch shape changes; only reading, the harness frames and a device catch meaning changes.

## 117 HD after a merge

117 HD is built from source at a pinned commit (`RLHD_REV` in both stagers), and **an upstream merge never moves that
pin**. What a merge can do is change the RuneLite API that 117 HD compiles against.

Each port lays its own full-file copies of a few 117 HD sources over the pinned tree before compiling:

| Port | Java overrides | Shader overrides |
|---|---|---|
| Android | `android/dev-tools/gpu/java-overlay/` | `android/dev-tools/gpu/shader-overlay/` |
| iOS | `ios/dev-tools/gpu-zone/java-overrides/` | `ios/dev-tools/gpu-zone/ios-overrides/` |

Because they are whole files, they don't pick up upstream fixes and they break where pristine 117 HD would too. The
common failure: upstream adds a method to an interface 117 HD implements (precedent: a new method on `Model`, which
117 HD's model cache implements). The 117 HD stager then prints the `javac` errors and exits 2. To fix it:

1. If the failing file is one of the overrides, refresh it from the pinned 117 HD source and re-apply the fork's
   change (the overlay READMEs list what each override changes, for example
   [`android/dev-tools/gpu/java-overlay/README.md`](../../android/dev-tools/gpu/java-overlay/README.md)). Do it for
   both ports when both carry the file.
2. If the failing file is pristine 117 HD, the fix is a new override (or a deliberate pin bump, which is its own
   change with its own checks, not part of a merge).
3. Re-stage, then run the shader matrix for both ports and the Simulator gate.

**Lombok.** The 117 HD stagers compile with the Lombok version pinned in `libs.versions.toml`, looked up in the
Gradle cache that `:client:shadowJar` populates. If upstream bumps Lombok, run `:client:shadowJar` before the
stagers. When the pinned jar isn't in the cache, they fall back to the newest cached 1.18.x, which may not be the
version the client was built with, and stop with "lombok jar not found" only when there is none at all. An old
1.18.x crashes JDK 21's `javac` (`NoSuchFieldError JCTree$JCImport.qualid`), so a crash like that after a merge
usually means the stager picked the wrong Lombok.

[renderers.md](renderers.md) covers the 117 HD port, the overrides and how to move the pin.

## The Plugin Hub pin

The Plugin Hub serves plugin manifests for **released** RuneLite versions only, and this client is always a
`-SNAPSHOT`, so the fork pins the hub to a release. `git merge` never touches that pin, so without a check a stale pin
would ride every merge forward unnoticed. `tools/shared-contract/check-hub-pin.sh` is that check: it fails once
`project.build.version` (minus `-SNAPSHOT`) passes `reviewed_project_version` in
[`tools/shared-contract/hub-pin.ack`](../../tools/shared-contract/hub-pin.ack). The release gate runs it, including
the `--contract-only` pre-flight the hosted build runs.

When it fails:

1. Probe the endpoints with the client's exact URL shapes, as the dated entries in `hub-pin.ack` do: the manifest at
   `repo.runelite.net/plugins/manifest/<v>_full.js`, and a POST to `api.runelite.net/runelite-<v>/pluginhub`.
2. Pin the hub to the **newest release this tree has merged**. Never a `-SNAPSHOT` (its manifest doesn't exist),
   and never a release you haven't merged: a plugin built against it can call API this client lacks.
3. To move the pin, change three values together: `runelite.pluginhub.version` in `runelite.properties`,
   `-Drunelite.pluginhub.version=` in `ios/app/RuneMobile/JVMLauncher.m`, and `pinned_hub_version` in the ack.
4. Add a dated entry to the ack and set `reviewed_project_version`, whether or not the pin moved.

`runelite.api.base` is a different service and must stay `${project.version}`; the check fails if it is pinned to a
literal.

**Rebuild after editing `runelite.properties`.** Changing it re-runs the resource processing, and Gradle can then drop
the build-generated `runelite/index` and assembled scripts from the jar, while the tasks that produce them stay up to
date. The jar builds and the client dies at boot with a black screen. Re-run `./gradlew :client:shadowJar` and
restage. On iOS, `ios/app/scripts/check-staged-jar.sh` fails the Xcode build when those resources are missing.

## Releases

### Remotes and what a push does

The public repository, [audaro/runemobile](https://github.com/audaro/runemobile), is the one that builds and
publishes. Its release workflow only runs on that repository's `master` (it checks the repository id), so:

- a push to its `master` builds both apps and publishes a rolling prerelease;
- a push to any other branch, any fork or any other remote builds nothing;
- a pull request runs only upstream's `CI.yml` build, never the signing build.

A maintainer may keep a separate private remote for work in progress. That is a personal choice; nothing in the
release path depends on it.

### Rolling prereleases

`.github/workflows/release-hosted.yml` runs on every push to `master` of the public repository, as three
GitHub-hosted jobs. Only `sign` sees the signing key and only `publish` can write to the repository, and neither runs
the build's third-party code ([`tools/ci/README.md`](../../tools/ci/README.md) has the reasoning):

1. **Skip rules.** A push that only changes Markdown files, `LICENSE`, `upstream-sync.yml` or `CI.yml` builds nothing
   (`paths-ignore`). A newer push cancels a build still running (`cancel-in-progress`).
2. **Pre-flight** (`build`, macOS). `./android/dev-tools/ci/release-gate.sh --contract-only`: the shared contract, the
   auth contract and the hub pin.
3. **Inputs** (`build`). It downloads the iOS JRE from the `ios-jre-dep` release asset and stops unless its sha256
   matches `IOS_JRE_SHA256` in the workflow ([Hosted build inputs](#hosted-build-inputs)).
4. **Build** (`build`). `tools/ci/build-release-artifacts.sh` with no secrets: the APK is signed with the debug key,
   and the IPA is built unsigned and then ad-hoc sealed (`IOS_ADHOC=1`). AltStore and SideStore re-sign the IPA on the
   phone at install, so no Apple certificate, profile or team is ever uploaded.
5. **Sign** (`sign`, Linux). With no checkout, it re-signs the APK with the release key using the runner's
   `apksigner` and fails unless the APK carries the release certificate.
6. **Publish** (`publish`, Linux). `tools/ci/publish-rolling-release.sh` creates a draft prerelease tagged
   `master-<N>` on the commit that was built, uploads every asset to it, then publishes it in one step, so nobody ever
   sees a half-uploaded release. Only the newest few rolling prereleases are kept. Stable `v*` releases are never
   touched.

Rolling builds are versioned `<semver>-master.<N>+<sha>`, where `<N>` is the workflow run number plus 1000, and get
an Android `versionCode` of `1_000_000 + <N>`. That keeps rolling builds monotonic, and it has a side effect: every
rolling APK has a higher `versionCode` than any stable release, so going from a rolling build back to a stable one is
a downgrade on Android (`adb install -r -d`, see [RELEASE.md](../../RELEASE.md#android)).

The workflow runs only the contract pre-flight of the release gate. The linters, the bridge tests and `lintRelease`
run only when you run the gate yourself, so run the full gate before pushing anything meant as a release.

[`tools/ci/README.md`](../../tools/ci/README.md) has the design notes behind each of these choices.

### Stable releases

A stable release is a tagged `v<semver>` release marked Latest. The AltStore/SideStore feed is served from
`/releases/latest/download/altstore.json`, which resolves to the newest **non-prerelease**, so only stable releases
are ever offered to users as updates.

1. **Gate.** Run the full `./android/dev-tools/ci/release-gate.sh`, `ios/dev-tools/sim-gate.sh`, and the shader
   matrix if the release moves the 117 HD pin or changes a shader override.
2. **Version and changelog.** Set `verMajor`/`verMinor`/`verPatch` in `android/app/build.gradle.kts`. Move the
   `## [Unreleased]` entries in `CHANGELOG.md` under `## [x.y.z] - YYYY-MM-DD`. The AltStore feed shows that section
   as "What's new". Commit both as `release: x.y.z`.
3. **Push** `master` to the public repository (this also produces a rolling prerelease of the same commit).
4. **Tag** the release commit `v<x.y.z>` and push the tag to the public repository.
5. **Build the artifacts** on a Mac that holds the release signing inputs, with no build number, so the version is
   the plain semver:

   ```sh
   REQUIRE_RELEASE_KEY=1 tools/ci/build-release-artifacts.sh
   ```

   The script reads its inputs from `CI_CONFIG_DIR` (default `~/.runemobile-ci/`): `keystore.properties`,
   `signing.env`, and a seed copy of the iOS JRE in `ios-jre/` if `ios/dev-tools/jre/` is absent. It ad-hoc-seals
   the IPA, as the hosted build does. `IOS_ADHOC=0` signs it with your `DEVELOPMENT_TEAM` instead, but that IPA
   embeds your provisioning profile, which carries your name, Apple ID email, team ID and the UDID of every
   provisioned device, so keep it for local use: both publish scripts refuse it. It writes
   `dist/ci/RuneMobile-<version>.{apk,ipa}`, `runelite-jit.js`, `manifest.env` and, when an IPA was built,
   `altstore.json` (via `tools/ci/make-altstore-source.sh`).
6. **Write the release notes**: the disclosure block from [RELEASE.md](../../RELEASE.md#release-page-disclosure-paste-into-every-release),
   the known issues that apply to this build, and the changelog section.
7. **Publish** with the script, never with a hand-written `gh release create`:

   ```sh
   tools/ci/publish-stable-release.sh v<x.y.z> --notes-file <notes.md>
   ```

   It refuses a tag that disagrees with the built version or an `altstore.json` that describes another release,
   uploads the APK, the IPA, the feed and `runelite-jit.js`, marks the release Latest, then re-reads the live feed
   (for up to a minute, since it sits behind a CDN) until it serves the new version. A stable release published
   without its feed leaves every AltStore user on the old version while telling them they are up to date.

Work through the [pre-publish checklist in RELEASE.md](../../RELEASE.md#pre-publish-checklist) as you go.

### Signing

Every published APK must be signed with the project's release key. The certificate's subject and SHA-256 fingerprint
are in [RELEASE.md](../../RELEASE.md#signing). Check each APK yourself, even though the build already enforces it:

```sh
apksigner verify --print-certs dist/ci/RuneMobile-<version>.apk
```

A build that doesn't show that fingerprint is not a genuine release; don't publish it. Android only updates an app
in place when the signature matches, so a release signed with any other key can't update existing installs, and a
lost key means every user has to uninstall and reinstall. Keep the keystore and its password backed up outside the
repository.

### Hosted build inputs

The hosted workflow needs two things the repository can't hold, set up once with:

```sh
tools/ci/setup-hosted-secrets.sh
```

It needs `gh` logged in with admin rights on the public repository. It reads the keystore and its properties from
`CI_CONFIG_DIR`, sets them as the Actions secrets `ANDROID_KEYSTORE_B64` and `ANDROID_KEYSTORE_PROPERTIES` (the
`sign` job reads only the passwords and alias from the latter), and uploads the patched iOS JRE as the `ios-jre-dep`
release asset. That JRE is patched local state rather than something a URL reproduces, so the hosted build downloads
it instead of building it. Re-run the script after you rotate the key or rebuild the JRE. After a JRE upload it prints
the new sha256: set `IOS_JRE_SHA256` in `.github/workflows/release-hosted.yml` to it, since every hosted build stops at
the JRE fetch until the pin matches.

Branch protection on `master` is what makes the key-bearing build run only on reviewed code; the workflow's
repository check alone controls where it runs, not what. `tools/ci/README.md` describes the protection to configure
before anyone else gets write access.

### Rollback

Never delete a published release: older builds stay downloadable so users can roll back. Android needs an explicit
downgrade (`adb install -r -d`); iOS users reinstall the older IPA through their sideload tool.
[RELEASE.md](../../RELEASE.md#update-rollback--recovery) has the user-facing steps.

To withdraw a bad stable release, ship a new patch version that reverts the change. Both update paths only move
forward: Android refuses a lower `versionCode` without `-d`, and marking an older release Latest does not move anyone
who already installed the newer one.

## Installing a dev build away from home

An iOS install has to originate on the phone's own network. `lockdownd` answers an install request that arrives over
the LAN and resets the same request when it arrives through a VPN interface, so a Mac can't push a build straight to
a phone over a VPN. Two tracked scripts work around that; both assume a private network you control between your Mac
and your phone, such as your own Tailscale tailnet.

**Let the phone pull the build.** `ios/dev-tools/serve-ipa.sh` builds a development-signed IPA and serves it over
HTTPS with `tailscale serve`, in two forms: an install page you open in Safari on the phone (an `itms-services`
manifest, which iOS only accepts over trusted HTTPS), and a SideStore source (`apps.json`) you add once. The
install page keeps Xcode's development signature, so StikDebug still attaches for JIT.

```sh
ios/dev-tools/serve-ipa.sh            # reuse the staged jars, build, serve
ios/dev-tools/serve-ipa.sh --jars     # rebuild the jars first
ios/dev-tools/serve-ipa.sh --stop     # stop the server and remove only this script's handler
```

Before it serves anything, the script checks that the signature verifies, that the profile is current and lists your
devices, and that it carries `get-task-allow`. iOS refuses an install it can't verify without saying why, so these
checks are the only diagnosis you get. It stamps the build `<release semver>.<counter>`, above the release on the
phone, so SideStore offers it as an update. The counter lives in a gitignored file: on a fresh clone the script warns
and starts at 1, and you may need to set it higher. The local server is not a daemon, so re-run the script after a
reboot.

**Build on a Mac that sits next to the phone.** `ios/dev-tools/deploy-remote.sh` builds the jars on your Mac, copies
the tree to a second Mac on the phone's LAN, and runs `ios/dev-tools/remote-build.sh` there (xcodegen, xcodebuild,
`devicectl install`). Configure it by copying `ios/dev-tools/deploy-remote.conf.example` to `deploy-remote.conf`
(gitignored). [`ios/dev-tools/DEPLOY-REMOTE.md`](../../ios/dev-tools/DEPLOY-REMOTE.md) has the details. When the Mac
you are on can see the phone itself, run `remote-build.sh` directly.

Android has no such constraint: `android/dev-tools/deploy-wireless.sh` installs over wireless debugging, on the same
network or across a tailnet.

## Commit conventions

These match [CONTRIBUTING.md](../../CONTRIBUTING.md#pull-requests):

- Commit under your own name, in plain prose. The subject is `<area>: <what changed>` in lower case, where the area is
  the part of the tree or the feature (`ios`, `android`, `headless`, `shells` for both native hosts, `tools`, `docs`,
  `input`, and so on; `git log --oneline` shows the ones in use). The body says why, in full sentences.
- Release commits are `release: x.y.z`. Upstream merges keep git's default message
  (`Merge remote-tracking branch 'upstream/master'`), with any API fixes inside the merge commit.
- Squash work-in-progress before it reaches `master`; every commit there should build.
- Keep upstream-file edits minimal and new behaviour in `headless/`.
- Never commit generated jars, `tokens.json`, keystores or signing files; the pre-commit hook blocks them, and
  `--no-verify` is only for a checked false positive.
- Anything under `docs/`, including `docs/handoffs/`, is tracked and therefore public.

## See also

- [setup.md](setup.md): the machine, the hooks and the staging order.
- [testing-qa.md](testing-qa.md): the full gate ladder and every QA tool.
- [renderers.md](renderers.md): the GPU and 117 HD paths, the overrides and the 117 HD pin.
- [bridge-api.md](bridge-api.md): the shared contract a merge must keep.
- [RELEASE.md](../../RELEASE.md): disclosure text, known issues, rollback and the pre-publish checklist.
- [`tools/ci/README.md`](../../tools/ci/README.md): the release pipeline's design notes.
- [CHANGELOG.md](../../CHANGELOG.md).
