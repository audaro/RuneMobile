#!/bin/bash
# Patch the bundled jre21 libjvm so HotSpot uses the debugger brk #0x69 code-cache
# path on our (sandboxed) iOS app.
#
# Why: libjvm's get_debug_jit_mapping() only calls BreakGetJITMapping (brk #0x69)
# when  MirrorMappedCodeCache(global)==1 && DeviceRequiresTXMWorkaround().
#   - DeviceRequiresTXMWorkaround() detects TXM by reading
#     /private/preboot/.../Ap,TrustedExecutionMonitor.img4 — the app sandbox can't
#     open it -> returns 0.
#   - The MirrorMappedCodeCache C-global also reads 0 here, so the function returns
#     NULL and the caller falls back to plain mmap(PROT_READ|PROT_EXEC) — which is
#     NOT executable on a TXM device -> instruction-abort on generated code.
# We confirmed on-device: with only the TXM gate NOPed, brk #0x69 still never fired;
# the flag gate diverts first. prepare_memory_region only works on debugger-allocated
# (_M) regions, so map-on-fault on HotSpot's own mmap pages can't make them RX.
#
# Fix: NOP BOTH gate branches in get_debug_jit_mapping so it ALWAYS calls
# BreakGetJITMapping. HotSpot's -XX:+MirrorMappedCodeCache write path then mirrors
# that debugger RX region RW for writing; the attached StikDebug script
# (runelite-jit.js) services the brk #0x69 with a real _M RX region.
#   0x81fc80: b.ne <fallback>   (MirrorMappedCodeCache flag gate)      -> nop
#   0x81fc8c: cbz w0,<mmap>      (DeviceRequiresTXMWorkaround gate)     -> nop
#
# Idempotent + verified. Run after fetching/extracting the JRE (JRE21-INVENTORY.md).
# The app's resign-jre.sh re-signs the patched dylib at build time.
set -euo pipefail

LIBJVM="${1:-$(dirname "$0")/jre/lib/server/libjvm.dylib}"
NOP="1f2003d5"   # nop

# site:expected_original (little-endian hex as stored in the file)
SITES=( "$((0x81fc80)):61080054" "$((0x81fc8c)):e0010034" )

if [ ! -f "$LIBJVM" ]; then echo "patch-jre-txm: not found: $LIBJVM" >&2; exit 1; fi

for entry in "${SITES[@]}"; do
    off="${entry%%:*}"; orig="${entry##*:}"
    cur=$(xxd -s "$off" -l 4 -p "$LIBJVM")
    if [ "$cur" = "$NOP" ]; then
        echo "patch-jre-txm: 0x$(printf %x "$off") already nop — skipping"
        continue
    fi
    if [ "$cur" != "$orig" ]; then
        echo "patch-jre-txm: UNEXPECTED bytes at 0x$(printf %x "$off"): $cur (expected $orig)." >&2
        echo "  JRE build may differ from the pinned one — re-derive offsets before patching." >&2
        exit 1
    fi
    printf '\x1f\x20\x03\xd5' | dd of="$LIBJVM" bs=1 seek="$off" count=4 conv=notrunc status=none
    echo "patch-jre-txm: NOPed 0x$(printf %x "$off") (was $orig) -> $(xxd -s "$off" -l 4 -p "$LIBJVM")"
done
echo "patch-jre-txm: done. get_debug_jit_mapping now always calls BreakGetJITMapping (brk #0x69)."
