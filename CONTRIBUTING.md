# Contributing

Contributions are genuinely welcome — bug reports, fixes, port improvements, docs, and new plugin/UI
work all help. This is a single-maintainer project, so reviews happen on a best-effort basis and a reply
may take a little while, but every issue and PR gets read.

**Good ways to start:**

- **Found a bug?** Open an issue with your device/OS, the port (iOS or Android), steps to reproduce, and the file
  from the app's **Share logs** button (About screen; on iOS also the start screen).
- **Small fix?** Send a PR directly — typos, crashes, one-file fixes need no preamble.
- **Larger change?** Open an issue first so we can agree on the approach before you invest the work —
  especially anything touching the shared `headless/` bridge (see below), the build/CI, or upstream RuneLite
  code, where a heads-up saves a round-trip.

New to the codebase? The [developer guide](docs/dev/README.md) is the full reference: setup, architecture, the
bridge API, each port, testing, debugging and releases. [`PORTS.md`](PORTS.md) is the repo map, and the README's
**Build from source** section is the short path to a running app.

## Build setup

See the **Build from source** section of the [README](README.md) for the staging
scripts and build commands. A fresh clone needs the staging steps run in order
before the app will boot.

## The shared-contract rule (load-bearing)

Code under `runelite-client/.../headless/` is the bridge between the engine and
**both** native shells (Android and iOS). It is resolved by name at runtime and
shared verbatim across ports, so changes there can break the other port silently.

Before committing a change that touches `headless/`:

```sh
tools/shared-contract/check-contract.sh
#   exit 0 = no surface change
#   exit 1 = additive change  -> update the baseline in the same commit
#   exit 2 = breaking change  -> verify the other port, then update the baseline in the same commit
```

Update the baseline with `check-contract.sh --update` and stage `tools/shared-contract/baseline.txt`; the
`pre-commit` hook blocks any contract change, additive or breaking, until it is staged. A breaking change (a
public static, `-D` flag or payload key removed or changed) is allowed, but only once both bridge censuses pass
against it: `android/dev-tools/bridge-census/run-census-desktop.sh` (expect `ANDROID_BRIDGE_CENSUS_GREEN`) and
`ios/dev-tools/bridge-census/run-census-sim.sh --jars` (expect `IOS_BRIDGE_CENSUS_GREEN`). The release gate
(`android/dev-tools/ci/release-gate.sh`) accepts an additive diff but fails a breaking one against the committed
baseline, so a breaking change ships only with its refreshed baseline committed.

`check-contract.sh --update` also regenerates [`docs/dev/bridge-api-reference.md`](docs/dev/bridge-api-reference.md),
the member-by-member reference built from the same scan plus each member's Javadoc; stage it with the baseline. A
Javadoc-only edit on a bridge member changes that page too: regenerate it with
`tools/shared-contract/gen-bridge-api.py`. The hook and the release gate both fail on a stale page.

Install the git hooks so this runs automatically:

```sh
tools/git-hooks/install.sh
```

This sets `core.hooksPath` (per-clone, so run it once after cloning) and activates:

- **`pre-commit`** — the contract check above, plus a hygiene gate that blocks staged secrets/keys
  (`tokens.json`, `*.jks`, `keystore.properties`, …), the generated `probes.jar`, local-only
  development scaffolding (evidence, audits, handoffs, …), and anything `gitleaks` flags. It also
  lints the staged files of each kind — `shellcheck` (shell), `ktlint` (Kotlin), `clang-format`
  (native, changed lines only) — each run only if that tool is installed.
- **`commit-msg`** — with `pre-commit`, checks the message and the staged added lines against a
  pattern list kept outside the repo (`~/.config/rune-mobile/attribution-denylist`, or
  `$RUNEMOBILE_ATTRIBUTION_DENYLIST`). Without that file the check prints a notice and passes.

Override a single commit with `git commit --no-verify` only when a flag is a known false positive.

To reclaim disk, use `tools/clean-local.sh` (dry run by default) rather than `git clean -X`: the ignore
rules also cover local-only files that cannot be regenerated, and `-X` deletes them too.

## Linting

Each runner soft-skips if its tool is absent, but the release gate invokes them with `--require` so a
missing linter fails the gate rather than passing silently. Incrementally, the pre-commit hook lints only
the staged files of each kind (if the tool is installed).

- **Shell:** `tools/lint/shellcheck.sh` lints every tracked script at `--severity=warning`; config and
  the single repo-wide mute live in `.shellcheckrc`. Intentional findings get a justified
  `# shellcheck disable=SCxxxx` directive, not a blanket mute.
- **Kotlin (style):** `tools/lint/ktlint.sh` lints all tracked Kotlin under `android/`; style (indent,
  line length, the Compose `@Composable` naming exception) lives in `.editorconfig`. Auto-fix most
  findings with `ktlint --format <files>`.
- **Kotlin (static analysis):** `tools/lint/detekt.sh` runs detekt over `android/`. Config lives in
  `android/config/detekt/detekt.yml` (ktlint owns formatting/naming, so those rules are off); existing
  complexity/exception debt is grandfathered in `android/config/detekt/baseline.xml`, so it fails only on
  **new** findings. Accept new debt deliberately by refreshing the baseline (the failure message shows how).
- **Native (C/C++/Obj-C):** `tools/lint/clang-format.sh` enforces `.clang-format` **incrementally** — only
  lines you change must conform (via `git clang-format`), so the existing hand-aligned tree is grandfathered
  and migrates as it is next edited. Apply fixes to your changes with `git clang-format`. The vendored JDK
  headers under `ios/app/RuneMobile/jni/` are excluded. This is a commit-time check (the release gate runs the
  whole-tree linters — shell/Kotlin — that we keep fully clean; native is enforced at the diff).
- **Java:** upstream Checkstyle (`config/checkstyle/`) + PMD (`runelite-client/pmd-ruleset.xml`).

## Testing the shared bridge

The `headless/` bridge has behavioural unit tests under
`runelite-client/src/test/java/net/runelite/client/headless/` (JUnit 4 + Mockito, no engine boot). They lock
down the parts of the contract the signature diff can't see — the bytes the bridge actually emits and the
geometry it computes: MenuPeek's snapshot JSON + entry fingerprint, JavaBridge's frame double-buffering and
the GPU load-in warmup hold, OverlayBridge's snap-corner math, HudVeneer's chat-avoidance rect, the
GrandExchange JSON reader, and which plugins MobileUiBridge gives a settings screen. If you change what the bridge emits or computes, update these so the other port
doesn't break silently. (GrandExchangeBridge's parser helpers are `private`; that one suite reaches them by
reflection — if you rename a helper, update the reflection target in the same change.)

```sh
./gradlew :client:test --tests 'net.runelite.client.headless.*'
```

The release gate runs them too (a scoped stage, so an unrelated upstream plugin-test breakage can't block it).

## Testing in the iOS Simulator

On an Apple silicon Mac the iOS app runs in the iOS Simulator: the same JRE, jars and native code as on the phone,
with the full JIT and no StikDebug. It is the quickest way to try an iOS change, and the only way to test one
without an iPhone. Set it up with steps 1 and 2 of [`ios/README.md`](ios/README.md#build-from-source-macos), then:

```sh
ios/dev-tools/run-sim.sh            # build, install, launch and press Play
ios/dev-tools/run-sim.sh --jars     # restage the jars first, after a Java change
ios/dev-tools/sim-gate.sh           # every simulator check, one verdict
```

`sim-gate.sh` ends with `VERDICT: SIM_GATE_GREEN` or `_RED` after about ten minutes. It checks that:

- every class, method and field the iOS code looks up through JNI resolves in the app's own VM (the bridge
  census), so a `headless/` change the native code still calls by its old name fails here, not on a phone;
- the native screens (Settings, the plugin list, the control editor, the side panels, …) still match their
  golden screenshots;
- every plugin's settings screen and every side panel opens, shows something, and logs no bridge fault;
- the app reaches the login screen on the CPU, GPU and 117HD renderers;
- no launch logged a shader error, or a line that isn't on the known-noise list (`tools/log-scan/`).

Each check also runs on its own: [`ios/README.md`](ios/README.md#run-in-the-ios-simulator-no-phone) lists them,
and [`ios/dev-tools/sim-gate/`](ios/dev-tools/sim-gate/README.md) explains each one and what to do when it fails.
Run the census after a change to `headless/` or to a JNI lookup, the screens after a native UI change, and the
whole gate before a release, after an upstream merge, and after a shader or renderer change.

Beyond the checks, the simulator is a place to work on the iOS app without a device round-trip:
`run-sim.sh --from-phone` starts it with a paired iPhone's settings and plugin profile, to reproduce a bug that
depends on them, and `run-sim.sh --desktop-login` logs it in with a throwaway account's session (see
`ios/README.md`), to try a change in game. `RENDERER=gpu` or `RENDERER=117hd` picks the renderer for a launch.

Good to know:

- The goldens are kept per Mac, outside git, so the first run on a new Mac fails the screens check with
  `NO_GOLDEN`. Check the shots by eye, then write them with `ios/dev-tools/sim-screens/sim-screens.py --update`.
  The simulator window has to be in landscape (Device > Rotate Left).
- The Python checks run under `/usr/bin/python3` and need Pillow and numpy.
- Every gate launch is logged out, so the gate never logs into the game, even when the simulator holds a session.
- On 117 HD, the first entry into the world freezes the game for a minute or more: Apple's software renderer
  compiles each shader the first time something is drawn with it. The freeze outlasts the server's timeout, so
  the connection drops once and the app logs back in. That is the simulator, not a bug. The gate only boots
  117 HD to the login screen, so it never waits on this.

It is not a phone. It can't show performance, the StikDebug JIT path, the phone's GPU driver (the simulator draws
the GPU modes with Apple's software renderer), multi-touch, or backgrounding. Check those on a device.

## Checking the 117 HD shaders

117 HD builds its shaders at run time, and each phone rewrites them for its own GL in native code, so a desktop
build never compiles them as a phone does. `tools/shader-matrix/run-matrix.sh ios` and `run-matrix.sh android`
repeat both steps on the Mac and validate every stage with glslang, across 11 combinations of 117 HD settings,
in a minute or two per port and with no phone. Run them after changing a shader override or a port's shader rewrite, and on
both ports after moving the 117 HD pin. [`tools/shader-matrix/`](tools/shader-matrix/README.md) explains what
they check and what they don't.

## Conventions

- **Android:** Kotlin + Jetpack Compose shell. Keep Android work under `android/`.
- **iOS:** Objective-C + UIKit shell under `ios/`.
- **Native:** C++17. Android's UI thread is never attached to the embedded JVM (touches are queued for the
  render thread); iOS's UI thread is attached and calls the bridge directly. See `headless/package-info.java`.
- R8 / minification is intentionally **off** — don't enable it.
- Don't fork the upstream RuneLite tree (`runelite-client/`, `runelite-api/`, …)
  unnecessarily; prefer additive bridge code.

## Pull requests

- Keep commits to plain prose under your own name; squash WIP before opening.
- Confirm `:app:assembleRelease` builds and you've tested on a device or emulator.
- If you changed the iOS app or `headless/` and have an Apple silicon Mac, run `ios/dev-tools/sim-gate.sh`.
- If you touched `headless/`, confirm the shared contract is unchanged, or that
  `check-contract.sh` passes and you updated the baseline.

Don't sweat getting every convention perfect on the first try — open the PR and we'll sort out the details
together. Contributions are accepted under the project's BSD 2-Clause license.
