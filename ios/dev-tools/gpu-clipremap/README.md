# gpu-clipremap — three-way reverse-Z depth A/B on iOS GLES (Simulator)

> Branch `gpu`. A self-contained iOS Simulator GLES harness (mirrors `gpu-depthsim`/`gpu-b1`: EAGL ES3 offscreen
> FBO + `glReadPixels` + an md5-gated verdict) that races **three** reverse-Z depth strategies head-to-head on
> identical geometry, to decide how to fix the Route C river z-fight on **native EAGL without `glClipControl`** —
> and specifically whether an **early-Z-preserving** vertex remap can replace `gl_FragDepth`.
>
> Run: `xcodegen generate && xcodebuild -project GpuClipRemap.xcodeproj -scheme GpuClipRemap -destination "id=<booted-sim>" -derivedDataPath build/dd build`
> then `simctl install/launch`, pull `Documents/gpu-clipremap-verdict.log`, and `./clipremap-verdict.sh`.

## The three strategies

| | depth written | precision | early-Z / TBDR HSR |
|---|---|---|---|
| **baseline** | fixed-function `window_z = (NDC.z+1)/2` | the z-fight (far plane crushed into `[0.5,~0.51]`) | on |
| **fragdepth** | `gl_FragDepth = clip.z/clip.w = NDC.z` (frag stage) | full (desktop `clip_control` value) | **off** (Apple disables HSR on any `gl_FragDepth` write) |
| **clipremap** | `gl_Position.z = 2*clip.z - clip.w` (vertex stage) | capped — routes far plane back through the `(z+1)/2` cancellation | on |

## Result (md5-sealed: `evidence/gpu-clipremap-sim-verdict.log`)

```
PHASE 1 (float32 precision at Zfar=6000, the device's confirmed-32F buffer):
  baseline  distinct depths = 1129
  fragdepth distinct depths = 72231  (64.0x baseline)   <- full reverse-Z precision
  clipremap distinct depths = 4516   ( 4.0x baseline)   <- only 4x: the vertex remap does NOT recover precision

PHASE 2 (real DEPTH_COMPONENT32F z-fight, FAR): baseline=131072 (collapse)  fragdepth=8704 (~15x)  clipremap=5632
PHASE 3 (PER-VERTEX coplanar bias layering): baseline=0  fragdepth=0  clipremap=0   <- all preserve decorations-on-floors
CONCLUSION = FRAGDEPTH_ONLY
```

## What this settles

1. **The vertex `2z-w` remap is NOT a precision fix.** It recovers only ~4x (vs `gl_FragDepth`/`clip_control`'s 64x)
   because the fixed-function `(NDC.z+1)/2` windowing re-introduces the exact catastrophic cancellation
   `glClipControl(ZERO_TO_ONE)` exists to avoid. It cleans the simple 2-plane test but won't be robust for dense
   coplanar geometry. Attractive (keeps early-Z) but insufficient on its own.
2. **`gl_FragDepth` is the only full-precision EAGL depth fix** (64x, ~15x cleaner z-fight), confirming `gpu-depthsim`.
   Its sole open cost is that writing `gl_FragDepth` **disables Apple TBDR Hidden Surface Removal / early-Z** — a
   perf hit that a **software renderer cannot measure**; it must be measured **on device** at OSRS overdraw with
   117HD's heavy fragment shaders.
3. **Per-vertex coplanar bias survives all three** (Phase 3 = 0 bleed) — closing the gap `gpu-depthsim` left open
   (it tested only a per-DRAW uniform bias; the plugin's bias is a per-vertex attribute `screenPos.z += bias/128`).

## Decision

- If `gl_FragDepth`'s device early-Z cost is acceptable → **EAGL + `gl_FragDepth`** = a wedge-free full depth fix
  (no ANGLE, no wedge bug).
- If it is too costly → use **ANGLE `clip_control`** (64x precision, early-Z intact) and fix the ANGLE near-plane
  **wedge bug** (a vertex-shader `w`-guard; separate harness).

⚠️ **Caveat:** `GL_RENDERER = Apple Software Renderer` (the Simulator), not the device Metal GPU. This proves depth
MECHANISM + PRECISION + layering and HONORS `gl_FragDepth`; it does **not** represent device perf or the TBDR
early-Z behavior. One device run is still warranted for the perf measurement.
