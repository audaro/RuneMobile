#!/usr/bin/env bash
# Stand up STOCK RuneLite (our fork's runelite-client) on desktop OpenJDK 21 — the W2 reference
# harness / inner loop. Builds the shaded jar if missing, then launches the full GUI client against
# live OSRS. This is the desktop ground-truth we A/B the headless capture against.
#
# JDK-21 launch flags (match the official RuneLite launcher's macOS args):
#   --add-exports java.desktop/com.apple.eawt=ALL-UNNAMED   (OSXFullScreenAdapter superclass access)
#   --add-opens   java.base/java.lang.reflect=ALL-UNNAMED   (ReflectUtil annotation-cache invalidation)
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
JAR="runelite-client/build/libs/client-1.12.28-SNAPSHOT-shaded.jar"

if [ ! -f "$JAR" ]; then
  echo "== building shaded client on JDK 21 =="
  ./gradlew :client:assemble --console=plain
fi

echo "== launching stock RuneLite on $($JAVA_HOME/bin/java -version 2>&1 | head -1) =="
exec "$JAVA_HOME/bin/java" \
  --add-exports java.desktop/com.apple.eawt=ALL-UNNAMED \
  --add-opens   java.base/java.lang.reflect=ALL-UNNAMED \
  -jar "$JAR" "$@"
