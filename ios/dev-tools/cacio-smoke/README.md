# cacio-smoke — desktop overlay-render gate (Gate 1a / 1b)

The cheapest feasibility test from the platform-feasibility audit: render a representative slice of
RuneLite's Java2D overlay surface to a PNG with **no window**, on desktop OpenJDK 21 — first plain
headless (reference), then under the **CACIO CTC toolkit** (the audit's requested test). Zero iOS.

## Run
```sh
./run.sh          # Gate 1a (plain headless) + a fall-back CACIO attempt + compare
./run-cacio.sh    # Gate 1b proper: CACIO CTC toolkit truly active (via the JUnit extension)
```
Requires OpenJDK 21 at `/opt/homebrew/opt/openjdk@21` (override with `JAVA`/`JAVAC`). Jars auto-needed
in `lib/` (gitignored) — fetch from Maven Central:
- `com.github.caciocavallosilano:cacio-tta:1.18`, `:cacio-shared:1.18`
- `net.bytebuddy:byte-buddy:1.14.11`, `:byte-buddy-agent:1.14.11`
- `org.junit.platform:junit-platform-console-standalone:1.10.2`

## What it draws (the ops the audit flagged as the soft spot)
`FontManager`-style TTF load + `registerFont`; `TextComponent`-style `drawString` with shadow, 4-way
outline, and `<col=..>` colour tags via `FontMetrics`; `OverlayUtil`-style `Polygon` draw/fill with
`BasicStroke` + alpha fill; `fillOval`; `AffineTransform` rotate; `drawImage` sprite blit; `setClip`
clipping; `AlphaComposite` translucent panel; antialiasing `RenderingHints`.

## Result (2026-05-29) — GREEN, with one load-bearing caveat
- **Gate 1a (plain headless OpenJDK 21):** renders correctly. `nonBackgroundPixels=34115`,
  `RuneScape` font registers, `FontMetrics` correct. Proves RuneLite's overlay **code** produces a
  correct composited buffer with no window — the capture seam (`mainBufferProvider.getImage()`) is real.
- **Gate 1b (CACIO CTC toolkit, JDK 21):** `toolkit=...CTCToolkit`, `graphicsenv=...CTCGraphicsEnvironment`
  genuinely active. cacio-tta **1.18 runs on JDK 21** (built for 17). `registerFont` + all ops survive a
  swapped `GraphicsEnvironment`. Output is **pixel-identical** to 1a (`maxChannelDelta=0`).

### The caveat (correction to the audit) — read before trusting this as a Claim-1 proof
On desktop, `BufferedImage.createGraphics()` returns `SunGraphics2D` over `BufferedImageGraphicsConfig`,
and the glyph rasterizer is `sun.font.CFontManager` — **both chosen by platform, independent of the AWT
toolkit.** CACIO's CTC swaps the *windowing/peer* layer, not the BufferedImage rasterizer or the font
scaler (that's why 1a and 1b are byte-identical). So this desktop test:
- **DOES settle Claim 2** (RuneLite renders overlays to a buffer headless; overlay code is toolkit-portable)
  and proves cacio runs on JDK 21 + survives a swapped GE.
- **DOES NOT settle the iOS half of Claim 1** (does the *iOS JRE's* native font/2D rasterizer render these
  ops correctly). Those natives only run on arm64-iOS, so that risk rides to Phase 3 (device) — bounded,
  because overlay code is plain Java2D and the gamepack rasterizer writes int[] directly (no font/2D).

### Activation gotcha
A bare `-Dawt.toolkit=...CTCToolkit` **silently falls back** to the native toolkit (`LWCToolkit` on mac).
CACIO must be installed before AWT init via `@ExtendWith(CacioExtension.class)`, whose byte-buddy-agent
self-attaches — so JDK 21 needs `-Djdk.attach.allowAttachSelf=true` plus the `--add-exports/--add-opens`
set in `run-cacio.sh`.

## Next: Gate 1c
Boot real RuneLite headless (stub `ClientUI`, real CACIO EDT) with 2–3 overlay plugins, capture
`mainBufferProvider.getImage()` to PNG. That attacks Claim 2's long pole with the real client.
