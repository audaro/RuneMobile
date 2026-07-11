# Mobile ports — repo map

This repo is a private fork of [`runelite/runelite`](https://github.com/runelite/runelite) that adds **two
mobile ports** running real RuneLite on an on-device JVM. Everything below `ios/` and `android/` is ours;
the rest of the tree (`runelite-client/`, `runelite-api/`, …) is upstream RuneLite, kept as-is so we can
`git merge upstream/master`.

The ports share one thing deliberately and split everything else:

```
runelite-ios/
├── runelite-client/  …   upstream RuneLite + our headless bridge (net.runelite.client.headless.*)
├── tools/
│   └── stage-mobile-runtime.sh   ← builds + stages the SHARED Java runtime into both ports
├── ios/              native iOS host (Objective-C/UIKit, JNI bootstrap, StikDebug per-launch JIT)
└── android/          native Android host (Kotlin/ART, JNI_CreateJavaVM, free JIT)
```

## The shared layer is the Java runtime, not the host

Both ports embed the **same two jars**, byte-for-byte:

| jar | what it is | built by |
| --- | --- | --- |
| `client-<version>-shaded.jar` | real RuneLite + all deps + our `net.runelite.client.headless.*` bridge | `./gradlew :client:shadowJar` |
| `probes.jar` | headless boot (`DeviceHeadlessBoot`), CACIO (folded in), W1 activation/bench probes | [`ios/app/build-probes.sh`](ios/app/build-probes.sh) |

The Java side — gamepack, plugins, overlays, the headless render loop, the touch/click facade — is
**identical** on iOS and Android and reused verbatim. Only the host differs: iOS is Mach-O + per-launch JIT
attach; Android is bionic ELF + free JIT. See [`android/README.md`](android/README.md) for the Android-specific
bootstrap and [`ios/README.md`](ios/README.md) for the iOS build pipeline.

## Build both ports from one front door

Do **not** hand-copy jars per port (that's how they drift). Run:

```sh
tools/stage-mobile-runtime.sh            # build :client:shadowJar + probes.jar, stage iOS + Android
tools/stage-mobile-runtime.sh --check    # verify both ports' staged jars match the last-built source jars (no build; stage first if source changed)
```

It builds the shaded jar, then `probes.jar` (which folds in CACIO and needs the shaded jar present), copies
both into `ios/app/jvm-resources/` and `android/app/src/main/assets/jvm/`, and writes a SHA/version manifest
(`tools/last-stage.manifest`, gitignored) with a short **content-tag**.

> **Stale assets can't happen:** Android unpacks its staged jars to `filesDir` once. The script writes the
> content-tag into the bundle as `jvm/runtime.tag`, and
> [`AssetInstaller.kt`](android/app/src/main/java/dev/audaro/runemobile/AssetInstaller.kt) re-unpacks whenever
> that tag changes — so a jar update invalidates old installs with no hand-typed version bump. The `BASE`
> constant there only needs bumping when the embedded JRE / native libs change (rare). iOS has no such cache —
> Xcode re-bundles `jvm-resources/` every build.

Both staged trees are gitignored (large, generated): `ios/app/jvm-resources/*.jar` and
`android/app/src/main/assets/jvm/{client-*.jar,probes.jar}`.

## Boundary convention (in lieu of a shared module)

There is intentionally **no `shared/` Gradle module and no umbrella build** — that would drag AGP/SDK
assumptions into normal RuneLite work and fight upstream mergeability for little gain. The shared edge is held
by convention, not compile-time walls. Code that crosses the JVM↔host boundary
(e.g. [`Hooks.java`](runelite-client/src/main/java/net/runelite/client/callback/Hooks.java)) falls into three
kinds — keep them distinguishable:

- **production shared** — facades both ports call (render, touch, click). Lives in `net.runelite.client.headless.*`.
- **desktop probe** — mutating spikes gated behind system properties, used for desktop A/B bring-up
  (`UnsafePokeActivation`, `DeviceHeadlessBoot`). Build front door is `ios/app/build-probes.sh`; folded into
  `probes.jar`. New probe classes should land under a `headless.probe` package, still inside `runelite-client`.
- **host-specific native** — never shared. iOS Objective-C + Android Kotlin/C++. The two `fake-xawt` builds
  stay **separate** on purpose — the platform link rules differ materially (Mach-O `libawt_xawt.dylib` vs
  bionic `libawt_xawt.so` with `DT_NEEDED libawt_headless.so`).

## Why no deeper restructure (yet)

Rationale and the rejected alternatives (shared module, umbrella `includeBuild`, hoisting the desktop harness,
unifying `fake-xawt`) were weighed in a June 2026 repo-structure review and rejected as not worth the churn.
The cheap, drift-killing move was this doc plus the staging script; revisit a module only if shared Java grows
its own independent build needs.
