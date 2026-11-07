#!/usr/bin/env bash
# FIX-13 / Phase-0 fps + frame-time measurement harness.
#
# Reads the once/sec engine probes Hooks.frame emits while the perf probe is armed
# (-Drunelite.fpsprobe=true: an Android debug build, or the perfprobe marker on either port, tools/perfprobe.sh):
#   [fpsprobe]   fps=N gs=STATE                              -- smoothed engine fps
#   [frameprobe] n=N min=.. avg=.. p95=.. max=.. gs=STATE    -- per-frame interval (ms), windowed/sec
#   [framebins]  dt=I:C,.. jit=I:C,.. max=.. jitMax=.. gcN=N gcMs=N heapMB=U/C gs=STATE
#   [framehist]  n=N p50=.. p95=.. p99=.. p999=.. ... scope=LOGGED_IN   -- every 10 s, since the first frame
# (headless.FrameStats), the native present probe (same switch; the GPU/117HD direct present on both ports,
# Android's CPU blit, where swap = the whole blit: frame copy, window lock, swizzle and post, and the iOS PiP frame
# feed of the CPU and base-GPU renderers, where swap = fetch, copy and enqueue and feed= names its thread):
#   [presentprobe] presents=N gapMaxMs=.. swapAvgMs=.. swapMaxMs=.. [feed=thread|main]
# the JVM's own -Xlog:gc,safepoint lines (same switch), the native GPU-time probe (librlawt, only with
# debug.routec.gputime=1):
#   [gpuprobe]   frames=N avg=.. min=.. max=.. ms disjoint=N hitch=N
# ThermalGovernor's 117HD load changes (MainActivity tag):
#   thermal status=S -> sceneResolutionScale PREV->NEW (baseline=B)
# and, from a pulled iOS log, memwatch (jetsam headroom, footprint, Java heap, thermal; every 5 s after the first 30 s)
# plus the cold-start stamps of either port:
#   [memwatch t=T.Ts] avail=..MB footprint=..MB heapMB=U/C thermal=STATE
#   [coldstart] MILESTONE sinceStartMs=N        (iOS)   onboard: splash dismissed (... sinceStartMs=N)   (Android)
# captures a window, and prints fps mean/median/min/max AND frame-time
# min/avg/p95/max (ms) + device thermal. Use it to A/B a 117HD preset in-world
# on real Mali: hold a fixed spot + camera, capture a "baseline" window, change
# the preset (redeploy or flip the config live via SET_HD_CONFIG), capture a
# second window, compare. Frame-time percentiles (not one smoothed fps) are what
# let a 2-3 fps tuning delta be told apart from noise.
#
# The probes log once a second in every game state while frames are flowing, so
# capture while the scene is actually rendering. fps here is the engine's own
# render rate (Client.getFPS); frame-time is the wall-clock interval between
# frame() calls.
#
# Usage:
#   fps-measure.sh [-s SERIAL] [-d SECONDS] [-t SECONDS] [-o OUT.csv] [LABEL]   # live capture over adb
#   fps-measure.sh --from-file LOGCAT.txt [-o OUT.csv] [LABEL]                  # parse an existing dump
#   cat logcat.txt | fps-measure.sh --stdin [LABEL]                            # parse from a pipe
#
# Notes:
#   - macOS has no `timeout`; live capture backgrounds `adb logcat` and kills it after -d seconds.
#   - Only LOGGED_IN samples are counted toward the stats (login-screen frames are excluded). [gpuprobe],
#     [presentprobe], -Xlog and the governor carry no game state, so each takes the gs of the last Hooks probe
#     line before it; a window logged before the first Hooks line is untagged and excluded.
#   - `pacing` percentiles come from summing the [framebins] buckets of every LOGGED_IN second in the capture:
#     bucket i is [0.1 ms * 10^(i/20), 0.1 ms * 10^((i+1)/20)), and a percentile reads its bucket's upper edge
#     capped at the exact max (FrameStats.java). Unlike the frame line's p95~ it is a real capture percentile.
#     `session` is the last [framehist] seen: since the client's first frame, not this capture.
#   - The device log can be a pulled iOS jvm-stdio.log (ios_pull_logs): the Java and -Xlog lines are the same.
#   - gpu disjoint = frames whose timer-query drain saw GL_GPU_DISJOINT (Mali DVFS raises it under load): the
#     absolute GPU ms then carry a caveat, a relative A/B still holds. hitch = kept results over 100 ms.
#   - Thermal (dumpsys thermalservice) is sampled at the start and end of the adb window, and every -t seconds
#     in between (default 1, 0 = off) as `thermal` CSV rows. File/stdin input has no thermal rows.
#   - A governor scale change mid-capture means the windows before and after it are different workloads; the
#     summary flags it with `!!`.
#   - CSV columns are positional per kind (label,kind,idx,a,b,c,d,e,gs,f,g):
#       fps       a=fps                                       gs
#       frame     a=n b=min c=avg d=p95 e=max (ms)            gs
#       gpu       a=frames b=min c=avg e=max (ms GPU)         gs  f=disjoint g=hitch
#       gpuempty  (a window with no usable GPU-time)          gs
#       thermal   a=elapsed s b=hottest C c=status
#       govern    a=status b=prev scale c=new scale d=baseline e=log time   gs
#       framebins a=gcN b=gcMs c=heap used MB d=max e=jitMax       gs  f=dt bins g=jit bins (I:C;I:C)
#       present   a=presents b=gapMaxMs c=swapAvgMs e=swapMaxMs     gs
#       gcpause   a=pause ms (-Xlog GC Pause)                      gs
#       safepoint a=total ns (-Xlog Safepoint)                     gs
#       mem       a=t s b=avail MB c=footprint MB d=heap used MB e=heap committed MB   gs  f=thermal
#       coldstart a=ms since process start                         f=milestone
set -euo pipefail

SERIAL=""
DUR=20
THERMAL_EVERY=1
OUT=""
LABEL="run"
SRC="adb"
FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) SERIAL="$2"; shift 2 ;;
    -d) DUR="$2"; shift 2 ;;
    -t) THERMAL_EVERY="$2"; shift 2 ;;
    -o) OUT="$2"; shift 2 ;;
    --from-file) SRC="file"; FILE="$2"; shift 2 ;;
    --stdin) SRC="stdin"; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) LABEL="$1"; shift ;;
  esac
done

ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
[[ -x "$ADB" ]] || ADB="adb"
# Every adb call spells the serial as ${SERIAL:+-s "$SERIAL"}: macOS /bin/bash 3.2 calls an empty "${arr[@]}"
# unbound under set -u, and a wrapper function would make the backgrounded logcat's $! the function's subshell,
# so the kill below would leave adb running.

# Hottest temperature (deg C) across all thermal sensors + the device's throttling status, as "HOT STATUS".
# Unprivileged (dumpsys thermalservice), so it works without root; either is "n/a" if the service doesn't say.
# Every pipeline ends in `|| true`: a grep that finds nothing must not end the capture under pipefail.
read_thermal() {
  local dump hot status
  dump="$("$ADB" ${SERIAL:+-s "$SERIAL"} shell dumpsys thermalservice 2>/dev/null || true)"
  hot="$(printf '%s\n' "$dump" | grep -oE 'mValue=[-0-9.]+' | sed -E 's/mValue=//' \
        | awk 'BEGIN{m=-1000} {if($1>m)m=$1} END{if(m>-1000)printf "%.1f",m; else print "n/a"}' || true)"
  status="$(printf '%s\n' "$dump" | grep -oE 'Thermal Status: [0-9]+' | sed -E 's/Thermal Status: //' | head -1 || true)"
  [[ -z "$status" ]] && status="$(printf '%s\n' "$dump" | grep -oE 'mStatus=[0-9]+' | sed -E 's/mStatus=//' | head -1 || true)"
  echo "${hot:-n/a} ${status:-n/a}"
}

sample_thermal() {
  local r
  r="$(read_thermal)"
  echo ">> thermal[$1]: hottest=${r% *}C status=${r#* }" >&2
}

# "ELAPSED_S HOT STATUS" every THERMAL_EVERY seconds until killed.
thermal_loop() {
  local t0
  t0="$(date +%s)"
  while :; do
    echo "$(( $(date +%s) - t0 )) $(read_thermal)"
    sleep "$THERMAL_EVERY"
  done
}

raw=""
thermal_rows=""
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
    "$ADB" ${SERIAL:+-s "$SERIAL"} logcat -c 2>/dev/null || true
    tmp="$(mktemp)"
    ttmp="$(mktemp)"
    "$ADB" ${SERIAL:+-s "$SERIAL"} logcat -v time > "$tmp" 2>/dev/null &
    logpid=$!
    thermpid=""
    if [[ "$THERMAL_EVERY" != 0 ]]; then
      thermal_loop > "$ttmp" 2>/dev/null &
      thermpid=$!
    fi
    sleep "$DUR"
    kill "$logpid" ${thermpid:+"$thermpid"} 2>/dev/null || true
    wait "$logpid" 2>/dev/null || true
    [[ -n "$thermpid" ]] && { wait "$thermpid" 2>/dev/null || true; }
    raw="$(cat "$tmp")"
    thermal_rows="$(cat "$ttmp")"
    rm -f "$tmp" "$ttmp"
    sample_thermal end
    ;;
esac

# One ordered pass turns every probe line into a "kind fields..." record. Empty fields are "-" so the
# whitespace-split readers below keep their columns. gs is the last Hooks probe's state: both Hooks probes log
# once a second in every state, so a [gpuprobe] or governor line's tag is at most about a second old.
records="$(printf '%s\n' "$raw" | awk '
  function kv(s, k,   i, r) { i = index(s, " " k "="); if (!i) return "-"; r = substr(s, i + length(k) + 2); sub(/ .*/, "", r); return r }
  function tag() { return gs == "" ? "-" : gs }
  { tod = ($1 ~ /^[0-9][0-9]-[0-9][0-9]$/ && $2 ~ /^[0-9][0-9]:[0-9][0-9]:/) ? $2 : "-" }
  match($0, /\[fpsprobe\] fps=[0-9]+ gs=[A-Z_]+/) {
    s = substr($0, RSTART, RLENGTH); gs = kv(s, "gs")
    print "fps", kv(s, "fps"), gs; next
  }
  match($0, /\[frameprobe\] n=[0-9]+ min=[0-9.]+ avg=[0-9.]+ p95=[0-9.]+ max=[0-9.]+ gs=[A-Z_]+/) {
    s = substr($0, RSTART, RLENGTH); gs = kv(s, "gs")
    print "frame", kv(s, "n"), kv(s, "min"), kv(s, "avg"), kv(s, "p95"), kv(s, "max"), gs; next
  }
  match($0, /\[gpuprobe\] frames=[0-9]+ avg=[0-9.]+ min=[0-9.]+ max=[0-9.]+ ms( disjoint=[0-9]+)?( hitch=[0-9]+)?/) {
    s = substr($0, RSTART, RLENGTH)
    print "gpu", kv(s, "frames"), kv(s, "avg"), kv(s, "min"), kv(s, "max"), kv(s, "disjoint"), kv(s, "hitch"), tag(); next
  }
  /\[gpuprobe\] no usable GPU-time this window/ { print "gpuempty", tag(); next }
  match($0, /\[framebins\] dt=[-0-9:,]+ jit=[-0-9:,]+ max=[0-9.]+ jitMax=[0-9.]+ gcN=-?[0-9]+ gcMs=-?[0-9]+ heapMB=[0-9]+\/[0-9]+ gs=[A-Z_]+/) {
    s = substr($0, RSTART, RLENGTH); gs = kv(s, "gs"); h = kv(s, "heapMB"); sub(/\/.*/, "", h)
    print "bins", kv(s, "dt"), kv(s, "jit"), kv(s, "max"), kv(s, "jitMax"), kv(s, "gcN"), kv(s, "gcMs"), h, gs; next
  }
  match($0, /\[framehist\] n=[0-9]+ p50=.* up=[0-9]+s scope=[A-Z_]+/) {
    s = substr($0, RSTART, RLENGTH)
    print "hist", kv(s, "n"), kv(s, "p50"), kv(s, "p95"), kv(s, "p99"), kv(s, "p999"), kv(s, "max"), kv(s, "jit50"), kv(s, "jit95"), kv(s, "jit99"), kv(s, "pauses"), kv(s, "gcN"), kv(s, "gcMs"), kv(s, "up"); next
  }
  match($0, /\[presentprobe\] presents=[0-9]+ gapMaxMs=[0-9.]+ swapAvgMs=[0-9.]+ swapMaxMs=[0-9.]+/) {
    s = substr($0, RSTART, RLENGTH)
    print "present", kv(s, "presents"), kv(s, "gapMaxMs"), kv(s, "swapAvgMs"), kv(s, "swapMaxMs"), tag(); next
  }
  /\[gc *\] GC\([0-9]+\) Pause / && $NF ~ /^[0-9.]+ms$/ { v = $NF; sub(/ms$/, "", v); print "gcpause", v, tag(); next }
  /\[safepoint *\] Safepoint "/ && match($0, /Total: [0-9]+ ns/) { print "safepoint", substr($0, RSTART + 7, RLENGTH - 10), tag(); next }
  match($0, /\[memwatch t= *[0-9.]+s\] avail=[0-9.]+MB footprint=[0-9.]+MB/) {
    t = substr($0, RSTART + 12); sub(/s\].*/, "", t); gsub(/ /, "", t)
    a = kv($0, "avail"); sub(/MB$/, "", a); f = kv($0, "footprint"); sub(/MB$/, "", f)
    hu = kv($0, "heapMB"); hc = hu; sub(/\/.*/, "", hu); sub(/.*\//, "", hc)
    print "mem", t, a, f, hu, hc, kv($0, "thermal"), tag(); next
  }
  match($0, /\[coldstart\] [A-Za-z]+ sinceStartMs=-?[0-9]+/) {
    s = substr($0, RSTART, RLENGTH); split(s, w, " "); print "coldstart", w[2], kv(s, "sinceStartMs"); next
  }
  match($0, /onboard: splash dismissed \(frame=[a-z]+ .*sinceStartMs=-?[0-9]+\)/) {
    s = substr($0, RSTART, RLENGTH); v = s; sub(/.*sinceStartMs=/, "", v); sub(/\).*/, "", v)
    print "coldstart", (s ~ /frame=true/) ? "firstFrame" : "splashTimeout", v; next
  }
  match($0, /thermal status=-?[0-9]+ -> sceneResolutionScale -?[0-9]+->[0-9]+ \(baseline=[0-9]+\)/) {
    s = substr($0, RSTART, RLENGTH); split(s, w, " "); split(w[5], sc, "->")
    b = s; sub(/.*baseline=/, "", b); sub(/\).*/, "", b)
    print "govern", kv(s, "status"), sc[1], sc[2], b, tod, tag(); next
  }
  match($0, /thermal: recovered a leaked throttle -> restored sceneResolutionScale=[0-9]+/) {
    s = substr($0, RSTART, RLENGTH); sub(/.*=/, "", s)
    print "govleak", s, tod; next
  }
')"

samples="$(printf '%s\n' "$records" | awk '$1=="fps" { print $2, $3 }')"
frames="$(printf '%s\n' "$records" | awk '$1=="frame" { print $2, $3, $4, $5, $6, $7 }')"
gpu="$(printf '%s\n' "$records" | awk '$1=="gpu" { print $2, $3, $4, $5, $6, $7, $8 }')"
gpuempty="$(printf '%s\n' "$records" | awk '$1=="gpuempty" { print $2 }')"
govern="$(printf '%s\n' "$records" | awk '$1=="govern" { print $2, $3, $4, $5, $6, $7 }')"
govleak="$(printf '%s\n' "$records" | awk '$1=="govleak" { print $2, $3 }')"
bins="$(printf '%s\n' "$records" | awk '$1=="bins" { print $2, $3, $4, $5, $6, $7, $8, $9 }')"
hist="$(printf '%s\n' "$records" | awk '$1=="hist"' | tail -1)"
present="$(printf '%s\n' "$records" | awk '$1=="present" { print $2, $3, $4, $5, $6 }')"
xlog="$(printf '%s\n' "$records" | awk '$1=="gcpause" || $1=="safepoint"')"
mem="$(printf '%s\n' "$records" | awk '$1=="mem" { print $2, $3, $4, $5, $6, $7, $8 }')"
coldstart="$(printf '%s\n' "$records" | awk '$1=="coldstart" { print $2, $3 }')"

# memwatch alone is enough to report (an iOS log from a launch without the perf probe); a cold-start stamp alone is not.
if [[ -z "$samples" && -z "$frames" && -z "$gpu" && -z "$gpuempty" && -z "$bins" && -z "$mem" ]]; then
  echo "no [fpsprobe]/[frameprobe]/[framebins]/[gpuprobe] samples found. Is the perf probe armed (-Drunelite.fpsprobe: Android debug build, or the perfprobe marker: tools/perfprobe.sh) and the scene rendering?" >&2
  exit 2
fi

# CSV (every kind, tagged by `kind`; column meanings per kind are in the header comment).
if [[ -n "$OUT" ]]; then
  {
    echo "label,kind,idx,a,b,c,d,e,gs,f,g"
    printf '%s\n' "$records" | awk -v L="$LABEL" '
      function v(x) { return x == "-" ? "" : x }
      $1=="fps"      { print L ",fps," nf++ "," $2 ",,,,," $3 ",," }
      $1=="frame"    { print L ",frame," nr++ "," $2 "," $3 "," $4 "," $5 "," $6 "," $7 ",," }
      $1=="gpu"      { print L ",gpu," ng++ "," $2 "," $4 "," $3 ",," $5 "," v($8) "," v($6) "," v($7) }
      $1=="gpuempty" { print L ",gpuempty," ne++ ",,,,,," v($2) ",," }
      $1=="govern"   { print L ",govern," nv++ "," $2 "," $3 "," $4 "," $5 "," v($6) "," v($7) ",," }
      $1=="bins"     { d = $2; j = $3; gsub(/,/, ";", d); gsub(/,/, ";", j)
                       print L ",framebins," nb++ "," $6 "," $7 "," $8 "," $4 "," $5 "," $9 "," v(d) "," v(j) }
      $1=="present"  { print L ",present," np++ "," $2 "," $3 "," $4 ",," $5 "," v($6) ",," }
      $1=="gcpause"  { print L ",gcpause," nc++ "," $2 ",,,,," v($3) ",," }
      $1=="safepoint" { print L ",safepoint," ns++ "," $2 ",,,,," v($3) ",," }
      $1=="mem"      { print L ",mem," nm++ "," $2 "," $3 "," $4 "," v($5) "," v($6) "," v($8) "," v($7) "," }
      $1=="coldstart" { print L ",coldstart," nk++ "," $3 ",,,,,," $2 "," }'
    printf '%s\n' "$thermal_rows" | awk -v L="$LABEL" '
      function v(x) { return x == "n/a" ? "" : x }
      NF==3 { print L ",thermal," n++ "," $1 "," v($2) "," v($3) ",,,,," }'
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

# Capture-window pacing over LOGGED_IN seconds: sum the [framebins] buckets, then read percentiles off them.
if [[ -n "$bins" ]]; then
  pacing="$(printf '%s\n' "$bins" | awk -v label="$LABEL" '
    function up(x) { return (x == int(x)) ? x : int(x) + 1 }
    function edge(i) { return 0.1 * exp(log(10) * (i + 1) / 20) }
    function pct(h, n, p, mx,   r, c, i) {
      if (n == 0) return 0
      r = up(p * n); if (r < 1) r = 1
      for (i = 0; i <= 80; i++) { c += h[i]; if (c >= r) return (i == 80 || edge(i) > mx) ? mx : edge(i) }
      return mx
    }
    function add(str, h,   k, a, b, j, t) {
      k = split(str, a, ","); t = 0
      for (j = 1; j <= k; j++) { split(a[j], b, ":"); if (b[2] != "") { h[b[1] + 0] += b[2]; t += b[2] } }
      return t
    }
    $8=="LOGGED_IN" {
      w++; ndt += add($1, dt); njit += add($2, jit)
      if ($3 + 0 > mx) mx = $3 + 0; if ($4 + 0 > jmx) jmx = $4 + 0
      if ($5 >= 0) { gcn += $5; gcms += $6; gcw++ }
      if ($7 + 0 > heap) heap = $7 + 0
    }
    END {
      if (w == 0) { print "pacing: no LOGGED_IN [framebins] windows"; exit }
      printf "%-10s  pacing windows=%-3d frames=%-5d  p50=%.2f  p95=%.2f  p99=%.2f  p999=%.2f  max=%.2f  jit50=%.2f  jit95=%.2f  jit99=%.2f  (ms, bucket upper edges)\n", \
        label, w, ndt, pct(dt, ndt, 0.50, mx), pct(dt, ndt, 0.95, mx), pct(dt, ndt, 0.99, mx), pct(dt, ndt, 0.999, mx), mx, \
        pct(jit, njit, 0.50, jmx), pct(jit, njit, 0.95, jmx), pct(jit, njit, 0.99, jmx)
      printf "gcwin %d %d %d %d\n", gcw, gcn, gcms, heap
    }')"
  printf '%s\n' "$pacing" | grep -v '^gcwin ' || true
  gcwin="$(printf '%s\n' "$pacing" | grep '^gcwin ' || true)"
  # GC over the same LOGGED_IN seconds (MXBean deltas from [framebins]) + per-pause detail when -Xlog is armed.
  if [[ -n "$gcwin" ]]; then
    { echo "$gcwin"; printf '%s\n' "$xlog"; } | awk -v label="$LABEL" '
      $1=="gcwin" { gcw = $2; gcn = $3; gcms = $4; heap = $5; next }
      $1=="gcpause" { xl = 1; if ($3=="LOGGED_IN") { pn++; ps += $2; if ($2 + 0 > pm) pm = $2 + 0 } next }
      $1=="safepoint" { xl = 1; if ($3=="LOGGED_IN") { sn++; ss += $2 / 1e6; if ($2 / 1e6 > sm) sm = $2 / 1e6 } next }
      END {
        if (gcw == 0) mx = "gcN=n/a  gcMs=n/a"; else mx = sprintf("gcN=%d  gcMs=%d", gcn, gcms)
        if (xl) xs = sprintf("pauses=%d  pauseMs=%.2f  pauseMax=%.2f  safepoints=%d  safepointMs=%.2f  safepointMax=%.2f", pn, ps, pm, sn, ss, sm)
        else xs = "pauses=n/a  (no -Xlog:gc lines)"
        printf "%-10s  gc     %s  heapMaxMB=%d  %s\n", label, mx, heap, xs
      }'
  fi
fi

# Present cadence over LOGGED_IN windows ([presentprobe]: the GPU/117HD direct present on either port, Android's
# CPU blit, or the iOS PiP frame feed).
if [[ -n "$present" ]]; then
  printf '%s\n' "$present" | awk -v label="$LABEL" '
    $5=="LOGGED_IN" { w++; n += $1; sw += $1 * $3; if ($2 + 0 > gap) gap = $2 + 0; if ($4 + 0 > smx) smx = $4 + 0; next }
    $5=="-" { untagged++; next }
    { other++ }
    END {
      skipped = (untagged || other) ? sprintf("  (excluded: %d untagged, %d other-state)", untagged, other) : ""
      if (w == 0) { printf "present: no LOGGED_IN windows%s\n", skipped; exit }
      printf "%-10s  present windows=%-3d presents=%-5d  perSec=%.1f  gapMax=%.2f  swapAvg=%.2f  swapMax=%.2f  (ms)%s\n", \
        label, w, n, n / w, gap, n ? sw / n : 0, smx, skipped
    }'
fi

# The last session summary in the log (since the first frame, LOGGED_IN seconds; not limited to this capture).
if [[ -n "$hist" ]]; then
  printf '%s\n' "$hist" | awk -v label="$LABEL" '{
    printf "%-10s  session n=%d  p50=%s  p95=%s  p99=%s  p999=%s  max=%s  jit50=%s  jit95=%s  jit99=%s  pauses=%s  gcN=%s  gcMs=%s  up=%s  (ms, since first frame)\n", \
      label, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14 }'
fi

# Memory over every memwatch sample in the log (all states: a leak or a jetsam squeeze is not a LOGGED_IN-only thing).
if [[ -n "$mem" ]]; then
  printf '%s\n' "$mem" | awk -v label="$LABEL" '
    function rank(t) { return t=="nominal" ? 0 : t=="fair" ? 1 : t=="serious" ? 2 : t=="critical" ? 3 : -1 }
    function na(t) { return t == "-" ? "n/a" : t }
    BEGIN { wr = -1; worst = "-" }
    NF >= 6 {
      n++; if (n == 1) { t0 = $1; f0 = $3; th0 = $6 }
      t1 = $1; f1 = $3; th1 = $6
      if (n == 1 || $2 + 0 < amn) amn = $2 + 0
      if ($3 + 0 > fmx) fmx = $3 + 0
      if ($4 != "-") { hn++; hu = $4; hc = $5; if ($4 + 0 > hmx) hmx = $4 + 0 }
      if (rank($6) > wr) { wr = rank($6); worst = $6 }
    }
    END {
      if (n == 0) exit
      heap = hn ? sprintf("heapUsedMB=%d  heapCommittedMB=%d  heapUsedMaxMB=%d", hu, hc, hmx) : "heapUsedMB=n/a"
      printf "%-10s  mem    samples=%-3d  tFirst=%s  tLast=%s  availMinMB=%.1f  footprintFirstMB=%.1f  footprintLastMB=%.1f  footprintMaxMB=%.1f  %s  thermalFirst=%s  thermalLast=%s  thermalWorst=%s\n", \
        label, n, t0, t1, amn, f0, f1, fmx, heap, na(th0), na(th1), na(worst)
    }'
fi

# Cold start: each milestone's last stamp in the log (a log can span more than one launch only on Android).
if [[ -n "$coldstart" ]]; then
  printf '%s\n' "$coldstart" | awk -v label="$LABEL" '
    NF == 2 { if (!($1 in ms)) order[++k] = $1; ms[$1] = $2 }
    END {
      if (k == 0) exit
      for (i = 1; i <= k; i++) s = s sprintf("  %s=%s", order[i], ms[order[i]])
      printf "%-10s  coldstart%s  (ms since process start)\n", label, s
    }'
fi

# GPU-time stats over LOGGED_IN windows (frame-weighted avg, min-of-min, max-of-max, summed disjoint/hitch). Only
# present when debug.routec.gputime=1. Windows in another state, or untagged, are counted so none vanish silently.
if [[ -n "$gpu" || -n "$gpuempty" ]]; then
  { printf '%s\n' "$gpu" | awk 'NF { print "w", $0 }'; printf '%s\n' "$gpuempty" | awk 'NF { print "e", $1 }'; } \
  | awk -v label="$LABEL" '
    $1=="e" { if ($2=="LOGGED_IN") empty++; next }
    $8=="-" { untagged++; next }
    $8!="LOGGED_IN" { other++; next }
    {
      w++; frames+=$2; wavg+=$2*$3; if (mn==0 || $4<mn) mn=$4; if ($5>mx) mx=$5;
      if ($6=="-") nodj=1; else dj+=$6;
      if ($7=="-") nohi=1; else hi+=$7;
    }
    END {
      skipped = (untagged || other) ? sprintf("  (excluded: %d untagged, %d other-state)", untagged, other) : ""
      if (w==0) { printf "gpu:   no LOGGED_IN windows with GPU-time (%d empty)%s\n", empty, skipped; exit }
      printf "%-10s  gpu    windows=%-3d frames=%-4d  min=%.2f  avg=%.2f  max=%.2f  (ms GPU)  disjoint=%s  hitch=%s  empty=%d%s\n", \
        label, w, frames, mn, wavg/frames, mx, nodj ? "n/a" : dj, nohi ? "n/a" : hi, empty, skipped
    }'
fi

# Per-second thermal over the adb window.
if [[ -n "$thermal_rows" ]]; then
  printf '%s\n' "$thermal_rows" | awk -v label="$LABEL" '
    NF==3 {
      n++
      if ($2 != "n/a") { h++; if (h==1 || $2<hmn) hmn=$2; if (h==1 || $2>hmx) hmx=$2 }
      if ($3 != "n/a") { s++; if (s==1) s0=$3; s1=$3; if ($3>smx) smx=$3 }
    }
    END {
      if (n==0) exit
      printf "%-10s  thermal samples=%-3d  hottest=%s..%sC  status=%s->%s (max %s)\n", label, n, \
        h ? sprintf("%.1f", hmn) : "n/a", h ? sprintf("%.1f", hmx) : "n/a", s ? s0 : "n/a", s ? s1 : "n/a", s ? smx : "n/a"
    }'
fi

# ThermalGovernor. On older builds the arm-time apply logs prev=-1 and sets the scale it already had, so it isn't a change.
if [[ -n "$govern" ]]; then
  printf '%s\n' "$govern" | awk -v label="$LABEL" '
    NF==6 {
      last=$3; base=$4
      if (mn=="" || $3<mn) mn=$3
      if ($2>0 && $2!=$3) { ch++; moves = moves sprintf(" %s->%s@%s", $2, $3, $5) }
    }
    END {
      printf "%-10s  govern changes=%d  scale=%s  minScale=%s  baseline=%s\n", label, ch, last, mn, base
      if (ch) printf "!! ThermalGovernor changed sceneResolutionScale during the capture (%s): windows before and after are different workloads, not one A/B arm\n", substr(moves, 2)
    }'
fi
if [[ -n "$govleak" ]]; then
  printf '%s\n' "$govleak" | awk '{ printf "!! ThermalGovernor restored a leaked throttle (sceneResolutionScale=%s at %s)\n", $1, $2 }'
fi
