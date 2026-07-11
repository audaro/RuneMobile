# gpu-tbo2d — RLHD `textureFaces` (GL_RGB32I texture-buffer) → 2D integer-texture repack (117HD blocker #1)

> Branch `gpu`. Self-contained iOS Simulator GLES harness (mirrors `gpu-depthsim`/`gpu-b1`/`gpu-clipremap`:
> EAGL ES3 offscreen FBO + `glReadPixels` + md5-gated verdict). Retires the single largest unproven piece of the
> 117HD-on-iOS port — the texture-buffer repack — validated against **RLHD's real format and fetch idiom**.
>
> Run: `xcodegen generate && xcodebuild -project GpuTbo2d.xcodeproj -scheme GpuTbo2d -destination "id=<booted-sim>" -derivedDataPath build/dd build`,
> then `simctl install/launch`, pull `Documents/gpu-tbo2d-verdict.log`, and `./tbo2d-verdict.sh`.

## The real RLHD schema (rlhd-src rev 7dded59)

| | |
|---|---|
| Buffer format | **`GL_RGB32I`** — `GLTextureBuffer.java:28` `glTexBuffer(target, GL_RGB32I, id)` → 3×int32 per texel |
| Declaration | `uniform isamplerBuffer textureFaces;` — `scene_vert.glsl:43`, `shadow_vert.glsl:42` |
| Layout | each **face = 3 consecutive texels** at base index `vTextureFaceIdx` (a per-vertex `int` attribute, location 3) |
| Fetch idiom | `texelFetch(textureFaces, vTextureFaceIdx{,+1,+2}).xyz` (flat/provoking path) **and** `texelFetch(textureFaces, vTextureFaceIdx{,+1})[vertex]` (per-vertex, `vertex = gl_VertexID % 3`) — `scene_vert.glsl:77-90`, `shadow_vert.glsl:54-57` |

`isamplerBuffer` / `GL_TEXTURE_BUFFER` is **ES 3.2 core** — present on Android's Mali-G715, **absent on iOS EAGL
GLES 3.0 *and* ANGLE-on-Metal ES 3.0**. So the port must repack the buffer into a 2D texture. Blocker **#1** in
`ios/HD-PORT-BLUEPRINT.md` §5, **backend-independent**, **upstream of every Zone shader**, and **0%-de-risked by
Android** (it had native TBO).

## Result (md5-sealed: `evidence/gpu-tbo2d-sim-verdict.log`)

```
GL_MAX_TEXTURE_SIZE=4096   16000 faces x 3 = 48000 texels  >  4096  ->  a 1D texture CANNOT hold them: 2D REQUIRED
PHASE A  A_RGB32I_SAMPLEABLE = YES   A_RGBA32I_SAMPLEABLE = YES   ->  REPACK_FORMAT = RGB32I (exact, ZERO host transform)
PHASE B  fragment, RLHD fetch idiom (idx/idx+1/idx+2 .xyz + dynamic [v]) ..... green=16000/16000 red=0  -> B_FRAG_EXACT = YES
PHASE C  vertex stage (gl_VertexID, the scene_vert/shadow_vert pathway) ...... green=16000/16000 red=0  -> C_VERT_EXACT = YES
VERDICT  tbo2d_repack_exact = YES
```

## What this proves

1. **`GL_RGB32I` (RLHD's real format) is sampleable as a 2D texture on iOS GLES 3.0** — so the repack is a pure
   re-`glTexImage2D` of the *same bytes*, **no per-frame data transform** (RGB→RGBA padding is unnecessary; it's
   available as a fallback and also works).
2. The repacked `texelFetch(tex, ivec2(idx % W, idx / W))` is **byte-exact** vs a CPU reference for the **real RLHD
   fetch idiom**: 3 consecutive texels per face, both `.xyz` and **dynamic `[vertex]` component indexing**, with
   spans that **straddle row boundaries**, for all 16,000 faces.
3. It works in the **vertex stage** (`gl_VertexID`-driven) — the exact stage RLHD fetches in.
4. The texel count (48,000) **exceeds `GL_MAX_TEXTURE_SIZE` (4096)**, so 2D is the *only* viable layout.

Integer 2D textures, `texelFetch`, and vertex texture fetch are **ES 3.0 core**, so this software-renderer GREEN is
high-confidence for the device Metal GPU. The one device-checkable item — `GL_RGB32I` 2D format support (PHASE A) —
is reported explicitly so a device run can re-confirm it cheaply.

## The downporter transform (drop into the iOS Zone staging step)

A mechanical 3-rule rewrite of each RLHD shader that declares `textureFaces` (`scene_vert`, `shadow_vert`):

```
RULE 1  uniform isamplerBuffer textureFaces;
     -> uniform highp isampler2D textureFaces;

RULE 2  inject at the top of main():
        int tfW = textureSize(textureFaces, 0).x;

RULE 3  texelFetch(textureFaces, EXPR)
     -> texelFetch(textureFaces, ivec2((EXPR) % tfW, (EXPR) / tfW), 0)
        (the .xyz / [vertex] swizzle after the call is UNCHANGED)
```

As a `sed`-style pass for `stage-rlhd-zone-jar.sh` (iOS variant), applied per shader file:

```sh
# rule 1
s/uniform[[:space:]]\+isamplerBuffer[[:space:]]\+textureFaces;/uniform highp isampler2D textureFaces;/
# rule 2 (inject after the first `void main() {` in a file that uses textureFaces)
# rule 3 (wrap every textureFaces index expression)
s/texelFetch(textureFaces,\([^)]*\))/texelFetch(textureFaces, ivec2((\1) % tfW, (\1) \/ tfW), 0)/g
```

(Rule 2 is a one-line injection; do it in the staging script's awk/python pass, gated on the file containing
`textureFaces`. Width `tfW` is read from the texture itself via `textureSize`, so no extra uniform and no host/shader
width contract to keep in sync.)

## The host / facade upload change

RLHD builds the buffer in `GLTextureBuffer.initialize`/`ensureCapacity` via `glTexBuffer(GL_RGB32I, bufId)`. The iOS
facade replaces that with a 2D upload of the same bytes (no data transform, since RGB32I 2D is sampleable):

```
numTexels = byteLength / 12                       // RGB32I = 12 bytes/texel
W         = min(GL_MAX_TEXTURE_SIZE, nextPow2OrCap)   // e.g. 2048; any W <= GL_MAX_TEXTURE_SIZE
H         = ceil(numTexels / W)
glBindTexture(GL_TEXTURE_2D, texId);
glTexParameteri(... MIN/MAG_FILTER, GL_NEAREST);  // integer textures require NEAREST
glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB32I, W, H, 0, GL_RGB_INTEGER, GL_INT, bytes);  // pad last row to W*H*12
```

Bind it to the same texture unit RLHD uses (`TEXTURE_UNIT_TEXTURED_FACES`) as a normal `sampler2D` binding instead of
the buffer-texture bind. This lives behind the Route C facade (the `org.lwjgl.opengl` shim) so RLHD source is
unmodified except the shader downport above.

## Next

- Wire RULES 1-3 into the iOS `stage-rlhd-zone-jar` shader pass and the facade upload above, when iOS Zone **B0**
  (renderer bring-up) starts. This probe is the correctness oracle for that wiring.
- The other ES-3.0 blockers (§5: draw-indirect strip, `glFramebufferTextureLayer`, RGBA16UI-array probe,
  clamp-to-border, `#version 420/430`→`300 es`) are separate, smaller items.
