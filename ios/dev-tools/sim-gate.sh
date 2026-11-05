#!/usr/bin/env bash
# sim-gate.sh — the iOS Simulator gate: build once, run every simulator check, give one GREEN/RED verdict.
#
#   ios/dev-tools/sim-gate.sh                         # build + install, then every check (~10 min, build current)
#   ios/dev-tools/sim-gate.sh --jars                  # restage the jars first (after a Java change)
#   ios/dev-tools/sim-gate.sh --no-build              # reinstall the last simulator build instead of building
#   ios/dev-tools/sim-gate.sh --skip sweep            # leave checks out (comma list of census, screens, sweep,
#                                                     # renderers)
#   RENDERERS="gpu 117hd" ios/dev-tools/sim-gate.sh   # boot only these (default: cpu gpu 117hd)
#
# The checks, in order. A failed check doesn't stop the run, so one run shows everything that is wrong; only a
# failed build or install does.
#   0. redaction         diagnostics/test-redaction.sh: the "Share logs" redaction (RMRedact.m, built for the
#                        Mac) against tools/diagnostics/redaction-cases.txt, the cases Android's RedactTest checks
#   1. build + install   ./run-sim.sh --no-launch
#   2. census            bridge-census/run-census-sim.sh: every JNI lookup the native code makes resolves
#   3. screens           sim-screens/sim-screens.py: the native screens match their goldens
#   4. sweep             sim-screens/plugin-sweep.py: every plugin's settings screen and every side panel on the
#                        rail opens, shows something, and logs no [bridge-fault]
#   5. renderers         sim-gate/boot-renderer.py per renderer: the client reaches LOGIN_SCREEN on the renderer
#                        it was asked for (not the crash cookie's CPU fallback) and is still running 15 s later
#                        (117hd also checks a player's launch: 117HD off, the login screen's picture still moving)
#   6. log scan          tools/log-scan/log-scan.py over every launch's jvm-stdio.log and hello-shell.log: no line
#                        that isn't on the known-noise list, and no shader error at all (the list can't excuse one)
# Every launch is logged out (-RMSkipLogin), so the gate never logs into the game, whatever session the simulator
# holds. SIM_NAME / SIM_UDID pick the simulator as in run-sim.sh. Output lands in build/sim-gate/<stamp>/: each
# step's output, each launch's two logs under logs/<launch>/, the scan's log-scan.json, and summary.txt. Exits 0
# exactly when GREEN; the last line is VERDICT: SIM_GATE_GREEN or _RED.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BUNDLE_ID=dev.audaro.runemobile
PY=/usr/bin/python3 # sim-screens and boot-renderer import tools/mcp, which needs PIL + numpy
RENDERERS="${RENDERERS:-cpu gpu 117hd}"
DWELL="${DWELL:-15}"

BUILD=yes
JARS=no
SKIP=","
while [ $# -gt 0 ]; do
  case "$1" in
    --jars) JARS=yes ;;
    --no-build) BUILD=no ;;
    --skip) shift; SKIP=",${1:-},"; ;;
    --skip=*) SKIP=",${1#--skip=}," ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
for s in $(echo "$SKIP" | tr ',' ' '); do
  case "$s" in census | screens | sweep | renderers) ;;
    *) echo "--skip takes census, screens, sweep, renderers (got '$s')" >&2; exit 2 ;;
  esac
done
for r in $RENDERERS; do
  case "$r" in cpu | gpu | 117hd) ;; *) echo "RENDERERS takes cpu, gpu, 117hd (got '$r')" >&2; exit 2 ;; esac
done
[ "$JARS$BUILD" != yesno ] || { echo "--jars needs a build (drop --no-build)" >&2; exit 2; }
skipped() { case "$SKIP" in *",$1,"*) return 0 ;; esac; return 1; }

RUN="$REPO/build/sim-gate/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN/logs"
STEPS=()       # "<step>|<PASS|FAIL|SKIP>|<detail>"
SCAN_ARGS=()   # --sim <file> for each kept log
SCANNED=0
LOG_GAPS=()    # logs a passing launch should have left and didn't (its lines went unchecked)
started=$SECONDS

log() { printf '\n\033[1;35m>> %s\033[0m\n' "$*"; }
record() { # <step> <PASS|FAIL|SKIP> <detail>
  STEPS+=("$1|$2|$3")
  printf '   %-18s %s  %s\n' "$1" "$2" "$3"
}
verdict_of() { sed -n 's/^[[:space:]]*VERDICT:[[:space:]]*\([A-Z0-9_]*\).*/\1/p' "$1" | tail -1; }
docs_dir() { local d; d="$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data 2>/dev/null)" && echo "$d/Documents"; }

finish() {
  local word=GREEN fails=0 line
  {
    echo "sim-gate on $SIM_NAME_SHOWN ($SIM_UDID), $((SECONDS - started)) s, $RUN"
    for line in "${STEPS[@]}"; do
      IFS='|' read -r step status detail <<<"$line"
      printf '   %-18s %s  %s\n' "$step" "$status" "$detail"
      [ "$status" != FAIL ] || fails=$((fails + 1))
    done
  } > "$RUN/summary.txt"
  [ "$fails" = 0 ] || word=RED
  xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  log "Summary"
  sed 1d "$RUN/summary.txt"
  echo "summary=$RUN/summary.txt"
  if [ "$word" = GREEN ]; then
    echo "SIM_GATE_GREEN"
  else
    echo "SIM_GATE_RED ($fails failed)"
  fi
  echo "VERDICT: SIM_GATE_$word"
  [ "$word" = GREEN ]
  exit $?
}

keep_logs() { # <launch name> <epoch the step started> <passed: yes|no>: copy this launch's logs for the scan
  local name="$1" since="$2" passed="$3" docs f born gap dst="$RUN/logs/$1"
  docs="$(docs_dir)" || docs=""
  mkdir -p "$dst"
  for f in jvm-stdio.log hello-shell.log; do
    gap=""
    if [ -z "$docs" ] || [ ! -f "$docs/$f" ]; then
      gap="missing"
    else
      # The app moves each log to .prev and starts a new one at launch, so the birth time is the launch time.
      born="$(stat -f %B "$docs/$f")"
      [ "$born" -ge $((since - 1)) ] || gap="left by an earlier launch"
    fi
    if [ -n "$gap" ]; then
      # A failed launch is RED already; a passing one without its logs means lines nobody checked.
      [ "$passed" = no ] || LOG_GAPS+=("$name/$f $gap")
      continue
    fi
    cp "$docs/$f" "$dst/$f"
    SCAN_ARGS+=(--sim "$dst/$f")
    SCANNED=$((SCANNED + 1))
  done
}

cd "$REPO" || exit 2
SIM_UDID="$(ios/dev-tools/run-sim.sh --print-udid)" || { echo "!! no simulator (see run-sim.sh)"; echo "VERDICT: SIM_GATE_RED"; exit 1; }
export SIM_UDID
SIM_NAME_SHOWN="$(xcrun simctl list devices -j | "$PY" -c '
import json, sys
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["udid"] == sys.argv[1]:
            print(d["name"])
' "$SIM_UDID")"
log "sim-gate on ${SIM_NAME_SHOWN:-?} ($SIM_UDID); output in $RUN"

# 0) "Share logs" redaction, before anything needs the simulator (~2 s).
log "Share-logs redaction cases"
if out="$(bash ios/dev-tools/diagnostics/test-redaction.sh 2>&1)"; then
  record redaction PASS "$(tail -1 <<<"$out")"
else
  printf '%s\n' "$out" | tail -12
  record redaction FAIL "$(tail -1 <<<"$out")"
fi

# 1) Build + install. Everything after this uses the installed app.
flags=(--no-launch)
[ "$BUILD" = yes ] || flags+=(--no-build)
[ "$JARS" = no ] || flags+=(--jars)
log "Build + install (run-sim.sh ${flags[*]})"
t=$SECONDS
if RENDERER=cpu bash ios/dev-tools/run-sim.sh "${flags[@]}" > "$RUN/build.log" 2>&1; then
  record build PASS "$((SECONDS - t)) s"
else
  tail -25 "$RUN/build.log"
  record build FAIL "run-sim.sh failed; see $RUN/build.log"
  finish
fi

# 2) Bridge census (CPU renderer; one run covers every renderer's classpath).
if skipped census; then
  record census SKIP "--skip census"
else
  log "Bridge census"
  t=$SECONDS
  since="$(date +%s)"
  bash ios/dev-tools/bridge-census/run-census-sim.sh --no-build > "$RUN/census.log" 2>&1
  rc=$?
  v="$(verdict_of "$RUN/census.log")"
  detail="$(grep -m1 '^checked=' "$RUN/census.log")"
  if [ "$rc" = 0 ] && [ "$v" = IOS_BRIDGE_CENSUS_GREEN ]; then
    record census PASS "$detail ($((SECONDS - t)) s)"
    keep_logs census "$since" yes
  else
    grep '^!! \|missing: ' "$RUN/census.log" | head -8
    record census FAIL "${v:-no verdict} (exit $rc); see $RUN/census.log"
    keep_logs census "$since" no
  fi
fi

# 3) Screen goldens.
if skipped screens; then
  record screens SKIP "--skip screens"
else
  log "Screen goldens"
  t=$SECONDS
  since="$(date +%s)"
  "$PY" ios/dev-tools/sim-screens/sim-screens.py --no-build > "$RUN/screens.log" 2>&1
  rc=$?
  v="$(verdict_of "$RUN/screens.log")"
  grep -E '^   .* (FAIL|ERROR|NO_GOLDEN) ' "$RUN/screens.log" || true
  if [ "$rc" = 0 ] && [ "$v" = SIM_SCREENS_GREEN ]; then
    record screens PASS "$(grep -m1 '^matched ' "$RUN/screens.log") ($((SECONDS - t)) s)"
    keep_logs screens "$since" yes
  else
    grep '^!! ' "$RUN/screens.log" | tail -3
    record screens FAIL "${v:-no verdict} (exit $rc); shots: $(sed -n 's/^shots=//p' "$RUN/screens.log")"
    keep_logs screens "$since" no
  fi
fi

# 4) Plugin sweep: every settings screen and side panel.
if skipped sweep; then
  record sweep SKIP "--skip sweep"
else
  log "Plugin sweep"
  since="$(date +%s)"
  "$PY" ios/dev-tools/sim-screens/plugin-sweep.py --no-build > "$RUN/sweep.log" 2>&1
  rc=$?
  v="$(verdict_of "$RUN/sweep.log")"
  grep -E '^   FAIL ' "$RUN/sweep.log" || true
  if [ "$rc" = 0 ] && [ "$v" = PLUGIN_SWEEP_GREEN ]; then
    record sweep PASS "$(grep -m1 '^checked ' "$RUN/sweep.log")"
    keep_logs sweep "$since" yes
  else
    grep '^!! ' "$RUN/sweep.log" | tail -3
    record sweep FAIL "${v:-no verdict} (exit $rc); shots: $(sed -n 's/^shots=//p' "$RUN/sweep.log")"
    keep_logs sweep "$since" no
  fi
fi

# 5) Each renderer, logged out, to the login screen.
if skipped renderers; then
  record renderers SKIP "--skip renderers"
else
  for r in $RENDERERS; do
    log "Renderer $r"
    since="$(date +%s)"
    "$PY" ios/dev-tools/sim-gate/boot-renderer.py "$r" --dwell "$DWELL" > "$RUN/renderer-$r.log" 2>&1
    rc=$?
    cat "$RUN/renderer-$r.log"
    if [ "$rc" = 0 ] && tail -1 "$RUN/renderer-$r.log" | grep -qx "RENDERER_OK $r"; then
      record "renderer $r" PASS "$(grep "^   $r: " "$RUN/renderer-$r.log" | sed "s/^   $r: //" | paste -sd ";" -)"
      keep_logs "renderer-$r" "$since" yes
    else
      record "renderer $r" FAIL "$(grep -m1 '^!! ' "$RUN/renderer-$r.log" | sed 's/^!! //' | cut -c1-200)"
      keep_logs "renderer-$r" "$since" no
    fi
  done
fi

# 6) Log scan over every launch kept above.
log "Log scan"
if [ "$SCANNED" = 0 ]; then
  record "log scan" FAIL "no launch left logs to scan"
else
  "$PY" tools/log-scan/log-scan.py "${SCAN_ARGS[@]}" --json "$RUN/log-scan.json" > "$RUN/log-scan.log" 2>&1
  rc=$?
  v="$(verdict_of "$RUN/log-scan.log")"
  sed -n '/^known noise/,/^LOG_SCAN_/p' "$RUN/log-scan.log" | grep -v '^LOG_SCAN_'
  shader="$("$PY" -c '
import json, sys
res = json.load(open(sys.argv[1]))
bad = ["%s=%d" % (f["file"].split("/logs/")[-1], f["shaderErrors"]) for f in res["files"] if f["shaderErrors"]]
print(" ".join(bad))
' "$RUN/log-scan.json" 2>/dev/null)" || shader="unreadable log-scan.json"
  problems=()
  [ "$rc" = 0 ] && [ "$v" = LOG_SCAN_GREEN ] || problems+=("${v:-no verdict} (exit $rc)")
  [ -z "$shader" ] || problems+=("shader errors: $shader")
  for g in "${LOG_GAPS[@]+"${LOG_GAPS[@]}"}"; do problems+=("not scanned: $g"); done
  if [ "${#problems[@]}" = 0 ]; then
    record "log scan" PASS "$(grep -m1 '^LOG_SCAN_GREEN' "$RUN/log-scan.log" | sed 's/^LOG_SCAN_GREEN //'), $SCANNED files"
  else
    joined=""
    for p in "${problems[@]}"; do joined="$joined$p; "; done
    record "log scan" FAIL "${joined}see $RUN/log-scan.log"
  fi
fi

finish
