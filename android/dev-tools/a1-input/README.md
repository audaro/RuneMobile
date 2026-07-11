# A1 — input parity

Brings Android up to the iOS Phase-5 control scheme (minus the native menu, which is A2). All bridge methods are
the existing `JavaBridge` surface proven present by the A-1 census; A1 is host wiring + Android input UI.
(The baseline `onClick`/`onTouch`/`onCameraDrag`/`clearHover` core input landed earlier — Milestone B / A0;
the table below is the A1 *additions*.)

## What's implemented
Native (`jvm_bootstrap.cpp`) + Kotlin (`JvmLauncher.kt`) bridge extension and the `MainActivity` input UI:

| Feature | Bridge | Android input |
|---|---|---|
| Pinch-to-zoom | `onWheel(x,y,rot)` | `ScaleGestureDetector` → wheel notches at the pinch centroid (spread = zoom in) |
| Camera rotate | `onCameraDrag` | one-finger scroll (suppressed while a pinch is in progress) |
| Precise (no-snap) tap | `onClickPrecise` | wired; used by chrome/menu in later phases |
| Hover / menu-track | `onMove` | pre-hover on single-finger ACTION_DOWN |
| Soft-keyboard text | `onText` | hidden `GameInputView` InputConnection → `commitText` |
| Special keys | `onKeyStroke(vk)` | InputConnection `sendKeyEvent`/`deleteSurroundingText` → AWT vks (BACK_SPACE/ENTER/arrows) |
| Keyboard auto-raise | `isTextInputOpen()` | per-frame Choreographer poll → show/hide IME |
| Interact haptic | `getInteractTapSeq()` | per-frame poll → `VibrationEffect` on advance |
| Finger snap radius | `snapRadius()` | polled read-surface |

Read-surface (`isTextInputOpen`/`getInteractTapSeq`/`snapRadius`) is polled by the HotSpot-attached render
thread into atomics; the UI thread reads them each frame (never attaches to HotSpot) — same pattern as the
frame dims.

## What's verified (emulator, no device)
- **Build:** `:app:assembleDebug` clean (NDK arm64 + Kotlin).
- **No regression:** autologin still reaches LOGGED_IN (`a0-login` gate md5 unchanged).
- **Read-surface — GREEN:** tap an interactable in-world → the per-frame poll observes `interactTapSeq`
  advance and fires the haptic. This is the same poll loop that drives the keyboard auto-raise, so the read
  mechanism is proven end-to-end.

```
./check-input.sh                 # live `adb logcat -d`
./check-input.sh saved.log       # a saved (ideally filtered) dump
```
Tip: the in-game logcat is high-volume and rotates fast — capture our tags only to avoid losing the line:
`adb logcat MainActivity:I '*:S' > a1.log &`, tap an entity (a player/NPC/object in the world viewport), then
run `./check-input.sh a1.log`.

**GREEN baseline (emulator `rl_arm64`, 2026-06-04):**
```
interactTapSeq:advanced
ANDROID_A1_READSURFACE_GREEN md5=61b01f11fe972d7f6e338dc131ebc561
```

## What needs manual / device confirm (not `adb`-injectable)
`adb` cannot synthesize a **multitouch pinch** or route an **IME into an in-game text field**, so the two
*write* paths are confirmed by hand (on the emulator with a mouse-wheel/host keyboard, or on a real device):
- **Pinch-zoom (`onWheel`):** two-finger pinch on the scene → the camera zooms (RuneLite zoom varc changes).
  The UI→native→drain→bridge plumbing is identical to the proven `onClick`/`onCameraDrag` paths; only the
  gesture→notch mapping (`ScaleListener`) is A1-new.
- **Keyboard (`onText`/`onKeyStroke` + `isTextInputOpen`):** open an in-game text field (press Enter for chat,
  or a bank/“enter amount” dialog) → the soft keyboard auto-raises (logcat `a1: textInputOpen=true`) → typed
  text appears in the field; backspace/enter work.
