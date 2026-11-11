#!/bin/bash
# Build phase: recursively re-sign every Mach-O inside the embedded jre with the
# app's signing identity (the W1-audit Claim A — the re-sign-avoids-bypass EXPERIMENT).
#
# The bundled jre21 dylibs ship ad-hoc/linker-signed (no Team ID). iOS library
# validation pins embedded code to the app's Team ID, so dyld would reject them
# on dlopen. Re-signing each Mach-O with EXPANDED_CODE_SIGN_IDENTITY is the clean
# route we are testing. If this proves insufficient at runtime (dlopen fails),
# the dyld bypass is mandatory — that is the experiment's negative result.
#
# Runs AFTER "Copy Bundle Resources", BEFORE Xcode's final app-wrapper signing.
set -euo pipefail

JRE_DIR="${CODESIGNING_FOLDER_PATH}/jre"
# Only the EXPANDED form is the resolved cert hash; it is set ONLY when Xcode is
# actually signing. Do not fall back to CODE_SIGN_IDENTITY (that may be the
# unresolved name "iPhone Developer", which codesign cannot use).
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"

if [ ! -d "$JRE_DIR" ]; then
    echo "warning: resign-jre: no embedded jre at $JRE_DIR — skipping"
    exit 0
fi

# The app ships without the JRE's Java Sound library, as the Android one does. Game audio has its own output
# (HeadlessMixerProvider), and libjsound's device listing starts the CoreAudio HAL inside the app. That loads the
# system's Bluetooth audio plug-in, whose service the app sandbox refuses, and on the phones seen it then retries the
# connection thousands of times a second for the whole session, leaking about 60 MB a minute until iOS ends the app.
# Without the library the JDK's own sound providers fail to load and Java Sound skips them.
rm -f "$JRE_DIR/lib/libjsound.dylib"

# Simulator builds: the jre's Mach-O are iOS-device binaries, which the simulator's dyld refuses. The code is the
# same arm64, so retag each one's LC_BUILD_VERSION as iossim and ad-hoc sign it (the rewrite drops the signature).
# Files Xcode did not re-copy since the last build are already retagged and are left alone.
if [ "${PLATFORM_NAME:-}" = "iphonesimulator" ]; then
    count=0
    while IFS= read -r -d '' f; do
        file -b "$f" | grep -q "Mach-O" || continue
        xcrun vtool -show-build "$f" | grep -qE '^ *platform IOS$' || continue
        xcrun vtool -set-build-version iossim 14.0 26.0 -replace -output "$f.iossim" "$f"
        mv "$f.iossim" "$f"
        /usr/bin/codesign --force --sign - --timestamp=none "$f"
        count=$((count + 1))
    done < <(find "$JRE_DIR" -type f \( -name '*.dylib' -o -perm -u+x \) -print0)
    echo "resign-jre: simulator build — retagged $count Mach-O files as iossim (ad-hoc signed)"
    exit 0
fi
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ] || [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
    echo "note: resign-jre: signing disabled / no resolved identity (got '$IDENTITY') — leaving ad-hoc"
    exit 0
fi

echo "resign-jre: signing Mach-O under $JRE_DIR with identity $IDENTITY"
count=0
while IFS= read -r -d '' f; do
    # Only sign actual Mach-O files (dylibs + the bin/ executables).
    if file -b "$f" | grep -q "Mach-O"; then
        /usr/bin/codesign --force --sign "$IDENTITY" --timestamp=none "$f"
        count=$((count + 1))
    fi
done < <(find "$JRE_DIR" -type f \( -name '*.dylib' -o -perm -u+x \) -print0)

echo "resign-jre: re-signed $count Mach-O files"
