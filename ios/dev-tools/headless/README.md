# headless — Gate 1c: real RuneLite, no Swing window, capture the engine buffer

The Gate 1c long pole: boot **real RuneLite** (real gamepack, real `PluginManager`/overlay pipeline) with
the desktop Swing `ClientUI` **replaced** by a window-less one, and capture the engine's composited buffer
(`mainBufferProvider`) to PNG on **desktop OpenJDK 21**. This is the product premise — RuneLite headless —
de-risked on the same JVM family before any device work.

## The cut (after the Gate 1c adversarial audit)
The audit refuted "just override five hot-path methods" and identified the real kill risk (its **Claim D**):
*will the OSRS engine drive the `Hooks.draw` callback with a non-null `Graphics` when there is no real Swing
window / displayable canvas?* If not, nothing composites and `mainBufferProvider.getImage()` is never fed.

So the architecture is:
- **`net.runelite.client.ui.HeadlessClientUI`** — subclass of `ClientUI` (its constructor was relaxed
  `private → protected`). Replaces the full desktop chrome (ContainableFrame + sidebar + toolbar + tray +
  L&F + OSX adapters) with **one minimal AWT `Frame` that hosts the gamepack `Component` and is realized**,
  so the engine's `Canvas` acquires a peer and hands the engine a real `Graphics`. Focus / cursor / taskbar /
  navigation / sidebar-overlay are all no-ops.
- **`net.runelite.client.headless.HeadlessModule`** — Guice override (`Modules.override(RuneLiteModule)
  .with(..)`) rebinding `ClientUI → HeadlessClientUI`. Every `@Inject ClientUI` site gets the headless one.
- **`net.runelite.client.headless.RuneLiteHeadless`** — entrypoint; sets the override module then calls
  `RuneLite.main` verbatim (same boot, same gamepack load, same plugins) — the honest client, not a rewrite.
- **`net.runelite.client.headless.HeadlessCapture`** — gated instrumentation wired into two lines of
  `Hooks.draw`: counts every draw + null-Graphics arrivals, and dumps the buffer to PNG via the
  toolkit-independent `BufferProvider.getPixels()`. Inert unless `-Drunelite.headless.capture.dir` is set.

Upstream files touched (minimal, merge-friendly): `ui/ClientUI.java` (constructor visibility + two
`frame == null` guards on its private `@Subscribe` handlers), `callback/Hooks.java` (two gated capture
calls), `RuneLite.java` (an optional override-module seam). Everything else is new and isolated.

## Run
```sh
./run-headless.sh         # experiment 1: native toolkit (bring-up crutch; a tiny window appears)
./run-headless-cacio.sh   # experiment 2: CACIO CTC toolkit — NO OS window (the honest iOS proxy)
```
Both boot to the **live-OSRS login screen** with `--safe-mode` (GPU off), run `RUN_SECONDS` (default 45),
dump frames + a log to `out/` (gitignored), then print a summary. CACIO activation reuses the Gate 1b path
(`CacioExtension` via the JUnit console launcher; `../cacio-smoke/lib` jars). Requires OpenJDK 21 at
`/opt/homebrew/opt/openjdk@21` (override with `JAVA_HOME`).

## Result (2026-05-29) — GREEN (login-screen capture); Claim D refuted
- **Native toolkit:** `HeadlessClientUI` realizes its frame (`canvas 765×503 displayable=true`); engine
  drives `Hooks.draw` ~42 fps with **`nullGraphics=0`**; 20 PNGs captured — each the **real live-OSRS login
  screen** rendered by the engine into our buffer, with no `ClientUI`. No `HeadlessException`, no NPEs.
- **CACIO CTC:** identical, under `toolkit=CTCToolkit` / `graphicsenv=CTCGraphicsEnvironment` with **no OS
  window** — the canvas is realized to a CACIO offscreen peer. `nullGraphics=0`, 20 login-screen frames.
  This is the honest iOS-shaped proof: the engine renders with no native display.

⇒ The kill risk is settled: **a window-less `ClientUI` does drive the real engine's render + capture seam**,
on both native and the iOS-shaped CACIO virtual display.

## What this does NOT yet prove — overlay compositing needs a logged-in client
`Hooks.draw` → `OverlayRenderer.renderOverlayLayer` → `renderOverlays`, which **returns early unless
`client.getGameState() == LOGGED_IN`** (`OverlayRenderer.java:249`) for **every** layer (including
`ALWAYS_ON_TOP`). So no overlay — synthetic or real — composites at the login screen. The honest
overlay-compositing proof is therefore **1c-ii: live login + in-game capture** (needs the throwaway Jagex
account / `tokens.json`).

## 1c-ii — live login + in-game overlay capture — GREEN (2026-05-29)
Run it: mint `ios/dev-tools/tokens.json` with `../fetch-shield-tokens.sh` (throwaway account), then
`./run-headless-login.sh` (native) / `./run-headless-login-cacio.sh` (no OS window). These map
`tokens.json` → the `JX_*` env vars the gamepack reads as the official-launcher handoff, switch to an F2P
world, synthesize the Play Now click, and boot `RuneLiteHeadless`; frames + a state-tagged log land in
`out-login/`. Env overrides: `AUTOLOGIN_POINT`, `AUTOLOGIN_WORLD`, `AUTOLOGIN_WORLD_ADDRESS`, `AUTOLOGIN=false`.

**Result — both native and CACIO (no window) reach `LOGGED_IN` and composite a real overlay:**
- The `JX_*` handoff auto-**authenticates** (`launcherDisplayName` set, `loginIndex=10`, welcome screen) but
  does **not** auto-**login** — it parks at `LOGIN_SCREEN`. `access_token`/`refresh_token` may be empty
  (Stage A of the token script is enough; the gamepack mints its own play token).
- `HeadlessLogin` (gated by `-Drunelite.headless.autologin`) posts a focus-gain + mouse sequence at the
  Play Now button into the gamepack `Canvas` via the toolkit `EventQueue`. **One synthesized click drives
  `LOGIN_SCREEN → LOGGING_IN → LOADING → LOGGED_IN`** — proving the window-less engine accepts synthesized
  input (the Phase-4 kill-risk, settled minimally; same UIKit-touch → AWT-`MouseEvent` path the device needs).
- A free account is bounced from members worlds, so `HeadlessLogin` `changeWorld`s to an F2P world
  (default 301 / `oldschool1.runescape.com`) before clicking.
- In-game the engine keeps driving `Hooks.draw` (`nullGraphics=0`), and `OverlayRenderer` (gated on
  `LOGGED_IN` at `OverlayRenderer.java:249`) composites the RuneLite **FPS overlay** into the captured PNG —
  top-right, on both toolkits. OSRS has no native FPS counter, so that is unambiguously a RuneLite plugin
  overlay. Account is fresh ⇒ Tutorial Island scene (irrelevant to the proof).

This closes Claim 2's long pole. The minimal click is the only Phase-4 input built; the full mobile control
scheme (gestures, tap-to-walk, long-press menus) remains later product work.
