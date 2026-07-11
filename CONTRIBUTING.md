# Contributing

Thanks for your interest. This is a personal/technical project; contributions are
welcome but reviewed on a best-effort, single-maintainer basis.

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
#   exit 2 = breaking change   -> not allowed
```

Install the git hooks so this runs automatically:

```sh
tools/git-hooks/install.sh
```

This sets `core.hooksPath` (per-clone, so run it once after cloning) and activates:

- **`pre-commit`** — the contract check above, plus a hygiene gate that blocks staged secrets/keys
  (`tokens.json`, `*.jks`, `keystore.properties`, …), the generated `probes.jar`, local-only
  development scaffolding (evidence, audits, handoffs, …), private-key material, and anything
  `gitleaks` flags. It also lints the staged files of each kind — `shellcheck` (shell), `ktlint`
  (Kotlin), `clang-format` (native, changed lines only) — each run only if that tool is installed.
- **`commit-msg`** — blocks stray `Co-Authored-By` trailers in the commit message.

Override a single commit with `git commit --no-verify` only when a flag is a known false positive.

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
the GPU load-in warmup hold, OverlayBridge's snap-corner math, HudVeneer's chat-avoidance rect, and the
GrandExchange JSON reader. If you change what the bridge emits or computes, update these so the other port
doesn't break silently. (GrandExchangeBridge's parser helpers are `private`; that one suite reaches them by
reflection — if you rename a helper, update the reflection target in the same change.)

```sh
./gradlew :client:test --tests 'net.runelite.client.headless.*'
```

The release gate runs them too (a scoped stage, so an unrelated upstream plugin-test breakage can't block it).

## Conventions

- **Android:** Kotlin + Jetpack Compose shell. Keep Android work under `android/`.
- **iOS:** Objective-C + UIKit shell under `ios/`.
- **Native:** C++17. The native UI thread is never attached to the embedded JVM.
- R8 / minification is intentionally **off** — don't enable it.
- Don't fork the upstream RuneLite tree (`runelite-client/`, `runelite-api/`, …)
  unnecessarily; prefer additive bridge code.

## Pull requests

- Keep commits to plain prose under your own name; squash WIP before opening.
- Confirm `:app:assembleRelease` builds and you've tested on a device or emulator.
- If you touched `headless/`, confirm the shared contract is unchanged, or that
  `check-contract.sh` passes and you updated the baseline.

Contributions are accepted under the project's BSD 2-Clause license.
