# CI — rolling release on every merge to master

Every push to `master` **on this repository** (`audaro/runemobile`) builds a real-signed **APK** + an
ad-hoc-signed **IPA** and publishes them as a rolling prerelease on this repo's Releases page, alongside the
StikDebug `runelite-jit.js` launch template. The job is gated to this repo's id, so a push anywhere else (a fork,
a mirror, another remote of the same clone) builds and releases nothing. A push that only touches Markdown, the
`LICENSE` or the two non-release workflows skips the build too (`paths-ignore` in `release-hosted.yml`).

The pipeline is **fully hosted on GitHub**, with no self-hosted machine. Only **Android** needs real signing
material (the APK installs directly, so it must carry the 45:E3 release key, materialized from a repo secret). The
**IPA is ad-hoc-signed only** — AltStore/SideStore re-sign the whole bundle on-device at install, the only
supported way to run it, so **no Apple cert/profile/team is ever uploaded**. The build reuses `tools/ci/*.sh`
verbatim; its inputs come from a GitHub secret (Android keystore) + a release asset (the iOS JRE). Locally the
same scripts read those inputs from `~/.runemobile-ci` instead.

It runs as **three jobs, so no secret sits next to third-party build code**:

| Job | Runner | Holds | Runs |
|-----|--------|-------|------|
| `build` | `macos-15` | no secret, read-only token | everything that pulls in outside code: Gradle and its dependencies, Homebrew, the SDK setup actions, upstream RuneLite's build logic. The APK comes out debug-key signed. |
| `sign` | `ubuntu-24.04` | the Android release key, a token with no rights | no checkout and no repo code: the runner image's `apksigner` re-signs the APK and the job checks the 45:E3 certificate |
| `publish` | `ubuntu-24.04` | the `contents: write` token | `publish-rolling-release.sh` and `gh`, from a fresh checkout; the build's `manifest.env` is read as data, never sourced |

A compromised build input can still make that build's own APK and IPA malicious, since `sign` signs whatever
`build` produced. What it can no longer do is steal the signing key, which would let it ship updates over every
install for good, or rewrite other releases: the stable `v*` releases, the AltStore feed they carry, or the
`ios-jre-dep` asset every later build fetches.

## Pieces

| File | Role |
|------|------|
| `tools/ci/build-release-artifacts.sh` | The build. Produces `dist/ci/RuneMobile-<ver>.{apk,ipa}` + `runelite-jit.js` + `manifest.env`. By default (`IOS_ADHOC=1`) it builds the IPA unsigned then ad-hoc-seals it (SideStore re-signs on install); `IOS_ADHOC=0` team-signs it, which embeds the developer's provisioning profile, so both publish scripts refuse that IPA. Runnable + testable locally. |
| `tools/ci/publish-rolling-release.sh` | Publishes `dist/ci/` as a rolling prerelease on this repo. |
| `tools/ci/check-ipa-clean.sh` | Refuses an IPA (or app folder) that still identifies the developer: a provisioning profile or `.xcent`, or a signing certificate left in a binary's signature space after a re-sign. The build runs it on the sealed app; both publish scripts run it on the IPA. |
| `.github/workflows/release-hosted.yml` | **The live pipeline.** `push:[master]` (+ dispatch): `build` (contract pre-flight → fetch + verify the iOS JRE → build) → `sign` → `publish`. |
| `.github/workflows/CI.yml` | Upstream RuneLite's full build/test (JDK 11) on every push + PR — the public green/red check that keeps this repo building like RuneLite. |
| `.github/workflows/upstream-sync.yml` | Polls `runelite/runelite` every 6 h and **fails loudly** (emails the owner) when upstream is ahead — a notifier, never an auto-merge (see *Upstream watch*). |
| `tools/ci/setup-hosted-secrets.sh` | One-shot helper: uploads the Android keystore secrets + the `ios-jre-dep` release asset to this repo. |

Run the build by hand anytime:

```bash
REUSE_JARS=1 BUILD_NUMBER=1 tools/ci/build-release-artifacts.sh   # reuses staged jars — fast
tools/ci/build-release-artifacts.sh                               # full clean build (rebuilds jars)
```

## Design notes

- **Versioning.** Rolling builds get `versionName = <semver>-master.<run>+<sha>` (e.g. `0.2.5-master.1044+<sha>`)
  and `versionCode = 1_000_000 + <run>`
  (kept above the semver-derived range so it stays monotonic). A plain local/tagged build passes neither override
  and gets the clean semver code/name. Gradle reads `-PversionCodeOverride` / `-PversionNameSuffix`.
- **Signing is enforced, not assumed.** The `sign` job fails unless the re-signed APK carries the documented
  **45:E3** release cert, and a local stable build does the same with `REQUIRE_RELEASE_KEY=1`, so a
  missing/misconfigured keystore can never silently ship a debug-signed build (which would also break user
  `apksigner verify` and can't upgrade a release-signed install). `sign` uses exactly the schemes Gradle signs a
  release with (v2 only, at `minSdk 28`), so a CI APK and a locally built one differ only in the signature bytes.
- **The iOS JRE is pinned.** Its files become native code in every IPA, and a release asset can be replaced in
  place, so `build` checks the downloaded `jre.tar.gz` against `IOS_JRE_SHA256` in the workflow and stops on a
  mismatch. `setup-hosted-secrets.sh` prints the new value after an upload.
- **Atomic publish.** Each merge is published as its OWN immutable prerelease, tag `master-<run>`: created as a
  DRAFT, all assets uploaded to the draft, then flipped to published in a single `gh release edit --draft=false`.
  A failed/cancelled publish can only leave an invisible, incomplete draft (reaped by retention) — users never
  see a half-uploaded or mixed-version release. The newest prerelease on the page is "latest master"; older
  rolling builds are pruned to the last 5 (`RETAIN`). Tagged `v*` semver releases are never touched.
- **Upstream watch (notify, never auto-merge).** `upstream-sync` polls `runelite/runelite` on a 6-hour schedule.
  When upstream/master is ahead it **fails loudly** — GitHub emails the owner with the commit count + playbook
  pointer. It does **not** auto-merge, run any upstream build code, or hold a push token: auto-adopting upstream
  master into a build that decodes the release signing key, with no human review of the upstream diff, would let
  one malicious upstream commit exfiltrate the key (a compile gate can't prevent that). So the merge is a
  **reviewed manual step**, done by the *Upstream merge playbook* below; `release-hosted` then rebuilds and
  republishes both apps.
- **Secret-bearing runs are gated to master + this repo id.** Every `release-hosted` job (`sign` decodes the
  Android signing key) runs only on `github.repository_id == '1296635776'` **and** `github.ref == 'refs/heads/master'`,
  so a dispatch/push on any other branch — or in a fork, which never receives secrets — can't run with the
  production key. Third-party actions are **pinned to full commit SHAs** (not mutable tags). This guard controls
  *where* the key-bearing build runs; it does **not** by itself prove the master commit was reviewed. That
  property is enforced by **branch protection on `master`** — which must **require a pull request with an
  approval, restrict direct pushes, and enforce the rule for admins (no bypass)** — so the signing key only ever
  builds code that landed through a reviewed PR (or the reviewed upstream sweep), never an unreviewed direct push
  or auto-merge (see *Upstream watch*). Configuring that protection is the one-time setup step below; until it is
  set, a direct push to master by anyone with write access would build with the key. **Current state (checked
  2026-10-20): not configured.** This is a single-maintainer repo and the maintainer pushes to `master` directly,
  so the review the key-bearing build relies on is the maintainer's own. Configure the protection before anyone
  else is given write access.

## One-time setup

### 1. Upload the build inputs

```bash
tools/ci/setup-hosted-secrets.sh   # unattended: uploads the Android keystore secrets + the iOS JRE asset
```

This sets two Actions secrets — `ANDROID_KEYSTORE_B64` (base64 of the 45:E3 release `.jks`) and
`ANDROID_KEYSTORE_PROPERTIES` (the keystore.properties minus `storeFile`, which the workflow pins itself) — and
uploads the ~166 MB iOS JRE as the `ios-jre-dep` release asset (it is verified/patched local state, not
URL-reproducible; publishing an OpenJDK build is fine — GPLv2+CE, and it already ships inside every IPA). **No
Apple cert/profile/team and no push token are ever uploaded**: the IPA is ad-hoc-signed and SideStore re-signs
it on-device, and `release-hosted` publishes with the built-in `GITHUB_TOKEN`.

### 2. Enable Actions

Already done on this repo (Actions are enabled); the command, for reference:

```bash
gh api -X PUT repos/audaro/runemobile/actions/permissions -F enabled=true -f allowed_actions=all
```

Then in the repo Settings, **branch-protect `master`**: require a pull request with **at least one approval**,
**restrict who can push directly** (dismiss stale approvals on new commits), **block force-pushes and
deletions**, and **enforce the rules for administrators (no bypass)**. This is what makes the signing-key build
run only on reviewed code (see *Signing / secret-bearing runs* above) — the workflow `if:` guard alone does not.
Then push (or *Actions → release-hosted → Run workflow*) to verify the rolling prerelease appears.

To pause the pipeline: `gh api -X PUT repos/audaro/runemobile/actions/permissions -F enabled=false`.

### 3. Upstream tracking (nothing to install)

`upstream-sync` is a **read-only notifier** — no token, no runner, no setup beyond Actions being enabled. When
`runelite/runelite` moves ahead of master it emails you; you then do the reviewed local merge (see *Upstream
watch* above) and push.

## Upstream merge playbook

After an OSRS weekly update, every existing build stops at `error_game_js5connect_outofdate` until upstream is
merged and a new build ships, because the client loads the `injected-client` bundled for its version. From the
repository root:

1. **Merge.** `git fetch upstream && git merge upstream/master`. Fix API breaks inside the merge commit. Check the
   upstream files this fork edits first: `git diff --name-status upstream/master...HEAD -- runelite-client`.
2. **Build and test the bridge.** `./gradlew :client:shadowJar`, then
   `./gradlew :client:test --tests 'net.runelite.client.headless.*'`. A clean compile is not proof: rev239 renamed
   `getMapAngle` to `getCameraYaw` *and* widened yaw from 11 to 14 bits, so the rename alone compiled and was wrong.
3. **Cross-port contract.** `tools/shared-contract/check-contract.sh` (0 unchanged, 1 additive, 2 removed or
   changed; `tools/shared-contract/README.md` says how to clear it) and `tools/shared-contract/check-auth-contract.sh`.
4. **Plugin-hub pin.** `tools/shared-contract/check-hub-pin.sh` fails once the version passes the last review. Re-probe
   the endpoints and add a dated entry to `tools/shared-contract/hub-pin.ack`; its header says how.
5. **Re-stage both ports** in the order [`PORTS.md`](../../PORTS.md) gives. Android's Gradle self-staging skips when a
   jar of the current version already exists, so a merge that keeps the version ships stale jars without this.
   117HD (RLHD) is pinned to `f5be2560` (v1.6.0.1) and a merge never moves it; a new client API can break the overlay
   recompile, and the stager then exits non-zero.
6. **Gate.** `./android/dev-tools/ci/release-gate.sh --skip-build`, and the full gate before a release.
7. **Device check.** Boot both ports and confirm the client logs in rather than stopping at `js5connect_outofdate`.
8. **Release notes.** Add a `CHANGELOG.md` entry naming the RuneLite version the build reports, and bump
   `verPatch` in `android/app/build.gradle.kts`.
9. **Push** `master` to this repository. That push is the release.
