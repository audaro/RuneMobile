#!/usr/bin/env bash
# Touch-targeting de-risk (W3): prove the PRESS-AND-PEEK menu-peek primitive + the production MenuPeekBridge
# on desktop OpenJDK 21 + CACIO before building the native touch UI (the W2 develop-first rule). Boots real
# RuneLite headless under the CACIO CTC toolkit (no OS window — the honest iOS proxy), logs in to a throwaway
# account, and enables:
#   -Drunelite.menupeek=true        the production MenuPeekBridge read surface (ships to device — the native
#                                   reticle/chip polls its JSON snapshot; read-only, never invokes)
#   -Drunelite.menupeek.probe=true  the desktop-only MenuPeek diagnostic: synth MOUSE_MOVED onto each visible
#                                   NPC's clickbox, read getMenuEntries() a cycle later, assert the TAIL entry
#                                   targets that named entity, AND cross-check MenuPeekBridge published the
#                                   same top this frame. Measures latency; confirms peek never opens a menu.
# Read-only (no press/click/menuAction beyond the one welcome-screen click to enter the world).
#
# The GREEN/RED verdict is computed by menupeek-verdict.sh (bash, md5-gated) — never a JVM-printed string.
set -euo pipefail
cd "$(dirname "$0")"
REPO="../../.."

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
JAVA="$JAVA_HOME/bin/java"
JAVAC="$JAVA_HOME/bin/javac"
JAR="$REPO/runelite-client/build/libs/client-1.12.28-SNAPSHOT-shaded.jar"
TOKENS="${TOKENS:-$REPO/ios/dev-tools/tokens.json}"
CACIOLIB="../cacio-smoke/lib"
CACIO="$CACIOLIB/cacio-tta-1.18.jar:$CACIOLIB/cacio-shared-1.18.jar:$CACIOLIB/byte-buddy-1.14.11.jar:$CACIOLIB/byte-buddy-agent-1.14.11.jar"
JUNIT="$CACIOLIB/junit-platform-console-standalone-1.10.2.jar"
OUT="out-menupeek"
RUN_SECONDS="${RUN_SECONDS:-70}"

if [ ! -f "$JAR" ]; then
  echo "== building shaded client on JDK 21 (picks up MenuPeek) =="
  (cd "$REPO" && ./gradlew :client:assemble --console=plain)
fi
if [ ! -f "$CACIOLIB/cacio-tta-1.18.jar" ] || [ ! -f "$JUNIT" ]; then
  echo "!! cacio/junit jars missing in $CACIOLIB — see ../cacio-smoke/README.md to fetch them" >&2
  exit 1
fi

# ---- Jagex login (REQUIRED: the peek primitive only has menu entries when LOGGED_IN with entities in view) ----
LOGIN_PROPS=()
if [ -f "$TOKENS" ] && command -v jq >/dev/null; then
  export JX_ACCESS_TOKEN="$(jq -r '.access_token // ""' "$TOKENS")"
  export JX_REFRESH_TOKEN="$(jq -r '.refresh_token // ""' "$TOKENS")"
  export JX_SESSION_ID="$(jq -r '.session_id // ""' "$TOKENS")"
  export JX_CHARACTER_ID="$(jq -r '.chosen_account_id // ""' "$TOKENS")"
  export JX_DISPLAY_NAME="$(jq -r '.chosen_display_name // ""' "$TOKENS")"
  if [ -n "$JX_SESSION_ID" ] && [ -n "$JX_CHARACTER_ID" ]; then
    echo "== JX handoff present (displayName='${JX_DISPLAY_NAME}') — autologin enabled =="
    LOGIN_PROPS=(
      -Drunelite.headless.autologin=true
      -Drunelite.headless.autologin.point="${AUTOLOGIN_POINT:-382,248}"
      -Drunelite.headless.autologin.world="${AUTOLOGIN_WORLD:-301}"
      -Drunelite.headless.autologin.worldAddress="${AUTOLOGIN_WORLD_ADDRESS:-oldschool1.runescape.com}"
    )
  fi
fi
if [ ${#LOGIN_PROPS[@]} -eq 0 ]; then
  echo "!! no JX handoff (tokens.json) — the peek probe needs to be LOGGED_IN; verdict will be INCONCLUSIVE" >&2
fi

mkdir -p "$OUT"
echo "== compile MobileUiSmoke (thin CACIO activation wrapper, reused) =="
"$JAVAC" -cp "$CACIO:$JUNIT:$JAR" -d "$OUT" MobileUiSmoke.java

L1="$OUT/menupeek.log"
echo "== launch -> $L1 =="
set +e
"$JAVA" \
  -ea \
  -Drunelite.menupeek=true \
  -Drunelite.menupeek.probe=true \
  ${MENUPEEK_OPTS:-} \
  -Djdk.attach.allowAttachSelf=true \
  -Dheadless.runSeconds="$RUN_SECONDS" \
  ${LOGIN_PROPS[@]+"${LOGIN_PROPS[@]}"} \
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
  -jar "$JUNIT" \
  -cp "$OUT:$CACIO:$JAR" \
  --select-class=MobileUiSmoke \
  --details=none \
  > "$L1" 2>&1 &
PID=$!
sleep "$((RUN_SECONDS + 10))"
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null
set -e

echo "== PEEK_* markers =="
grep -E "^PEEK_" "$L1" || echo "(no PEEK_ markers — did it reach LOGGED_IN? see $L1)"
echo
./menupeek-verdict.sh "$L1"
echo "log: ios/dev-tools/headless/$L1"
