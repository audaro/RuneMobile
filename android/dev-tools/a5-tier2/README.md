# A5 Tier-2 — native Quest Helper + World Switcher screens

The two-tier panel system's curated half: data-driven **native** screens for Quest Helper and World Switcher,
parsed from `QuestHelperBridge` / `WorldSwitcherBridge`, with a graceful fall-back to the Tier-1 rendered-image
panel when a bridge's `isAvailable()` is false. Mirrors the iOS Tier-2 design; **zero new shared Java** (both
bridges are already `init()`/`tick()`-wired by `MobileUiBridge`, so they're live whenever
`-Drunelite.mobileui` is set — which Android always sets).

## Pieces
- **Native seam** — `jvm_bootstrap.cpp` resolves both as separate facades (the `MenuPeekBridge` pattern) behind
  their own release/acquire publication latches (`g_questReady` / `g_worldReady`, all-or-nothing); externs in
  `JvmLauncher.kt` (`quest*` / `world*`). Read on the rl-bridge thread.
- **Screens** — `QuestWorldScreens.kt` (`QuestHelperScreen`, `WorldSwitcherScreen`); routed from `PanelList`
  (a "Native screens" row appears per available bridge) via `PluginPanel`.

## Bridge contract (verified against source)
- **Quest list** `getQuestListJson()` → `{"available":bool,"quests":[{"name","difficulty","type","state"}]}`
- **Quest active** `getQuestActiveJson()` → `{"available":true,"active":bool[,"name","steps":[],"items":[],"general":[]]}`
- **World list** `getWorldListJson()` → `{"available":true,"current":int,"worlds":[{"id","players","location","members","pvp","highRisk","activity","types":[]}]}`
- writes: `startQuest(name)` / `stopQuest()` / `hop(worldId)`; lifecycle `setUiOpen(bool)` brackets each screen.

## GREEN gates

### Seam (census, md5-stable sentinels)
```
adb shell am start -n dev.audaro.runemobile/.MainActivity --ez census true
./check-a5-tier2.sh            # greps the census self-test sentinels; exit 0 == GREEN
```
Emulator `rl_arm64` baseline:
- `ANDROID_A5_TIER2_QUEST_GREEN available=false quests=0 isAvailable=false` — Quest Helper is a **hub plugin**,
  absent on a fresh emulator → the bridge resolves and returns clean `{"available":false}`; the native screen
  falls back to the Tier-1 rendered panel. (Native Quest screen is exercisable only with the hub plugin
  installed — deferred, per the blueprint's hub deferral.)
- `ANDROID_A5_TIER2_WORLD_GREEN available=true worlds=404 current=542` — World Switcher is **built-in** and we're
  LOGGED_IN → a live world list crosses the boundary.

### UI (interactive nav + screencap)
Open in normal mode, then ⚙ → **Panels** → the **World Switcher** "native ›" row:
- `ANDROID_A5_PANELLIST count=10 questNative=false worldNative=true` (native row surfaced only when available)
- `ANDROID_A5_TIER2_WORLD_UI_GREEN worlds=404 current=301` — the native screen renders the live world list,
  current world highlighted, Members/Free filters, per-row players/activity/membership; tap → `hop`.
- `evidence-panellist.png` (the Tier-1 list with the native World Switcher row on top) and
  `evidence-worldswitcher.png` (the live native world list) are the captured screencap evidence.

The emulator GL is software (SwiftShader); these prove logic, not perf/driver behaviour.
