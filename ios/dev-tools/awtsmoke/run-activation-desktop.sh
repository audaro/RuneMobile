#!/usr/bin/env bash
# W1 Phase 3 §6.0 — desktop PRE-CHECK of the CACIO activation mechanism.
#
# Question: WHAT actually activates CACIO's CTC toolkit + graphicsenv on JDK 21?
# We control launch flags + can call code via the RuneMobile launcher on device, so
# this finds what works on desktop, then asks whether it ports to the iOS JRE.
#
# OBSERVED (2026-05-29, OpenJDK 21.0.5 aarch64 macOS) — read the printed verdicts;
# the docs quote the captured output, not the other way round:
#   (a) classpath    + props (+JPMS)   => FAILED      (toolkit=LWCToolkit, GE=CGraphicsEnvironment — native)
#   (b) bootclasspath + props (no JPMS)=> FAILED      (same — native; -Dawt.toolkit is NOT honored on JDK 21)
#   (c) AGENT inject() + allowAttachSelf=> CTC ACTIVE  (toolkit AND GE both = CTC) — the JVMTI redefine THREW
#                                          ("class redefinition failed: change the schema") yet activation
#                                          still succeeded (carried by CacioExtension's field injection).
#   (d) FIELD-POKE (naive reflection)  => FAILED       (GE singleton lives in lazy holder
#                                          GraphicsEnvironment$LocalGE; there is NO `localEnv` field, so the
#                                          poke broke GE init). Superseded by (e).
#   (e) UNSAFE FIELD-POKE              => CTC ACTIVE   (no byte-buddy/attach/JVMTI). Seeds SMF.instance +
#                                          headless flags + Toolkit.toolkit, then Unsafe-overwrites the
#                                          static-final GraphicsEnvironment$LocalGE.INSTANCE with the CTC GE.
#                                          3/3 repeatable; toolkit AND GE both = CTC; 1024x768 CTC vscreen.
#
# THE FINDING (corrected 2026-05-30): property/bootclasspath selection does NOTHING on
# JDK 21. Mode (c) the byte-buddy redefine of getLocalGraphicsEnvironment / createGE
# SUCCEEDS the first time and IS load-bearing for the GE swap (CacioExtension's static{}
# alone activates CTC, no throw — see StaticOnlyProbe). The "redefine throws yet succeeds"
# note was a MISREAD: the throw only appeared because AwtActivationAgent.main called
# inject() a *second* time, re-redefining an already-redefined method ("change the schema").
# So the agent needs real instrumentation — and the device jre21 has none. Mode (e) is the
# device path: it reaches CTC ACTIVE with zero instrumentation.
#
# DEVICE IMPLICATION: §6.0-on-device uses mode (e). The ONE remaining device unknown is
# that (e) forces GraphicsEnvironment$LocalGE.<clinit> once (runs the iOS jre21's hardcoded
# PlatformGraphicsInfo.createGE() before we clobber INSTANCE) — must survive on device.
# That is the single short device confirm; everything else is standard java.desktop 21.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

JAVA="${JAVA:-/opt/homebrew/opt/openjdk@21/bin/java}"
JAVAC="${JAVAC:-/opt/homebrew/opt/openjdk@21/bin/javac}"
L="../cacio-smoke/lib"
CACIO_RUNTIME="$L/cacio-tta-1.18.jar:$L/cacio-shared-1.18.jar"
CACIO_AGENT="$CACIO_RUNTIME:$L/byte-buddy-1.14.11.jar:$L/byte-buddy-agent-1.14.11.jar"
JUNIT="$L/junit-platform-console-standalone-1.10.2.jar"   # CacioExtension implements a junit iface -> needed to COMPILE AwtActivationAgent
MODE="${1:-all}"

PROPS=(
  -Djava.awt.headless=false
  -Dawt.toolkit=com.github.caciocavallosilano.cacio.ctc.CTCToolkit
  -Djava.awt.graphicsenv=com.github.caciocavallosilano.cacio.ctc.CTCGraphicsEnvironment
)
JPMS=(
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
GREP='isHeadless|getDefaultToolkit\(\) =|getLocalGraphicsEnvironment\(\) =|AWT-ACTIVATION|injectCTC|THREW|Unsafe-overwrote'

# Clean out/ every run and fail-fast on compile errors. (A masked compile failure that
# leaves a STALE .class behind made mode (e) flap FAILED<->CTC ACTIVE — never again.)
rm -rf out && mkdir -p out
echo "== compile =="
"$JAVAC" --release 8 -d out AwtActivation.java || { echo "!! AwtActivation compile failed"; exit 1; }
"$JAVAC" -cp "$CACIO_RUNTIME:out" -d out FieldPokeActivation.java || { echo "!! FieldPokeActivation compile failed"; exit 1; }
"$JAVAC" --release 8 -cp "$CACIO_RUNTIME:out" -d out UnsafePokeActivation.java || { echo "!! UnsafePokeActivation compile failed"; exit 1; }
# AwtActivationAgent references CacioExtension (implements a junit iface) -> junit on cp.
"$JAVAC" -cp "$CACIO_AGENT:$JUNIT:out" -d out AwtActivationAgent.java || { echo "!! agent harness failed to compile"; exit 1; }

run_a() {
  echo; echo "########## (a) classpath + props (+JPMS) — OBSERVED: FAILED ##########"
  "$JAVA" -cp "out:$CACIO_RUNTIME" "${PROPS[@]}" "${JPMS[@]}" AwtActivation 2>&1 | grep -E "$GREP"
}
run_b() {
  echo; echo "########## (b) -Xbootclasspath/a + props (no JPMS) — OBSERVED: FAILED ##########"
  "$JAVA" "-Xbootclasspath/a:$CACIO_RUNTIME" "${PROPS[@]}" -cp out AwtActivation 2>&1 | grep -E "$GREP"
}
run_c() {
  echo; echo "########## (c) AGENT inject + allowAttachSelf — OBSERVED: JVMTI redefine THREW, yet CTC ACTIVE (toolkit+GE both CTC) ##########"
  "$JAVA" -Djdk.attach.allowAttachSelf=true -Djava.awt.headless=false "${JPMS[@]}" \
    -cp "out:$CACIO_AGENT:$JUNIT" AwtActivationAgent 2>&1 | grep -E "$GREP"
}
run_d() {
  echo; echo "########## (d) FIELD-POKE naive reflection — OBSERVED: FAILED (no localEnv field; GE singleton is in lazy holder LocalGE) ##########"
  "$JAVA" -Djava.awt.headless=false "${JPMS[@]}" \
    -cp "out:$CACIO_RUNTIME" FieldPokeActivation 2>&1 | grep -E "$GREP"
}
run_e() {
  echo; echo "########## (e) UNSAFE FIELD-POKE (no byte-buddy/attach/JVMTI) — OBSERVED: CTC ACTIVE (toolkit+GE both CTC) ##########"
  "$JAVA" -Djava.awt.headless=false "${JPMS[@]}" \
    -cp "out:$CACIO_RUNTIME" UnsafePokeActivation 2>&1 | grep -E "$GREP"
}

case "$MODE" in
  a) run_a ;; b) run_b ;; c) run_c ;; d) run_d ;; e) run_e ;;
  all) run_a; run_b; run_c; run_d; run_e ;;
  *) echo "usage: $0 [a|b|c|d|e|all]"; exit 2 ;;
esac
