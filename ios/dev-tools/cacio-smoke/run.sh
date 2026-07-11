#!/usr/bin/env bash
# Desktop CACIO overlay smoke — Gate 1a (plain headless) + Gate 1b (CACIO CTC) + compare.
set -euo pipefail
cd "$(dirname "$0")"

JAVA="${JAVA:-/opt/homebrew/opt/openjdk@21/bin/java}"
JAVAC="${JAVAC:-/opt/homebrew/opt/openjdk@21/bin/javac}"
FONTDIR="${FONTDIR:-../../../runelite-client/src/main/resources/net/runelite/client/ui}"
CP="lib/cacio-tta-1.18.jar:lib/cacio-shared-1.18.jar:lib/byte-buddy-1.14.11.jar:lib/byte-buddy-agent-1.14.11.jar"

CACIO_ARGS=(
  -Djava.awt.headless=false
  -Dawt.toolkit=com.github.caciocavallosilano.cacio.ctc.CTCToolkit
  -Djava.awt.graphicsenv=com.github.caciocavallosilano.cacio.ctc.CTCGraphicsEnvironment
  -Djdk.attach.allowAttachSelf=true
  --add-exports=java.desktop/java.awt=ALL-UNNAMED
  --add-exports=java.desktop/java.awt.peer=ALL-UNNAMED
  --add-exports=java.desktop/sun.awt.image=ALL-UNNAMED
  --add-exports=java.desktop/sun.java2d=ALL-UNNAMED
  --add-exports=java.desktop/java.awt.dnd.peer=ALL-UNNAMED
  --add-exports=java.desktop/sun.awt=ALL-UNNAMED
  --add-exports=java.desktop/sun.awt.event=ALL-UNNAMED
  --add-exports=java.desktop/sun.awt.datatransfer=ALL-UNNAMED
  --add-exports=java.base/sun.security.action=ALL-UNNAMED
  --add-opens=java.base/java.util=ALL-UNNAMED
  --add-opens=java.desktop/java.awt=ALL-UNNAMED
  --add-opens=java.desktop/sun.java2d=ALL-UNNAMED
  --add-opens=java.base/java.lang.reflect=ALL-UNNAMED
)

echo "==== compile ===="
"$JAVAC" -d out OverlaySmoke.java

echo
echo "==== Gate 1a: plain headless OpenJDK 21 (reference) ===="
"$JAVA" -Djava.awt.headless=true -cp out OverlaySmoke render "$FONTDIR" out/overlay-plain.png

echo
echo "==== Gate 1b: CACIO CTC toolkit (headless=false) ===="
"$JAVA" "${CACIO_ARGS[@]}" -cp "out:$CP" OverlaySmoke render "$FONTDIR" out/overlay-cacio.png

echo
echo "==== compare 1a vs 1b ===="
"$JAVA" -Djava.awt.headless=true -cp out OverlaySmoke compare out/overlay-plain.png out/overlay-cacio.png
