# A5 — plugin side-panels (seam first)

Brings RuneLite's plugin side-panels to Android (see `../../PORT-PHASING.md` Phase A5). Two tiers:
- **Tier-1 (generic, any panel):** the plugin's Swing panel is realized off-screen under CACIO and painted to
  a supersampled ARGB `int[]` (just like the game blit); the host pulls it and shows it in a zoom/pan view,
  mapping taps back via `panelClick`. Works for **every** plugin with a side-panel.
- **Tier-2 (curated native):** Quest Helper (`QuestHelperBridge`) + World Switcher (`WorldSwitcherBridge`) get
  native data-driven screens, falling back to Tier-1 when `isAvailable()` is false.

## Tier-1 panel seam (GREEN)
The host reaches the panel surface across the VM boundary on the rl-bridge thread:
`listPanels` → `openPanel(index)` (realizes + starts the repaint daemon) → `getPanelWidth/Height/FrameSeq` +
`getPanelPixels` (the ARGB image, marshalled cross-VM) → `panelClick(x,y)` → `closePanel`. The census-mode host
self-test (`MainActivity`) opens the first listed panel and pulls its image.

### GREEN baseline (emulator `rl_arm64`, 2026-06-08)
```
ANDROID_A5_SEAM_GREEN panels=10 panel='XP Tracker' 968x404 px=391072 seq=1
```
968×404 = 391,072 px confirms the full supersampled panel image (PANEL_WIDTH×4) crossed ART↔HotSpot intact.

```
./check-a5.sh                 # live `adb logcat -d` after a `--ez census true` run
./check-a5.sh saved.log
```

## Next (this phase, not yet built)
- **UI:** a panel host reachable from the plugin list — a zoom/pan view that blits `getPanelPixels` into a
  Bitmap and maps taps back via `panelClick` (Tier-1); native Quest Helper / World Switcher screens parsing
  `getWorldListJson`/`getQuestListJson` (Tier-2), with `setUiOpen(true/false)` so the bridges only tick while open.
