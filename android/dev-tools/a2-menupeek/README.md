# A2 — press-and-peek native right-click menu

The first custom overlay drawn over the live SurfaceView. Long-press opens the engine right-click menu and a
native OSRS-styled "Choose Option" overlay at the finger; slide highlights a row (haptic per row); release
commits it; release-off cancels.

## How it works
Gate `-Drunelite.menupeek=true` (+ `menupeek.maxEntries=14`). The flow (ported from iOS `ViewController.m`):
1. `MainActivity.beginMenuPeek` — long-press → `JavaBridge.onClick(x,y,3)` opens the engine menu at the finger.
2. Choreographer poll → `tryBuildNativeMenu` reads `MenuPeekBridge.getSnapshot()` (published by the render
   thread into a native string) until `menuOpen && count>0`, then `presentNativeMenu` builds `MenuOverlayView`.
3. Drag → `updateMenuHighlight` (row hit-test in view space, haptic on change).
4. Release → `commitMenuSelection`: clicks the **engine row centre** `(menuX+menuW/2, menuY+19+k*15+7)` via
   `JavaBridge.selectMenuPoint` (honours plugin onClick + Menu Entry Swapper); off-row → `cancelMenu` clicks the
   engine's own Cancel row.

`MenuOverlayView` is a full-screen, non-interactive overlay (touches fall through to the SurfaceView);
selection is driven by the host's long-press drag, not the view's own touch.

## What's verified (emulator, no device)
- **Overlay-over-SurfaceView compositing — the primary A2 risk — RETIRED.** The native "Choose Option" menu
  renders over the live game frame (white option verbs + blue targets), with the engine menu underneath.
- **Full snapshot pipeline:** gate armed → `MenuPeekBridge facade published` → render-thread publish → UI parse
  → overlay built with the correct entries.
- **Open + commit:** long-press opens; release fires `JavaBridge.selectMenuPoint` (the cancel path clicks the
  engine Cancel row — same commit mechanism as a row select).
- **No regression:** autologin→LOGGED_IN gate md5 unchanged.

```
adb logcat MainActivity:I '*:S' > a2.log &
# long-press a player (held DOWN), then release:
adb shell input motionevent DOWN <x> <y>; sleep 1.0; adb shell input motionevent UP <x> <y>
./check-menupeek.sh a2.log
```

**GREEN baseline (emulator `rl_arm64`, 2026-06-04):**
```
menu-open
native-overlay-built
commit-cancel
ANDROID_A2_MENUPEEK_GREEN md5=dc56e6b9e25cd46d2ef66ae7b7300152
```

## What needs manual / device confirm
Sliding the highlight onto a **non-cancel row and committing it** needs a *continuous* hold→drag→release
gesture. On this emulator neither split `adb input motionevent` calls (a MOVE/UP without a linked DOWN session
is dropped) nor raw `sendevent` (not routed to the app) can produce one. The row-highlight + the
row→engine-coordinate commit math mirror iOS exactly, and `selectMenuPoint` is the same proven click path as
`onClick` (verified firing on cancel). Confirm by hand on a device / with a mouse on the emulator: long-press an
NPC, slide down onto "Attack"/"Follow", release → the action executes; per-row haptic ticks while sliding.
