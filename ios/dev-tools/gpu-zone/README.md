# gpu-zone — iOS Zone Z0 conformance harness (RLHD zone shaders → ES 3.00 on EAGL)

> Branch `gpu`. Phase **Z0** of `ios/HD-ZONE-B0-SCOPE.md` / `ios/HD-PORT-BLUEPRINT.md` §5: a fail-closed gate that
> proves the **entire RLHD zone-path shader surface compiles on native EAGL GLES 3.0** before any renderer work.
> Clones the proven `gpu-b1` pattern (xcodegen + EAGL offscreen compile + md5-sealed verdict). Backend = **EAGL**
> (the 2026-06-09 device A/B locked EAGL + `gl_FragDepth`; ANGLE is not used).

## Layout

- `rlhd-src/` — vendored RLHD @ `7dded59` (BSD-2): `shaders/hd/**/*.glsl` (47 zone shaders, `#include`/`#define`
  unresolved) + `java/…/shader/{ShaderIncludes,ShaderTemplate,ShaderException}.java` (the assembler) + `LICENSE` +
  `PROVENANCE.md`.
- `app/` — the probe app: `ZoneDownport.{h,m}` (GLSL→ES 3.00 rewriter), `ZoneProbe.{h,m}` (compile loop), `main.m`.
- `assembled/` — RLHD-Template-assembled shaders, bundled flat as `<name>.<stage>.assembled.glsl`. **Empty until the
  assemble step exists** (see Status).
- `project.yml` — xcodegen (`xcodegen generate` → `GpuZone.xcodeproj`).
- `gpu-zone-z0-verdict.sh` — md5-gated verdict over the pulled `gpu-zone-z0-verdict.log`.

## The pipeline

```
RLHD .glsl (#include/#define)  ──assemble──►  flat desktop GLSL (#version 420/430)
                                                      │  ZoneDownport
                                                      ▼
                                            GLSL ES 3.00  ──glCompileShader──►  EAGL ES3 (Sim → device)
```

## ZoneDownport — what's implemented (`app/ZoneDownport.m`)

Superset of the base-gpu B1 downporter. Per the blueprint §5 blocker list:
1. `#version <any>` (RLHD injects **420/430**, not 330) → `#version 300 es`  *(#7)*
2. inject `precision …` qualifiers (float/int/sampler2DArray/sampler2D/**isampler2D/usampler2D**)
3. drop `noperspective`
4. strip float-literal `f`/`F` suffixes
5. **`textureFaces` texture-buffer → 2D `isampler2D` repack** (3 rules, proven byte-exact in `gpu-tbo2d`)  *(#1)*
6. explicit int↔float casts — **site set discovered from Z0 compile errors** (empty until the compile loop runs;
   prefer hand-maintained variants for the cast-heavy files per the blueprint).

## Status — done / in progress / remaining

**Done:** vendored RLHD source; the **assemble step (`assemble/ZoneShaderAssemble.java`)** — a dependency-free
host-JVM replica of RLHD's `ShaderIncludes.parse()` that resolves all `#include`/`#define` from the fixed
minimal-config define map AND applies the **GLSL 330→ES 3.00 downport** (the single source of truth for the rules;
`app/ZoneDownport.m` is now superseded for the gate — the probe compiles the pre-downported `assembled/` shaders
as-is). The `MAX_SIMULTANEOUS_WORLD_VIEWS`/`WORLD_VIEW_GETTER` overrides `ZoneRenderer.addShaderIncludes()` does and
the `MATERIAL_CONSTANTS` named-material defines are replicated in the config. **`ios-overrides/`** shadow-dir
(resolved before `rlhd-src/`) holds hand-maintained ES3 copies of pervasively cast-heavy files
(`utils/color_utils.glsl`). **`glslang-check.sh`** = an offline fast-filter (glslang at `#version 310 es` to suppress
its interface-block false-positives) that reports many #13 sites per pass — works for shadow/ui, but **not scene**
(glslang bails at scene's in/out interface blocks, which Apple's EAGL accepts).

**B0.5 MATERIAL STORE — GREEN ON THE REAL DEVICE ✅ (2026-06-09).** The B0.5 runtime blocker (`glLinkProgram:
"Uniform interface block UBOMaterials too large (57120 exceeds max 16384)"` — Apple's GLES-on-Metal caps uniform
blocks at 16 KB; the real material set is 595 × 96 B std140) is fixed by **texture-backing the material data**:
`ios-overrides/uniforms/materials.glsl` drops the UBO block and rebuilds `getMaterial(i)` from 6×RGBA32I
`texelFetch`es per material (same std140 bytes, `materialStore` isampler2D on unit 6), and the **`java-overrides/`**
overlay (new: laid over `rlhd-src` at stage time, same pattern as `ios-overrides`) makes `MaterialManager` upload
the UBO's serialized ByteBuffer verbatim into that texture + wires the sampler in `SceneShaderProgram` /
`ShadowShaderProgram`. Gates: assembler now uses the REAL `MATERIAL_COUNT 595` — the **negative control**
(`evidence/gpu-zone-b05-materialstore-NEGCONTROL.log`, override held out) reproduces the exact device link failure
on scene AND shadow, then the fix run links **3/3 → sealed `evidence/gpu-zone-b05-materialstore-DEVICE-GREEN.log`**
(md5 `373b9b4a7d633e91c9fe4a8e89ae1011`, the verdict-script default). `./check-std140.sh` host-gates the GLSL
decode map against the actual `UniformBuffer` layout engine (`STD140_DECODE_MAP_MATCHES`). Staged class md5 is now
`d4dc966c00af9b0d983f25eecce62f73` (java overlay changed classes).

**Z0 COMPLETE — GREEN ON THE REAL DEVICE ✅** (iPhone 17 Pro Max, A19 Pro, `GL_VERSION = OpenGL ES 3.0 Metal -
104.1`): **6/6 compile + 3/3 link → `Z0_ZONE_SHADER_GATE_GREEN`**, sealed `evidence/gpu-zone-z0-DEVICE-GREEN.log`
(md5 `6690f2b89cb5c4f183e9147926afa4c2`; note Z0 ran at the placeholder `MATERIAL_COUNT 1`, which is why it could
not catch the 16 KB cap; `./gpu-zone-z0-verdict.sh <log> 6690f…` reproduces). The Sim run is kept too
(`evidence/gpu-zone-z0-sim-GREEN.log`) — Sim and device agree, retiring the "Sim compiler ≠ A19" caveat. All of
scene/shadow/ui × vert/frag compile to ES 3.00 AND all three programs link (vertex-out interface blocks match the
fragment-in blocks — no varying mismatch). **GpuZone has no JVM/JIT** (pure EAGL shader-compile probe), so the device
run is just `devicectl install` + `process launch` — no StikDebug. Cleared: `#version`-first, precision, zero-array,
MAT_*-constants, the shadows-off `sampleShadowMap` int-`0` stub macro, the full #13 int↔float pass. ios-overrides:
`utils/color_utils.glsl`, `utils/water.glsl`, `utils/fog.glsl`; everything else via targeted CAST rules. Also fixed a
real downport bug (the `f`-suffix strip corrupting `material1.flowMap`→`lowMap`).

## Phase B0 — renderer bring-up (`ios/HD-ZONE-B0-SCOPE.md`)

**B0.1 GREEN (host, no device).** `stage-ios-zone-jar.sh` stages the iOS-variant RLHD jar: it compiles the
RLHD source — pristine (`rlhd-src/src/`, full tree @ `7dded59`, gitignored — see `rlhd-src/PROVENANCE.md`)
except the committed **`java-overrides/`** laid over it at stage time (B0.5: the materials subsystem) —
against `[facade/ : lwjgl-stripped client jar]` with lombok as an annotation processor, then re-zips
`rs117/**` classes + RLHD shader/JSON resources (no `org/lwjgl`/`rlawt` — facade ships in the gpu jar). Verdict
`IOS_RLHD_STAGE_GREEN`: **304 RLHD classes** (== the Android count at this rev), 0 lwjgl leak, 47 shaders, 9
loader JSON, `ZoneRenderer` + `OpenCLManager` present; class md5 `d4dc966c00af9b0d983f25eecce62f73`
(`04e0b29fa4761cca3386d8eb6ca457d3` was the pre-overlay B0.1 seal). The
`facade/` (35 classes) is the RLHD-complete superset of the base-gpu facade and is the **spec** for the B0.3
native delta (see `facade/README.md`). Output: `ios/app/jvm-resources/client-rlhd.jar`
(gitignored, regen via the script).

**Next (B0.2+):** facade `glTexBuffer`→2D `glTexImage2D` RGB32I upload (blocker #1), the `RouteCBridge.m` native
facade delta (~50 GL calls), Java conformance fixes (#2/#11/#14 + `gl_FragDepth` scene/shadow depth-write), wire +
boot the ZoneRenderer. (Z0 used the minimal flat-scene config — shadows/tiled/dynamic-lights/displacement/POM OFF;
enabling those in B1+ surfaces their shader code's own #13 sites, which the assembler config + CAST map grow to cover.)

### Device run (reproduce)
```sh
cd ios/dev-tools/gpu-zone && xcodegen generate
xcodebuild -project GpuZone.xcodeproj -scheme GpuZone -destination 'generic/platform=iOS' \
  -derivedDataPath build-ios -allowProvisioningUpdates build
DEV=<iphone-uuid>   # xcrun devicectl list devices
xcrun devicectl device install app --device "$DEV" build-ios/Build/Products/Debug-iphoneos/GpuZone.app
xcrun devicectl device process launch --device "$DEV" dev.audaro.gpuzone   # no StikDebug needed
xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer \
  --domain-identifier dev.audaro.gpuzone --source Documents/gpu-zone-z0-verdict.log --destination ./z0-device.log
./gpu-zone-z0-verdict.sh ./z0-device.log <md5>
```

**Iterate loop:** edit `assemble/ZoneShaderAssemble.java` (CAST rules) or add an `ios-overrides/` file →
`cd assemble && javac ZoneShaderAssemble.java && java ZoneShaderAssemble` → for shadow/ui: `./glslang-check.sh`
(fast); for scene: `xcodegen generate && xcodebuild -sdk iphonesimulator … && simctl install/launch
dev.audaro.gpuzone` → pull `Documents/gpu-zone-z0-verdict.log`.

---

### Reference — the assembler's fixed define-list (`HdPlugin.getShaderIncludes()` @ `7dded59`)

```
addIncludePath(SHADER_PATH)
addInclude  VERSION_HEADER = "#version 420\n…"  (Linux) | "#version 430\n" (Windows)  ← downporter rewrites anyway
define UI_SCALING_MODE, COLOR_BLINDNESS, APPLY_COLOR_FILTER
define MATERIAL_COUNT (= MaterialManager.MATERIALS.length), WATER_TYPE_COUNT
define DYNAMIC_LIGHTS, TILED_LIGHTING, TILED_LIGHTING_LAYER_COUNT, TILED_LIGHTING_TILE_SIZE, MAX_LIGHT_COUNT
define NORMAL_MAPPING, PARALLAX_OCCLUSION_MAPPING
define SHADOW_MODE, SHADOW_TRANSPARENCY, SHADOW_FILTERING, SHADOW_RESOLUTION
define VANILLA_COLOR_BANDING, UNDO_VANILLA_SHADING, LEGACY_GREY_COLORS, DISABLE_DIRECTIONAL_SHADING, FLAT_SHADING
define WIND_DISPLACEMENT(+NOISE_RESOLUTION), CHARACTER_DISPLACEMENT, MAX_CHARACTER_POSITION_COUNT, WIREFRAME
define WINDOWS_HDR_CORRECTION
define LEGACY_RENDERER=false, ZONE_RENDERER=true          ← we are the zone renderer
define MAX_SIMULTANEOUS_WORLD_VIEWS=0, WORLD_VIEW_GETTER=""
addInclude MATERIAL_CONSTANTS (#define MAT_<NAME> getMaterial(idx) … from MaterialManager.MATERIAL_MAP)
addInclude MATERIAL_GETTER  = generateGetter("Material", MATERIAL_COUNT)
addInclude WATER_TYPE_GETTER = generateGetter("WaterType", WATER_TYPE_COUNT)
addUniformBuffer  uboGlobal, uboLights, uboLightsCulling, uboUI, uboMaterials, uboWaterTypes   ← std140 block emit
renderer.addShaderIncludes(includes)   ← ZoneRenderer-specific includes
```

The material/UBO dynamic includes (`MATERIAL_CONSTANTS`, the getters, the `addUniformBuffer` std140 blocks) need
minimal data — either drive them from the vendored material/UBO Java (pull from the pinned rev) or stub to a small
fixed set for the flat-scene gate, then grow with B1. Once `assembled/` is populated: `xcodegen generate`, build for
the Simulator (cheap inner loop), pull the log, iterate rule #6 until clean, then **device confirm** (Sim compiler ≠
A19), then seal the md5.

## Run (once assembled/ is populated)

```sh
cd ios/dev-tools/gpu-zone && xcodegen generate
xcodebuild -project GpuZone.xcodeproj -scheme GpuZone -sdk iphonesimulator \
  -derivedDataPath build -destination 'generic/platform=iOS Simulator' build
# boot a sim, install, launch, then:
xcrun simctl get_app_container booted dev.audaro.gpuzone data   # → Documents/gpu-zone-z0-verdict.log
./gpu-zone-z0-verdict.sh <pulled-log>
```
