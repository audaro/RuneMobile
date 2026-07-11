#!/usr/bin/env bash
#
# Source + stage the Android embedded JRE (the one artifact git doesn't carry and a package
# manager can't provide). Reproduces, in one command, the setup that was painful to rediscover:
#   1. download the verified bionic arm64 OpenJDK 21 (AngelAuraMC / Amethyst lineage)
#   2. structurally verify it's bionic aarch64 (NOT iOS Mach-O, NOT glibc)
#   3. stage the WHOLE tree (incl. every .so) into android/app/src/main/assets/jvm/jre  — assets ONLY
#   4. build the missing headful libawt_xawt.so (the JRE ships none)
#   5. guard against the jniLibs trap (see below)
#
# THE jniLibs TRAP (do not undo): the JRE's .so must live ONLY under assets (→ filesDir at runtime).
# If they are ALSO in jniLibs/arm64-v8a, the linker resolves libawt.so by soname, libawt's JNI_OnLoad
# gets a non-absolute dli_fname, realpath() fails, and the VM aborts "Could not allocate library name"
# in java.awt.Toolkit.<clinit>. The native bootstrap dlopens libjvm.so from filesDir by absolute path,
# which works. jniLibs holds ONLY the CMake-built librunemobile.so. See android/README.md.
#
# After this, run tools/stage-mobile-runtime.sh to stage the shared client/probes jars.
#
# Usage:
#   tools/stage-android-jre.sh                 # download (cached) + verify + stage + build fake-xawt
#   tools/stage-android-jre.sh --force         # re-download even if the cached tarball is present
#   tools/stage-android-jre.sh --no-verify-sha # skip the pinned-SHA check (structural check still runs)
#
# Env: ANDROID_SDK_ROOT (defaults to ~/Library/Android/sdk) — needed for the fake-xawt NDK build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# --- the pinned artifact (GitHub release assets are immutable per tag) -------------------------
# 16 KB PAGE-SIZE: this is a 16 KB-page-aligned bionic arm64 OpenJDK 21 — all 32 jre/lib/*.so link at
# p_align=16384 (incl. libjvm.so + libfreetype.so), so the embedded VM loads on a true 16 KB-page kernel as well
# as 4 KB. No such build exists upstream (the canonical AngelAuraMC / Pojav→Amethyst builder ships 4 KB by
# construction), so we BUILT it: a fork at audaro/angelauramc-openjdk-build, branch buildjre17-21, adds
# `-Wl,-z,max-page-size=16384` to the OpenJDK configure LDFLAGS (6_buildjdk.sh) AND to freetype's configure
# (4_buildlibs.sh — libtool captures LDFLAGS at configure time, not make time). Built via that fork's GitHub
# Actions (the `Build Java 21 for Android aarch64` matrix leg) and published as the release asset below.
#   To rebuild/refresh: edit those two scripts on the fork, run the workflow, then re-pin JRE_URL/SHA/BYTES here.
#   Upstream 4 KB fallback (no 16 KB alignment): AngelAuraMC download_jre21 / jre21-android-arm64.tar.xz
#     sha256 8d41ec401ee59f7722df60ed991f81ad146e130452804bfdd8a05d3436f7bbfe (28675516 bytes).
#   NB: to revert to the 4 KB build you MUST change all THREE pins together (URL + JRE_SHA256 + JRE_BYTES) to the
#   values on the two lines above — they diverge from the 16 KB asset. The SHA check below will refuse a URL/SHA
#   mismatch rather than stage it, so a partial revert fails loudly (by design). 16 KB-VALIDATED: builds on a real
#   16 KB-page kernel (ps16k arm64 emulator, PAGE_SIZE=16384) — JDK .so mmap + GL context OK; the 4 KB fallback
#   is for 4 KB-page devices only and is NOT exercised by CI/this script.
# PROD-RELEASE-ENG-06: the artifact lives on a single GitHub release. The download is SHA-pinned below, so ANY
# byte-identical mirror is safe — set JRE_URL to override the primary, and/or JRE_URL_MIRROR to a fallback host
# the script tries if the primary is unreachable (avoids a single point of failure for a clean build).
JRE_URL="${JRE_URL:-https://github.com/audaro/angelauramc-openjdk-build/releases/download/jre21-android-arm64-16k/jre21-android-arm64.tar.xz}"
JRE_URL_MIRROR="${JRE_URL_MIRROR:-}"
JRE_SHA256="db7862e4ec68a71a46cf1fec078938443410805cb61e8f99b75f10893c708c9a"
# shellcheck disable=SC2034  # documented size pin (see header); kept as one of the three revert pins, not read here
JRE_BYTES=28679076

CACHE="android/dev-tools/.jre-cache"
TARBALL="$CACHE/jre21-android-arm64.tar.xz"
JRE_DEST="android/app/src/main/assets/jvm/jre"
JNI="android/app/src/main/jniLibs/arm64-v8a"
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"

FORCE=0 ; VERIFY_SHA=1
for a in "$@"; do case "$a" in
  --force) FORCE=1 ;;
  --no-verify-sha) VERIFY_SHA=0 ;;
  -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  *) echo "unknown arg: $a (try --help)" >&2; exit 2 ;;
esac; done

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

# --- 1. download (cached) ---------------------------------------------------------------------
mkdir -p "$CACHE"
if [ "$FORCE" = 1 ] || [ ! -f "$TARBALL" ] || { [ "$VERIFY_SHA" = 1 ] && [ "$(sha "$TARBALL" 2>/dev/null)" != "$JRE_SHA256" ]; }; then
  echo "== download bionic jre21 (28 MB) =="
  if ! curl -fL --retry 3 -o "$TARBALL" "$JRE_URL"; then
    [ -n "$JRE_URL_MIRROR" ] || { echo "!! primary host failed and no JRE_URL_MIRROR set: $JRE_URL" >&2; exit 1; }
    echo "   primary host failed — falling back to mirror $JRE_URL_MIRROR" >&2
    curl -fL --retry 3 -o "$TARBALL" "$JRE_URL_MIRROR"
  fi
else
  echo "== using cached $TARBALL =="
fi

if [ "$VERIFY_SHA" = 1 ]; then
  got="$(sha "$TARBALL")"
  if [ "$got" != "$JRE_SHA256" ]; then
    echo "!! SHA mismatch — expected $JRE_SHA256, got $got" >&2
    echo "   (re-run with --force to re-download, or --no-verify-sha if you trust a newer build)" >&2
    exit 1
  fi
  echo "   sha256 OK ($JRE_SHA256)"
fi

# --- 2. extract + structurally verify bionic aarch64 ------------------------------------------
TMP="$CACHE/extract"
rm -rf "$TMP"; mkdir -p "$TMP"
echo "== extract =="
tar xf "$TARBALL" -C "$TMP"
# tree is flat (bin/ conf/ legal/ lib/{*.so, server/, modules}); fall back to a search if a build
# ever nests it under a top dir. (Avoid `find | head` here — SIGPIPE trips pipefail.)
SRC="$TMP"
if [ ! -f "$SRC/lib/server/libjvm.so" ]; then
  hit="$(find "$TMP" -name libjvm.so -path '*/lib/server/*' 2>/dev/null || true)"
  SRC="${hit%/lib/server/libjvm.so}"
fi
[ -n "$SRC" ] && [ -f "$SRC/lib/server/libjvm.so" ] || { echo "!! couldn't find lib/server/libjvm.so in the tarball" >&2; exit 1; }

echo "== verify bionic aarch64 (not iOS Mach-O, not glibc) =="
javadesc="$(file -b "$SRC/bin/java")"
echo "   bin/java: $javadesc"
case "$javadesc" in
  *"ARM aarch64"*"/system/bin/linker64"*) echo "   ✓ ELF aarch64, bionic interpreter" ;;
  *) echo "!! bin/java is not a bionic aarch64 ELF — wrong artifact" >&2; exit 1 ;;
esac
# bionic uses unversioned sonames; glibc would NEED libc.so.6 / libpthread.so.0
NDK="$(ls -d "$SDK"/ndk/* 2>/dev/null | sort | head -1)"
READELF="$(ls -d "$NDK"/toolchains/llvm/prebuilt/*/bin/llvm-readelf 2>/dev/null | head -1)"
if [ -n "$READELF" ] && [ -x "$READELF" ]; then
  if "$READELF" -d "$SRC/lib/server/libjvm.so" | grep -qE "libc\.so\.6|libpthread\.so\.0"; then
    echo "!! libjvm NEEDs glibc sonames (libc.so.6/libpthread.so.0) — this is a glibc build, not bionic" >&2
    exit 1
  fi
  echo "   ✓ libjvm NEEDs only bionic sonames"
else
  echo "   (no NDK readelf found under $SDK/ndk — skipped the glibc soname check)"
fi

# --- 3. stage the WHOLE JRE into assets ONLY --------------------------------------------------
echo "== stage -> $JRE_DEST (assets only) =="
rm -rf "$JRE_DEST"; mkdir -p "$JRE_DEST"
cp -R "$SRC"/. "$JRE_DEST"/
rm -rf "$TMP"
echo "   modules: $(ls -la "$JRE_DEST/lib/modules" | awk '{print $5}') bytes; server/libjvm.so present: $([ -f "$JRE_DEST/lib/server/libjvm.so" ] && echo yes)"

# --- 4. build the missing headful libawt_xawt.so ----------------------------------------------
echo "== build fake libawt_xawt.so (NDK) =="
( cd android/dev-tools/fake-xawt && ANDROID_SDK_ROOT="$SDK" ./build-libawt_xawt.sh >/dev/null )
[ -f "$JRE_DEST/lib/libawt_xawt.so" ] && echo "   ✓ libawt_xawt.so installed into jre/lib" || { echo "!! libawt_xawt.so not built" >&2; exit 1; }

# --- 5. guard the jniLibs trap ----------------------------------------------------------------
# jniLibs/arm64-v8a must hold ONLY the CMake-built librunemobile.so (Gradle puts it there). Any JRE
# .so staged here re-triggers the libawt realpath abort — remove them.
if [ -d "$JNI" ]; then
  stray=""
  for so in "$JNI"/*.so; do
    [ -e "$so" ] || continue                       # glob stayed literal -> no .so present
    [ "$(basename "$so")" = librunemobile.so ] && continue
    stray+="$so"$'\n'
  done
  stray="${stray%$'\n'}"                            # trim the trailing newline
  if [ -n "$stray" ]; then
    echo "== removing stray JRE .so from jniLibs (the trap) =="
    echo "$stray" | sed 's/^/   rm /'
    echo "$stray" | xargs rm -f
  fi
fi

echo
echo "== Android JRE staged. Next: tools/stage-mobile-runtime.sh  (stages the client/probes jars),"
echo "   then build/run: android/gradlew :app:assembleDebug"
