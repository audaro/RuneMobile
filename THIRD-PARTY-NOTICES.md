# Third-Party Notices

This project is a derivative of [RuneLite](https://github.com/runelite/runelite)
and bundles or builds against the third-party components listed below. The
project's own code is licensed under the BSD 2-Clause License (see `LICENSE`).
This file aggregates the notices those components require.

Dependency versions are pinned in `libs.versions.toml` (root) and the per-module
build files. Where a component ships its own `NOTICE` file, that file is
propagated in binary distributions.

---

## A. RuneLite — BSD-2-Clause

Copyright (c) 2016-2017, Adam <Adam@sigterm.info> and contributors.

This software is a fork of RuneLite. The upstream BSD 2-Clause license text is
reproduced verbatim in the root `LICENSE` file (clause 1 retention). The
RuneLite client, API, and cache libraries retain their original headers.

## B. 117HD / rs117 — BSD-2-Clause

Copyright (c) 2021, 117 <https://github.com/117HD/RLHD>

The 117HD renderer source is compiled into the shipped `client-*-rlhd.jar`. It
is licensed under the BSD 2-Clause License; the retention obligation is
discharged by this notice.

## C. net.runelite.rlawt (AWTContext) — BSD-2-Clause

Copyright (c) RuneLite contributors. `net.runelite:rlawt:1.8`. The Java AWT/GL
context facade; on this project the native half is replaced by `librlawt.so`
built from this repository's own `librlawt.cpp`.

## D. Apache License 2.0 group

The following are licensed under the Apache License, Version 2.0. The full
license text is reproduced once below; each component's own `NOTICE` file (where
present — Guava, Guice, Gson) is propagated in binary distributions.

- Google Guava — `com.google.guava:guava:23.2-jre`
- Google Guice — `com.google.inject:guice:4.1.0` (no_aop)
- Google Gson — `com.google.code.gson:gson:2.8.5`
- FlatLaf — `net.runelite:flatlaf:3.2.5-rl4`
- Apache Commons Text — `org.apache.commons:commons-text:1.2`
- Apache Commons Compress — `org.apache.commons:commons-compress:1.10`
- Java Native Access (JNA) — `net.java.dev.jna:jna:5.9.0` and
  `jna-platform:5.9.0` (dual Apache-2.0 / LGPL-2.1 — Apache-2.0 elected here)
- FindBugs JSR-305 — `com.google.code.findbugs:jsr305:3.0.2`
- JetBrains Annotations — `org.jetbrains:annotations:23.0.0`
- tomlj — `org.tomlj:tomlj:1.1.0`
- OkHttp — `com.squareup.okhttp3:okhttp:3.14.9` (in the shaded client jar)
- Okio — `com.squareup.okio:okio:1.17.2` (in the shaded client jar)
- AndroidX: `core` 1.13.1, `appcompat` 1.7.0, `browser` 1.8.0,
  `compose-bom` 2024.09.00 (incl. `material3`), `activity-compose` 1.9.2
- Kotlin coroutines — `org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1`

> Apache-2.0 full text: https://www.apache.org/licenses/LICENSE-2.0
> (reproduced in full in binary distributions alongside the propagated NOTICE files).

## E. MIT License group

- SLF4J — `org.slf4j:slf4j-api:1.7.25`
- jopt-simple — `net.sf.jopt-simple:jopt-simple:5.0.1`

## F. BSD-3-Clause group

- LWJGL 3 — `org.lwjgl:lwjgl` / `lwjgl-opengl` / `lwjgl-opencl:3.3.2`.
  Note: the LWJGL native libraries are not shipped on Android (`librlawt.so`
  replaces them); the Java facade ships, so attribution is retained.
- Protocol Buffers (javalite) — `com.google.protobuf:protobuf-javalite:3.21.12`
- ANTLR 4 runtime — `org.antlr:antlr4-runtime:4.13.1`
- RSyntaxTextArea — `com.fifesoft:rsyntaxtextarea:3.1.2` (in the shaded client jar)
- AutoComplete — `com.fifesoft:autocomplete:3.1.1` (in the shaded client jar)

## F2. Other licenses in the shaded client jar

The fat (`client-*-shaded.jar`) client jar — and the `client-*-gpu.jar` /
`client-*-rlhd.jar` staged from it — additionally embed:

- **Logback** — `ch.qos.logback:logback-classic` / `logback-core:1.2.9`, dual
  EPL-1.0 / LGPL-2.1; **EPL-1.0 elected here**. Full text:
  https://www.eclipse.org/legal/epl-v10.html — library source at
  https://logback.qos.ch/.
- **Bouncy Castle** (`org.bouncycastle.*`) — bundled transitively inside the
  RuneLite artifacts; **Bouncy Castle Licence** (an MIT-derived permissive
  license): https://www.bouncycastle.org/licence.html.
- **JSON-java** — `org.json:json:20090211`; the **JSON License**
  (https://www.json.org/license.html).
- **runelite-discord** — `net.runelite:discord:1.4`, BSD-2-Clause (RuneLite
  project artifact, same license as §A; the native Discord IPC library it
  fronts is not shipped on mobile).

## G. Caciocavallo Silano — GPLv2 with Classpath Exception

Caciocavallo (`com.github.caciocavallosilano:cacio` 1.18) provides the headless
AWT toolkit used to drive the engine's `Canvas`/`BufferProvider` off-screen.
Licensed under GPLv2 **with the Classpath Exception**. Source:
https://github.com/caciocavallosilano/cacio

Its source is not in this repository — the two release jars (`cacio-tta` /
`cacio-shared` 1.18) are fetched at build time and their classes are **folded
into the generated `probes.jar`**, which binary distributions of the app embed.
The Classpath Exception permits distributing that combination with this BSD-2
software (the GPL does not extend to the application code); the corresponding
source is the upstream repository linked above, and `probes.jar` itself is
generated output (`ios/app/build-probes.sh`), not committed.

## H. OpenJDK 21 — GPLv2 with Classpath Exception

The embedded arm64 OpenJDK 21 runtime (the in-process JVM that hosts the engine)
is licensed under GPLv2 **with the Classpath Exception**. It is **not committed**
to this repository — it is fetched at build time from a SHA-pinned upstream build
(see `tools/stage-android-jre.sh`). Binary distributions carry the runtime's own
`jre/legal/` directory intact, plus its bundled sub-notices (ICU, CLDR, Unicode,
the Mozilla public-suffix list, AES, ASM, c-libutl, and the Lucida fonts) and a
written offer of corresponding source for OpenJDK (`openjdk.org`, tag
`jdk-21.0.1`) and the build repository.

## I. Fonts

The bundled chat font, `runescape.ttf`, is **"RuneScape Chat '07" by WolfieMario
(2013)** — FontStruct construction #855573 — distributed under
**CC BY-NC-SA**. The iOS shell additionally bundles `runescape_small.ttf`
(WolfieMario, CC BY-NC-SA) and `runescape_bold.ttf` ("Bucket 2010", FontStruct,
different author). These fonts are the work of their respective FontStruct
authors and are **not** Jagex assets. The non-commercial (NC) term applies to any
distributed binary.

## J. Trademarks and game assets

RuneScape and Old School RuneScape — and the tab/stone/skill-icon/chat-button
interface art they originate — are property of Jagex Ltd. This is an unofficial
fan client and is not affiliated with, endorsed by, or sponsored by Jagex. **No
Jagex interface art is committed to or shipped in this repository.** The native
mobile chrome renders those interface sprites from the user's own live game cache
at runtime — the same way the upstream RuneLite client draws its interface — so
the art is never redistributed by this project. All such cache art, which
RuneLite streams live, remains Jagex's property and is not covered by this
project's license.
