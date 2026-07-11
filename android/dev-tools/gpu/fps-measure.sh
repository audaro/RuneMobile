#!/usr/bin/env bash
# FIX-13 / Phase-0 fps + frame-time measurement harness.
#
# Reads two once/sec engine probes that Hooks.frame emits in 117HD test mode
# (enabled by -Drunelite.fpsprobe=true):
#   [fpsprobe]   fps=N gs=STATE                              -- smoothed engine fps
#   [frameprobe] n=N min=.. avg=.. p95=.. max=.. gs=STATE    -- per-frame interval (ms), windowed/sec
# captures a window, and prints fps mean/median/min/max AND frame-time
# min/avg/p95/max (ms) + device thermal. Use it to A/B a 117HD preset in-world
# on real Mali: hold a fixed spot + camera, capture a "baseline" window, change
# the preset (redeploy or flip the config live via SET_HD_CONFIG), capture a
# second window, compare. Frame-time percentiles (not one smoothed fps) are what
# let a 2-3 fps tuning delta be told apart from noise.
#
# The probes only log while gs=LOGGED_IN frames are flowing, so capture while the
# scene is actually rendering. fps here is the engine's own render rate
# (Client.getFPS); frame-time is the wall-clock interval between frame() calls.
#
# Usage:
#   fps-measure.sh [-s SERIAL] [-d SECONDS] [-o OUT.csv] [LABEL]   # live capture over adb
#   fps-measure.sh --from-file LOGCAT.txt [-o OUT.csv] [LABEL]     # parse an existing dump
#   cat logcat.txt | fps-measure.sh --stdin [LABEL]               # parse from a pipe
#
# Notes:
#   - macOS has no `timeout`; live capture backgrounds `adb logcat` and kills it after -d seconds.
#   - Only LOGGED_IN samples are counted toward the stats (login-screen frames are excluded).
#   - Thermal is sampled (dumpsys thermalservice) at the start and end of the adb window only.
set -euo pipefail

SERIAL=""
DUR=20
OUT=""
LABEL="run"
SRC="adb"
FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) SERIAL="$2"; shift 2 ;;
    -d) DUR="$2"; shift 2 ;;
    -o) OUT="$2"; shift 2 ;;
    --from-file) SRC="file"; FILE="$2"; shift 2 ;;
    --stdin) SRC="stdin"; shift ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) LABEL="$1"; shift ;;
  esac
done

ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
[[ -x "$ADB" ]] || ADB="adb"
adb_args=(); [[ -n "$SERIAL" ]] && adb_args=(-s "$SERIAL")

# Hottest temperature (deg C) across all thermal sensors + the device's throttling status. Unprivileged
# (dumpsys thermalservice), so it works without root; prints "n/a" if the service is unavailable.
sample_thermal() {
  local when="$1"
  local dump
  dump="$("$ADB" "${adb_args[@]}" shell dumpsys thermalservice 2>/dev/null || true)"
  local hot status
  hot="$(printf '%s\n' "$dump" | grep -oE 'mValue=[-0-9.]+' | sed -E 's/mValue=//' \
        | awk 'BEGIN{m=-1000} {if($1>m)m=$1} END{if(m>-1000)printf "%.1f",m; else print "n/a"}')"
  status="$(printf '%s\n' "$dump" | grep -oE 'Thermal Status: [0-9]+' | sed -E 's/Thermal Status: //' | head -1)"
  [[ -z "$status" ]] && status="$(printf '%s\n' "$dump" | grep -oE 'mStatus=[0-9]+' | sed -E 's/mStatus=//' | head -1)"
  echo ">> thermal[$when]: hottest=${hot:-n/a}C status=${status:-n/a}" >&2
}

raw=""
case "$SRC" in
  stdin)
    raw="$(cat)"
    ;;
  file)
    [[ -f "$FILE" ]] || { echo "no such file: $FILE" >&2; exit 1; }
    raw="$(cat "$FILE")"
    ;;
  adb)
    echo ">> capturing ${DUR}s of fps/frame probe (label=$LABEL)${SERIAL:+ from $SERIAL} ..." >&2
    sample_thermal start
    "$ADB" "${adb_args[@]}" logcat -c 2>/dev/null || true
    tmp="$(mktemp)"
    "$ADB" "${adb_args[@]}" logcat -v time > "$tmp" 2>/dev/null &
    logpid=$!
    sleep "$DUR"
    kill "$logpid" 2>/dev/null || true
    wait "$logpid" 2>/dev/null || true
    raw="$(cat "$tmp")"
    rm -f "$tmp"
    sample_thermal end
    ;;
esac

# Pull "[fpsprobe] fps=N gs=STATE" lines; keep only LOGGED_IN samples for the fps stats.
samples="$(printf '%s\n' "$raw" \
  | grep -oE '\[fpsprobe\] fps=[0-9]+ gs=[A-Z_]+' \
  | sed -E 's/\[fpsprobe\] fps=([0-9]+) gs=([A-Z_]+)/\1 \2/' || true)"

# Pull "[frameprobe] n=.. min=.. avg=.. p95=.. max=.. gs=STATE" windows (one per second).
frames="$(printf '%s\n' "$raw" \
  | grep -oE '\[frameprobe\] n=[0-9]+ min=[0-9.]+ avg=[0-9.]+ p95=[0-9.]+ max=[0-9.]+ gs=[A-Z_]+' \
  | sed -E 's/\[frameprobe\] n=([0-9]+) min=([0-9.]+) avg=([0-9.]+) p95=([0-9.]+) max=([0-9.]+) gs=([A-Z_]+)/\1 \2 \3 \4 \5 \6/' || true)"

# Pull "[gpuprobe] frames=.. avg=.. min=.. max=.. ms" windows (per second; only present when debug.routec.gputime=1).
gpu="$(printf '%s\n' "$raw" \
  | grep -oE '\[gpuprobe\] frames=[0-9]+ avg=[0-9.]+ min=[0-9.]+ max=[0-9.]+ ms' \
  | sed -E 's/\[gpuprobe\] frames=([0-9]+) avg=([0-9.]+) min=([0-9.]+) max=([0-9.]+) ms/\1 \2 \3 \4/' || true)"

if [[ -z "$samples" && -z "$frames" && -z "$gpu" ]]; then
  echo "no [fpsprobe]/[frameprobe]/[gpuprobe] samples found. Is fpsprobe on (-Drunelite.fpsprobe / 117HD test mode) and the scene rendering?" >&2
  exit 2
fi

# CSV (all three probe families, tagged by `kind`).
if [[ -n "$OUT" ]]; then
  {
    echo "label,kind,idx,a,b,c,d,e,gs"
    i=0; while read -r fps gs; do [[ -z "$fps" ]] && continue; echo "$LABEL,fps,$i,$fps,,,,,$gs"; i=$((i+1)); done <<< "$samples"
    i=0; while read -r n mn av p95 mx gs; do [[ -z "$n" ]] && continue; echo "$LABEL,frame,$i,$n,$mn,$av,$p95,$mx,$gs"; i=$((i+1)); done <<< "$frames"
    i=0; while read -r n av mn mx; do [[ -z "$n" ]] && continue; echo "$LABEL,gpu,$i,$n,$mn,$av,,$mx,"; i=$((i+1)); done <<< "$gpu"
  } > "$OUT"
  echo ">> wrote $(($(wc -l < "$OUT" | tr -d ' ') - 1)) rows to $OUT" >&2
fi

# fps stats over LOGGED_IN samples only.
if [[ -n "$samples" ]]; then
  printf '%s\n' "$samples" | awk -v label="$LABEL" '
    $2=="LOGGED_IN" { v[n++]=$1; sum+=$1 }
    END {
      if (n==0) { print "fps:   no LOGGED_IN samples (only login-screen frames captured)"; exit }
      for (i=0;i<n;i++) for (j=i+1;j<n;j++) if (v[j]<v[i]) { t=v[i]; v[i]=v[j]; v[j]=t }
      med = (n%2) ? v[int(n/2)] : (v[n/2-1]+v[n/2])/2
      printf "%-10s  fps    n=%-3d  mean=%.1f  median=%.1f  min=%d  max=%d\n", label, n, sum/n, med, v[0], v[n-1]
    }'
fi

# frame-time stats over LOGGED_IN windows: frame-weighted avg, min-of-min, max-of-max, mean per-sec p95 (p95~).
if [[ -n "$frames" ]]; then
  printf '%s\n' "$frames" | awk -v label="$LABEL" '
    $6=="LOGGED_IN" {
      w++; frames+=$1; wavg+=$1*$3; p95sum+=$4;
      if (mn==0 || $2<mn) mn=$2;
      if ($5>mx) mx=$5;
    }
    END {
      if (w==0) { print "frame: no LOGGED_IN windows captured"; exit }
      printf "%-10s  frame  windows=%-3d frames=%-4d  min=%.2f  avg=%.2f  p95~=%.2f  max=%.2f  (ms)\n", \
        label, w, frames, mn, wavg/frames, p95sum/w, mx
    }'
fi

# GPU-time stats (frame-weighted avg, min-of-min, max-of-max). Only present when debug.routec.gputime=1.
if [[ -n "$gpu" ]]; then
  printf '%s\n' "$gpu" | awk -v label="$LABEL" '
    { w++; frames+=$1; wavg+=$1*$2; if (mn==0 || $3<mn) mn=$3; if ($4>mx) mx=$4; }
    END {
      if (w==0) exit
      printf "%-10s  gpu    windows=%-3d frames=%-4d  min=%.2f  avg=%.2f  max=%.2f  (ms GPU)\n", \
        label, w, frames, mn, wavg/frames, mx
    }'
fi
