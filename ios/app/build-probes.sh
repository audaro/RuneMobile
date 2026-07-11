#!/usr/bin/env bash
# Build jvm-resources/probes.jar (the resource project.yml bundles into the app).
# Compiled `--release 8` so the device JDK 21 loads them (same as the desktop A/B).
#
# Contents:
#   - Phase-1 probes (jvmbench): JitProbe, Bench, GlyphSmoke
#   - W1 P3 §6.0 activation confirm (awtsmoke): AwtActivation + UnsafePokeActivation
#   - the CACIO cacio17 classes (cacio-tta + cacio-shared 1.18) FOLDED IN, so the device
#     classpath stays just probes.jar (JVMLauncher sets -Djava.class.path to it alone).
#     Cacio is GPLv2 WITH THE CLASSPATH EXCEPTION and these classes DO ship inside app binaries —
#     see THIRD-PARTY-NOTICES.md §G for the notice that covers the combination.
#
# Usage: ./build-probes.sh                 (run from ios/app/)
#        ./build-probes.sh --no-verify-sha  (skip the pinned-SHA check on the folded CACIO jars)
set -euo pipefail
cd "$(dirname "$0")"

VERIFY_SHA=1
for a in "$@"; do
  case "$a" in
    --no-verify-sha) VERIFY_SHA=0 ;;
    *) echo "build-probes: unknown arg '$a' (only --no-verify-sha)" >&2; exit 64 ;;
  esac
done

JAVAC="${JAVAC:-/opt/homebrew/opt/openjdk@21/bin/javac}"
JAR="${JAR:-/opt/homebrew/opt/openjdk@21/bin/jar}"
JFLAGS="--release 8"
JVMBENCH=../dev-tools/jvmbench
AWTSMOKE=../dev-tools/awtsmoke
CACIO_LIB=../dev-tools/cacio-smoke/lib
CACIO_CP="$CACIO_LIB/cacio-tta-1.18.jar:$CACIO_LIB/cacio-shared-1.18.jar"
OUT=build/probes-classes
JARFILE=jvm-resources/probes.jar

# SUPPLY-1: the two CACIO jars are folded verbatim into probes.jar and ship inside the app binary. They are
# gitignored (staged from local state), so a pinned SHA-256 is their only integrity gate — refuse to fold a
# jar that doesn't match rather than silently ship a tampered/wrong-version one. Re-pin here if you
# deliberately bump the cacio version; --no-verify-sha skips the check. (byte-buddy in the same lib dir is
# compile/test-only and is NOT folded, so it isn't pinned here.)
CACIO_TTA_SHA256="2dc226227d86af25d2ae9dbd87aa4e210c86d734c1d7775f80359b6474805228"
CACIO_SHARED_SHA256="6f3a26dfaba0d0287d97922ef316b751db06d93f183e8fa274ddec53b74bd845"

verify_sha() {   # <file> <expected-sha256>
  local f="$1" want="$2" got
  [ -f "$f" ] || { echo "build-probes: missing $f" >&2; exit 1; }
  if command -v shasum >/dev/null 2>&1; then
    got="$(shasum -a 256 "$f" | awk '{print $1}')"
  else
    got="$(sha256sum "$f" | awk '{print $1}')"
  fi
  if [ "$got" != "$want" ]; then
    echo "build-probes: SHA-256 mismatch for $f" >&2
    echo "    expected $want" >&2
    echo "    got      $got" >&2
    echo "    A wrong/tampered jar would ship inside probes.jar — refusing. Re-pin the SHA above if you" >&2
    echo "    deliberately bumped cacio, or pass --no-verify-sha to skip." >&2
    exit 1
  fi
}

# Fetched from Maven Central when absent (fresh checkout / CI workspace); the SHA gate below still decides
# whether the bytes are trusted, so a failed or tampered download can never fold into probes.jar.
CACIO_MAVEN="https://repo1.maven.org/maven2/com/github/caciocavallosilano"
fetch_if_missing() {   # <file>
  local f="$1" name artifact tmp
  [ -f "$f" ] && return 0
  name="$(basename "$f")"; artifact="${name%-1.18.jar}"
  echo "== fetch $name from Maven Central =="
  mkdir -p "$(dirname "$f")"
  # Download to a temp sibling and atomically rename on success: an interrupted/killed curl can never leave a
  # partial file at the real path (which the [ -f ] guard above would then skip forever, failing the SHA gate
  # on every subsequent run until hand-deleted). The trailing SHA check is still the trust decision.
  tmp="$(mktemp "$(dirname "$f")/.$name.XXXXXX")"
  if curl -sfL -o "$tmp" "$CACIO_MAVEN/$artifact/1.18/$name"; then
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp"
    echo "build-probes: failed to fetch $name from Maven Central" >&2; exit 1
  fi
}

rm -rf "$OUT"; mkdir -p "$OUT" "$(dirname "$JARFILE")"
here="$(pwd)"

fetch_if_missing "$CACIO_LIB/cacio-tta-1.18.jar"
fetch_if_missing "$CACIO_LIB/cacio-shared-1.18.jar"

if [ "$VERIFY_SHA" = 1 ]; then
  echo "== verify CACIO jar checksums (SUPPLY-1) =="
  verify_sha "$CACIO_LIB/cacio-tta-1.18.jar"    "$CACIO_TTA_SHA256"
  verify_sha "$CACIO_LIB/cacio-shared-1.18.jar" "$CACIO_SHARED_SHA256"
fi

echo "== fold in CACIO classes =="
( cd "$OUT" && unzip -oq "$here/$CACIO_LIB/cacio-tta-1.18.jar"    -x 'META-INF/*' \
            && unzip -oq "$here/$CACIO_LIB/cacio-shared-1.18.jar" -x 'META-INF/*' )

echo "== compile Phase-1 probes (javac $JFLAGS) =="
"$JAVAC" $JFLAGS -d "$OUT" \
  "$JVMBENCH/JitProbe.java" "$JVMBENCH/Bench.java" "$JVMBENCH/GlyphSmoke.java"

echo "== compile §6.0 activation + §6.1 smoke probes (javac $JFLAGS, cacio on cp) =="
"$JAVAC" $JFLAGS -cp "$CACIO_CP" -d "$OUT" \
  "$AWTSMOKE/AwtActivation.java" "$AWTSMOKE/UnsafePokeActivation.java" "$AWTSMOKE/AwtSmoke.java"

# §6.2: DeviceHeadlessBoot references net.runelite.client.headless.RuneLiteHeadless (in the shaded
# client jar), so it only compiles when the shaded jar is present. Folded into probes.jar; the device
# classpath is shaded.jar:probes.jar, so RuneLiteHeadless resolves from shaded at runtime.
SHADED="${SHADED:-$(ls ../../runelite-client/build/libs/client-*-shaded.jar 2>/dev/null | tail -1 || true)}"
if [ -f "$SHADED" ]; then
  echo "== compile §6.2 DeviceHeadlessBoot + GateCensus (javac $JFLAGS, prior classes+cacio+shaded on cp) =="
  "$JAVAC" $JFLAGS -cp "$OUT:$CACIO_CP:$SHADED" -d "$OUT" "$AWTSMOKE/DeviceHeadlessBoot.java" "$AWTSMOKE/GateCensus.java"
elif [ "${ALLOW_NO_SHADED:-0}" = "1" ]; then
  echo "== SKIP §6.2 DeviceHeadlessBoot (ALLOW_NO_SHADED=1; probes.jar will NOT boot the client) =="
else
  # Without the shaded jar this would silently produce a probes.jar MISSING the boot entry point
  # (DeviceHeadlessBoot) — the app then dies at launch with a confusing NoClassDefFoundError. Build the
  # shaded jar first; ALLOW_NO_SHADED=1 restores the old skip for probe-only builds.
  echo "ERROR: shaded client jar not found (looked at: ${SHADED:-<none>})." >&2
  echo "       Run ./gradlew :client:shadowJar at the repo root first, or set ALLOW_NO_SHADED=1." >&2
  exit 1
fi

echo "== pack $JARFILE =="
"$JAR" cf "$JARFILE" -C "$OUT" .

echo "== done =="
ls -la "$JARFILE"
echo "key classes:"; "$JAR" tf "$JARFILE" | grep -E 'UnsafePokeActivation|AwtActivation\.class|ctc/CTCToolkit\.class|ctc/CTCGraphicsEnvironment\.class' || true
