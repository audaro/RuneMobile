#!/usr/bin/env bash
# Gate 1b proper: activate CACIO's CTC toolkit via the JUnit extension and render the overlay scene.
set -euo pipefail
cd "$(dirname "$0")"

JAVA="${JAVA:-/opt/homebrew/opt/openjdk@21/bin/java}"
JAVAC="${JAVAC:-/opt/homebrew/opt/openjdk@21/bin/javac}"
FONTDIR="${FONTDIR:-../../../runelite-client/src/main/resources/net/runelite/client/ui}"
CACIO="lib/cacio-tta-1.18.jar:lib/cacio-shared-1.18.jar:lib/byte-buddy-1.14.11.jar:lib/byte-buddy-agent-1.14.11.jar"
JUNIT="lib/junit-platform-console-standalone-1.10.2.jar"

JVM_ARGS=(
  -Djdk.attach.allowAttachSelf=true
  -Dsmoke.fontDir="$FONTDIR"
  -Dsmoke.out=out/overlay-cacio.png
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

echo "==== compile (test + smoke) ===="
"$JAVAC" -cp "$CACIO:$JUNIT" -d out OverlaySmoke.java OverlaySmokeTest.java

echo
echo "==== Gate 1b: run under CACIO CTC toolkit via JUnit ===="
"$JAVA" "${JVM_ARGS[@]}" -jar "$JUNIT" \
  -cp "out:$CACIO" \
  --select-class=OverlaySmokeTest \
  --details=tree 2>&1

echo
echo "==== compare 1a (plain) vs 1b (cacio) ===="
"$JAVA" -Djava.awt.headless=true -cp out OverlaySmoke compare out/overlay-plain.png out/overlay-cacio.png || true
