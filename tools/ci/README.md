# CI — rolling release on every merge to master

Every push to `master` on the **private** origin (`audaro/Rune-Mobile`) builds a real-signed **APK + IPA** and
publishes them as a single always-latest **`latest-master` prerelease** on the **public** repo
(`audaro/runemobile`), alongside the StikDebug `runelite-jit.js` launch template.

The build runs on a **self-hosted runner on the developer Mac** — it already has the full toolchain (OpenJDK 21,
Android SDK/NDK, Xcode) and the real signing keychain, so artifacts are properly signed at **$0** with **no key
material uploaded to GitHub**. The iOS IPA's outer code-signature breaks when the embedded JRE is re-signed;
that is expected and harmless because SideStore/AltStore re-sign the whole bundle on install.

## Pieces

| File | Role |
|------|------|
| `tools/ci/build-release-artifacts.sh` | The build. Produces `dist/ci/RuneMobile-<ver>.{apk,ipa}` + `runelite-jit.js` + `manifest.env`. Runnable + testable locally. |
| `tools/ci/publish-rolling-release.sh` | Cross-publishes `dist/ci/` to the `latest-master` prerelease on `audaro/runemobile`. |
| `.github/workflows/runemobile-release.yml` | Thin self-hosted wrapper: contract pre-flight → build → publish. |
| `.github/workflows/upstream-sync.yml` | Polls `runelite/runelite` every 6 h, merges new upstream work into master (gated), pushes — which fires the release workflow. |
| `~/.runemobile-ci/` (in `$HOME`, not the repo) | `keystore.properties`, `signing.env`, `keychain.pw`. Secrets stay here. |

Run the build by hand anytime:

```bash
REUSE_JARS=1 BUILD_NUMBER=1 tools/ci/build-release-artifacts.sh   # reuses staged jars — fast
tools/ci/build-release-artifacts.sh                               # full clean build (rebuilds jars)
```

## Design notes

- **Versioning.** Rolling builds get `versionName = 0.1.0-master.<run>+<sha>` and `versionCode = 1_000_000 + <run>`
  (kept above the semver-derived range so it stays monotonic). A plain local/tagged build passes neither override
  and gets the clean semver code/name. Gradle reads `-PversionCodeOverride` / `-PversionNameSuffix`.
- **Signing is enforced, not assumed.** The build hard-fails (`REQUIRE_RELEASE_KEY=1`, set by the workflow)
  unless the APK carries the documented **45:E3** release cert, so a missing/misconfigured keystore can never
  silently ship a debug-signed build (which would also break user `apksigner verify` and can't upgrade a
  release-signed install).
- **Atomic publish.** Each merge is published as its OWN immutable prerelease, tag `master-<run>`: created as a
  DRAFT, all assets uploaded to the draft, then flipped to published in a single `gh release edit --draft=false`.
  A failed/cancelled publish can only leave an invisible, incomplete draft (reaped by retention) — users never
  see a half-uploaded or mixed-version release. The newest prerelease on the page is "latest master"; older
  rolling builds are pruned to the last 5 (`RETAIN`). Tagged `v*` semver releases are never touched.
- **Source can lag the binaries — no over-claim.** The public repo is a periodically force-pushed *scrubbed
  snapshot*; this pipeline does **not** auto-sync source (that stays a manual, gated sweep). The origin commit
  is recorded in the notes only as an internal maintainer **build id** — a public reader can't view it and the
  pre-release does not ship matching source, so the notes don't imply public auditability.
- **Inherited workflows are neutered.** `CI.yml` (upstream's full build) and `android-release-gate.yml` (hosted
  ubuntu) are set to `workflow_dispatch`-only so enabling Actions doesn't fire them on every push.
- **Upstream auto-sync.** `upstream-sync` polls `runelite/runelite` on a 6-hour schedule. When upstream/master
  has new commits it merges them (merge commit authored as the maintainer), runs a fast gate
  (`:client:compileJava` + the cross-port contract check) and pushes master — the PAT-authenticated push then
  triggers `runemobile-release`, so a clean upstream revision bump ships end-to-end unattended. **On a merge
  conflict or compile break the run fails loudly and master is left untouched** — GitHub emails the owner; fix
  locally with the usual playbook (`git fetch upstream && git merge upstream/master`, repair any API breaks —
  e.g. rev239's `getMapAngle`→`getCameraYaw` — then push; the release fires as normal). The gate is deliberately
  fast/shallow: the full signed build in `runemobile-release` is the real backstop and refuses to publish a
  broken or mis-signed build.
- **Runner safety.** The self-hosted runner is attached to the **private origin only** — never a public repo,
  where an untrusted PR could execute code on the Mac. Third-party actions are **pinned to full commit SHAs**
  (not mutable tags) since the runner holds signing material. For extra isolation you can run the runner under
  a dedicated, minimally-privileged macOS account (duplicate `~/.runemobile-ci`, `~/.keystores`, and the
  `build.keychain` there) — optional, since only you can push to origin.

## One-time setup (the live steps)

These are the only steps not already committed; they enable the pipeline.

### 1. Mint the publish token (you)

The build runs on origin but publishes to the *separate* `audaro/runemobile` repo, so it needs a token with
write access to that repo (the default `GITHUB_TOKEN` only covers the repo the run is in).

- GitHub → Settings → Developer settings → **Fine-grained tokens** → *Generate*.
- Repository access: **only** `audaro/runemobile`. Permissions: **Contents: Read and write**. Short expiry is fine.
- Store it as an Actions secret on the **private** origin:

  ```bash
  gh secret set PUBLISH_TOKEN --repo audaro/Rune-Mobile   # paste the token when prompted
  ```

### 1b. Mint the sync token (you)

`upstream-sync` pushes merged upstream work back to **this** repo, and that push must trigger the release
workflow — which the built-in `GITHUB_TOKEN` cannot do (GitHub suppresses workflow-to-workflow recursion for
it). So it needs its own PAT:

- Fine-grained token, repository access: **only** `audaro/Rune-Mobile`. Permissions: **Contents: Read and
  write** AND **Workflows: Read and write** — upstream occasionally touches its own `.github/workflows/`
  files, and GitHub rejects any push containing workflow-file changes from a token without the Workflows
  permission (the sync would fail loudly on exactly the weeks upstream edits its CI).
- ```bash
  gh secret set SYNC_TOKEN --repo audaro/Rune-Mobile   # paste the token when prompted
  ```

The token is never persisted into the checkout (`persist-credentials: false`); the gate step runs Gradle from
the freshly-merged tree, so credentials are handed only to the final push step via env.

Until this secret exists, `upstream-sync` fails fast at its first step with a pointer here (nothing breaks).

### 2. Install the self-hosted runner (on the Mac)

```bash
# get a registration token (short-lived) for the PRIVATE origin repo:
gh api -X POST repos/audaro/Rune-Mobile/actions/runners/registration-token --jq .token

mkdir -p ~/actions-runner && cd ~/actions-runner
# download the current macOS arm64 runner from github.com/actions/runner/releases, then:
./config.sh --url https://github.com/audaro/Rune-Mobile --token <REG_TOKEN> \
  --labels macOS --name mac-mini --unattended
./run.sh          # run interactively in tmux/mosh (signing works from a tmux session), OR
./svc.sh install && ./svc.sh start   # run as a launchd service
```

Run it **interactively in tmux/mosh** if signing misbehaves under launchd — the dedicated `build.keychain` the
build unlocks is what makes non-interactive signing work, but an interactive session is the proven path.

### 2b. Seed the iOS JRE (on the Mac)

The runner builds from a fresh checkout, and every gitignored build input **self-provisions** — the cacio jars
fetch from Maven Central (still gated by their pinned SHA-256), `rlhd-src` fetches the pinned `117HD/RLHD` rev,
delombok output regenerates via `:client:delombok`, and the Android JRE is a SHA-pinned download — **except one**:
the embedded iOS JRE (`ios/dev-tools/jre`) is verified + patched local state (`patch-jre-txm.sh`, see
`ios/dev-tools/JRE21-INVENTORY.md`) and can't be rebuilt from a URL. Seed it once into the CI config dir:

```bash
cp -R /path/to/dev-checkout/ios/dev-tools/jre ~/.runemobile-ci/ios-jre
```

The build copies it into any workspace where `ios/dev-tools/jre/lib/libjvm.dylib` is missing, and fails with a
pointer here if the seed is absent.

### 3. Enable Actions on the private origin (you or me)

```bash
gh api -X PUT repos/audaro/Rune-Mobile/actions/permissions -F enabled=true -f allowed_actions=all
```

This reverses the fork's default "Actions disabled" stance — deliberate, and scoped: only `runemobile-release`
and `upstream-sync` auto-run (the inherited workflows are manual-only). Push a trivial commit to `master` (or run the workflow via
*Actions → runemobile-release → Run workflow*) to verify the `latest-master` prerelease appears on
`audaro/runemobile`.

To pause the pipeline: `gh api -X PUT repos/audaro/Rune-Mobile/actions/permissions -F enabled=false`.
