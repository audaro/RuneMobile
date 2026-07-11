#!/usr/bin/env bash
# Phase-6 (W3) STEP-0 de-risk: prove the MobileUiBridge facade's thread semantics + type/config serialization
# on desktop OpenJDK 21 BEFORE building any native UI (the W2 develop-first rule). Boots real RuneLite headless
# under the CACIO CTC toolkit (no OS window — the honest iOS proxy) with:
#   -ea                          so the startPlugin/stopPlugin EDT asserts are LIVE (a no-op -ea would hide a
#                                wrong-thread bug — see the design audit's risk #2)
#   -Drunelite.mobileui=true     arms the facade + its tick() snapshot
#   -Drunelite.mobileui.smoke=true  arms the MobileUiSmokeRunner daemon (the SAME checks that run on device)
#
# The checks live in net.runelite.client.headless.MobileUiSmokeRunner (in the jar) so desktop and device run
# IDENTICAL bytes; here MobileUiSmoke.java is just the CACIO/JUnit activation wrapper. Runs TWICE so the second
# launch reads the first launch's config sentinel back off disk (cross-launch persistence). The GREEN/RED
# verdict is computed by mobileui-verdict.sh (bash, md5-gated) — never a JVM-printed success string.
set -euo pipefail
cd "$(dirname "$0")"
REPO="../../.."

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
JAVA="$JAVA_HOME/bin/java"
JAVAC="$JAVA_HOME/bin/javac"
# QA-P1-15: derive the version from gradle.properties instead of a hardcoded literal (broken on the next bump).
VERSION="$(sed -n 's/^project\.build\.version=//p' "$REPO/gradle.properties")"
[ -n "$VERSION" ] || { echo "!! could not read project.build.version from $REPO/gradle.properties" >&2; exit 1; }
JAR="$REPO/runelite-client/build/libs/client-${VERSION}-shaded.jar"
TOKENS="${TOKENS:-$REPO/ios/dev-tools/tokens.json}"
CACIOLIB="../cacio-smoke/lib"
CACIO="$CACIOLIB/cacio-tta-1.18.jar:$CACIOLIB/cacio-shared-1.18.jar:$CACIOLIB/byte-buddy-1.14.11.jar:$CACIOLIB/byte-buddy-agent-1.14.11.jar"
JUNIT="$CACIOLIB/junit-platform-console-standalone-1.10.2.jar"
OUT="out-mobileui"
RUN_SECONDS="${RUN_SECONDS:-55}"

if [ ! -f "$JAR" ]; then
  echo "== building shaded client on JDK 21 (picks up MobileUiBridge + MobileUiSmokeRunner) =="
  (cd "$REPO" && ./gradlew :client:assemble --console=plain)
fi
if [ ! -f "$CACIOLIB/cacio-tta-1.18.jar" ] || [ ! -f "$JUNIT" ]; then
  echo "!! cacio/junit jars missing in $CACIOLIB — see ../cacio-smoke/README.md to fetch them" >&2
  exit 1
fi

# ---- optional Jagex login (only needed for the chat-bounds check) ----
LOGIN_PROPS=()
if [ -f "$TOKENS" ] && command -v jq >/dev/null; then
  export JX_ACCESS_TOKEN="$(jq -r '.access_token // ""' "$TOKENS")"
  export JX_REFRESH_TOKEN="$(jq -r '.refresh_token // ""' "$TOKENS")"
  export JX_SESSION_ID="$(jq -r '.session_id // ""' "$TOKENS")"
  export JX_CHARACTER_ID="$(jq -r '.chosen_account_id // ""' "$TOKENS")"
  export JX_DISPLAY_NAME="$(jq -r '.chosen_display_name // ""' "$TOKENS")"
  if [ -n "$JX_SESSION_ID" ] && [ -n "$JX_CHARACTER_ID" ]; then
    echo "== JX handoff present (displayName='${JX_DISPLAY_NAME}') — chat-bounds check enabled =="
    LOGIN_PROPS=(
      -Drunelite.headless.autologin=true
      -Drunelite.headless.autologin.point="${AUTOLOGIN_POINT:-382,248}"
      -Drunelite.headless.autologin.world="${AUTOLOGIN_WORLD:-301}"
      -Drunelite.headless.autologin.worldAddress="${AUTOLOGIN_WORLD_ADDRESS:-oldschool1.runescape.com}"
    )
  fi
else
  echo "== no tokens.json — running core proofs without login (chat-bounds check skipped) =="
fi

mkdir -p "$OUT"
echo "== compile MobileUiSmoke (thin CACIO wrapper) =="
"$JAVAC" -cp "$CACIO:$JUNIT:$JAR" -d "$OUT" MobileUiSmoke.java

run_launch() # $1=logfile
{
  local log="$1"
  set +e
  "$JAVA" \
    -ea \
    -Drunelite.mobileui=true \
    -Drunelite.mobileui.smoke=true \
    ${HUBPROBE:+-Drunelite.mobileui.hubprobe=true -Drunelite.hub=true -Drunelite.pluginhub.version=${HUBVER:-1.12.27}} \
    ${PANELPROBE:+-Drunelite.mobileui.panelprobe=true -Drunelite.headless.capture.dir=$PWD/out-mobileui} \
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
    > "$log" 2>&1 &
  local pid=$!
  sleep "$((RUN_SECONDS + 10))"
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  set -e
}

L1="$OUT/launch1.log"
L2="$OUT/launch2.log"
echo "== launch 1/2 -> $L1 =="; run_launch "$L1"
echo "== launch 2/2 (reads launch-1 sentinel back off disk) -> $L2 =="; run_launch "$L2"

./mobileui-verdict.sh "$L1" "$L2"
echo "logs: ios/dev-tools/headless/$L1 , $L2"
