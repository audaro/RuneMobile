#!/usr/bin/env bash
# GPU Route C — DESKTOP reproduction of the device black-3D-scene blocker.
#
# The device-verified diagnosis (ios/dev-tools/gpu-routec/BLACK-SCENE-DIAGNOSIS.md): in GPU headless mode the
# engine UPLOADS the scene (loadScene/swapScene fire) and runs the composite (draw(int) ~60fps) but NEVER
# dispatches the per-frame zone render (preSceneDraw/drawZone*/postSceneDraw = 0) -> empty scene FBO -> black 3D,
# correct UI. The JNI GL bridge is proven end-to-end on device, so this is a render-gap, not a bridge fault.
#
# iOS and desktop share the SAME window-less HeadlessClientUI/CACIO canvas; only the GL bridge differs (EAGL on
# device, none on desktop). This harness boots real RuneLite headless under the DEVICE-shaped UnsafePoke CTC path
# (same as run-headless-login-unsafepoke.sh) with the throwaway Jagex login, and arms GpuHandshakeProbe, which
# replays GpuPlugin.startUp's engine handshake (setDrawCallbacks + setGpuFlags(GPU|ZBUF) + setExpandedMapLoading +
# resizeCanvas) with a NO-GL counting DrawCallbacks. So isGpu()==true with no GL context, and GpuSceneDiag logs
# whether the engine dispatches the per-frame scene render.
#
# READ THE RESULT at LOGGED_IN ([gpudiag] callbacks[...]):
#   preSceneDraw>0 / drawScene>0 on desktop  => the engine DOES dispatch the GPU scene render in this CACIO setup
#                                               => the device black-scene is iOS/bridge-specific. Focus there.
#   preSceneDraw=0 / drawScene=0 on desktop  => the device signature REPRODUCES on desktop => the gap is the
#                                               shared W2/CACIO setup, not iOS => attach jdb/IntelliJ here, break at
#                                               the scene-render dispatch, read the gate directly. No device rounds.
#
# safe-mode (DeviceHeadlessBoot default) keeps the built-in plugins but disables the REAL gpu plugin (which would
# fail to make a GL context headless anyway) — the handshake probe supplies GPU mode instead.
set -euo pipefail
cd "$(dirname "$0")"
REPO="../../.."

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
JAVA="$JAVA_HOME/bin/java"; JAVAC="$JAVA_HOME/bin/javac"
# QA-P1-15: default the version from gradle.properties (env VERSION still overrides) instead of a hardcoded literal.
VERSION="${VERSION:-$(sed -n 's/^project\.build\.version=//p' "$REPO/gradle.properties")}"
[ -n "$VERSION" ] || { echo "!! could not read project.build.version from $REPO/gradle.properties" >&2; exit 1; }
SHADED="$REPO/runelite-client/build/libs/client-${VERSION}-shaded.jar"
CACIOLIB="../cacio-smoke/lib"
CACIO="$CACIOLIB/cacio-tta-1.18.jar:$CACIOLIB/cacio-shared-1.18.jar"   # NO byte-buddy — UnsafePoke needs none
AWTSMOKE="../awtsmoke"
# HANDSHAKE=true (default) arms the no-GL GPU|ZBUF handshake (reproduces the device black-scene render-gap).
# HANDSHAKE=false is the CPU/software CONTROL: no handshake, safe-mode disables the gpu plugin, the engine
# renders the scene in software -> drawScene fires. Run the control with STACK=true to dump the live caller
# chain from the frame loop down to the scene-render dispatch (the path static decompile can't resolve).
HANDSHAKE="${HANDSHAKE:-true}"
STACK="${STACK:-false}"
OUT="out-gpu-handshake${HANDSHAKE_OUT_SUFFIX:-}"
[ "$HANDSHAKE" = "true" ] || OUT="out-gpu-handshake-cpuctl"
TOKENS="${TOKENS:-../tokens.json}"
RUN_SECONDS="${RUN_SECONDS:-180}"   # login + cache fetch + world load takes a while

if [ ! -f "$SHADED" ]; then
  echo "== building shaded client on JDK 21 =="
  (cd "$REPO" && ./gradlew :client:shadowJar --console=plain)
fi
if [ ! -f "$TOKENS" ]; then
  echo "!! $TOKENS missing — mint it first: ../fetch-shield-tokens.sh (throwaway account)" >&2
  exit 1
fi
command -v jq >/dev/null || { echo "!! jq required to read $TOKENS" >&2; exit 1; }

# ---- Map tokens.json -> JX_* env (the official-launcher handoff the gamepack reads) ----
export JX_ACCESS_TOKEN="$(jq -r '.access_token // ""' "$TOKENS")"
export JX_REFRESH_TOKEN="$(jq -r '.refresh_token // ""' "$TOKENS")"
export JX_SESSION_ID="$(jq -r '.session_id // ""' "$TOKENS")"
export JX_CHARACTER_ID="$(jq -r '.chosen_account_id // ""' "$TOKENS")"
export JX_DISPLAY_NAME="$(jq -r '.chosen_display_name // ""' "$TOKENS")"
if [ -z "$JX_SESSION_ID" ] || [ -z "$JX_CHARACTER_ID" ]; then
  echo "!! tokens.json has no session_id/chosen_account_id — Stage A of fetch-shield-tokens.sh must succeed" >&2
  exit 1
fi
echo "== JX handoff: displayName='${JX_DISPLAY_NAME}' characterId=${JX_CHARACTER_ID} session=${JX_SESSION_ID:0:6}… access=${JX_ACCESS_TOKEN:+set}${JX_ACCESS_TOKEN:-empty} =="

rm -rf "$OUT"; mkdir -p "$OUT/cap"
echo "== compile DeviceHeadlessBoot + activation (against shaded+cacio) =="
"$JAVAC" -cp "$SHADED:$CACIO" -d "$OUT" \
  "$AWTSMOKE/AwtActivation.java" "$AWTSMOKE/UnsafePokeActivation.java" "$AWTSMOKE/DeviceHeadlessBoot.java"

LOG="$OUT/run.log"
GPU_HANDSHAKE_PROP="-Drunelite.gpuhandshake=$HANDSHAKE"
echo "== launching real RuneLite under UnsafePoke CTC (handshake=$HANDSHAKE stack=$STACK, no OS window, ${RUN_SECONDS}s) =="
set +e
"$JAVA" \
  $GPU_HANDSHAKE_PROP \
  -Drunelite.gpudiag=true \
  -Drunelite.gpudiag.stack="$STACK" \
  -Dheadless.runSeconds="$RUN_SECONDS" \
  -Dheadless.captureTargetFrames=999 \
  -Drunelite.headless.capture.dir="$PWD/$OUT/cap" \
  -Drunelite.headless.capture.interval="${CAPTURE_INTERVAL:-10}" \
  -Drunelite.headless.capture.max="${CAPTURE_MAX:-60}" \
  -Drunelite.headless.capture.preLoginMax="${PRELOGIN_MAX:-40}" \
  -Drunelite.headless.welcomeplay="${WELCOMEPLAY:-true}" \
  -Drunelite.headless.autologin="${AUTOLOGIN:-true}" \
  -Drunelite.headless.autologin.eula="${AUTOLOGIN_EULA:-true}" \
  -Drunelite.headless.autologin.eula.point="${AUTOLOGIN_EULA_POINT:-302,312}" \
  -Drunelite.headless.autologin.eula.loginIndex="${AUTOLOGIN_EULA_INDEX:-12}" \
  -Drunelite.headless.autologin.point="${AUTOLOGIN_POINT:-382,248}" \
  -Drunelite.headless.autologin.world="${AUTOLOGIN_WORLD:-301}" \
  -Drunelite.headless.autologin.worldAddress="${AUTOLOGIN_WORLD_ADDRESS:-oldschool1.runescape.com}" \
  ${EXTRA_JVM_ARGS:-} \
  --add-exports=java.desktop/java.awt=ALL-UNNAMED \
  --add-exports=java.desktop/java.awt.peer=ALL-UNNAMED \
  --add-exports=java.desktop/sun.awt.image=ALL-UNNAMED \
  --add-exports=java.desktop/sun.java2d=ALL-UNNAMED \
  --add-exports=java.desktop/java.awt.dnd.peer=ALL-UNNAMED \
  --add-exports=java.desktop/sun.awt=ALL-UNNAMED \
  --add-exports=java.desktop/sun.awt.event=ALL-UNNAMED \
  --add-exports=java.desktop/sun.awt.datatransfer=ALL-UNNAMED \
  --add-exports=java.base/sun.security.action=ALL-UNNAMED \
  --add-opens=java.base/java.util=ALL-UNNAMED \
  --add-opens=java.desktop/java.awt=ALL-UNNAMED \
  --add-opens=java.desktop/sun.java2d=ALL-UNNAMED \
  --add-opens=java.base/java.lang.reflect=ALL-UNNAMED \
  -cp "$OUT:$CACIO:$SHADED" DeviceHeadlessBoot > "$LOG" 2>&1 &
PID=$!
sleep "$((RUN_SECONDS + 15))"
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
set -e

echo "== gameState + loginIndex progression =="
grep -E "\[headless-capture\] (gameState|loginIndex)|\[headless-login\]|\[welcomeplay\]" "$LOG" || echo "(no transitions logged — check $LOG)"
echo "== GPU handshake install =="
grep -E "\[gpuhandshake\]" "$LOG" || echo "(handshake never installed — check $LOG)"
echo "== scene-render caller chain (CPU control with STACK=true) =="
grep -A 40 "FIRST drawScene dispatch" "$LOG" | grep -E "FIRST drawScene|at " | head -40 || echo "(no stack — drawScene never dispatched, or STACK!=true)"
echo "== gpudiag callback counts (the answer) =="
grep -E "\[gpudiag\]" "$LOG" | tail -12 || echo "(no gpudiag lines — check $LOG)"
echo "== summary =="
grep -E '\[boot\]|injected-client|LOGGED_IN|LOGGING_IN|ERROR|Exception|UnsatisfiedLink' "$LOG" | tail -25 || true
echo "== full log: ios/dev-tools/headless/$LOG =="
