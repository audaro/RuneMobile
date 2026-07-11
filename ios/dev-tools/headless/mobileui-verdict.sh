#!/usr/bin/env bash
# Shared GREEN/RED verdict for the MobileUiBridge STEP-0 smoke — used by BOTH the desktop runner
# (run-mobileui-smoke.sh, two local JVM launches) and the device confirm (a pulled jvm-stdio.log from
# two StikDebug launches). The verdict is computed HERE in bash from the grepped MUI_* markers and
# md5-gated against the verbatim log(s) — never trusting a JVM-printed success string (the documented
# false-GREEN guard).
#
# Usage:
#   mobileui-verdict.sh <run1.log> [run2.log]
# One log    -> single-launch gates (no cross-launch persistence; that needs two launches).
# Two logs   -> also requires run2's PERSIST_PRELOAD == run1's PERSIST_WRITTEN (disk round-trip).
set -euo pipefail

LOG1="${1:?usage: mobileui-verdict.sh <run1.log> [run2.log]}"
LOG2="${2:-}"

mk() { grep -m1 "^$1=" "$2" 2>/dev/null | cut -d= -f2- || true; }
md5of() { if command -v md5 >/dev/null; then md5 -q; else md5sum | cut -d' ' -f1; fi; }

EA="$(mk MUI_EA "$LOG1")"
LIST_OK="$(mk MUI_LIST_OK "$LOG1")"
CFG_FIRED="$(mk MUI_CONFIG_FIRED "$LOG1")"
CFG_VAL_OK="$(mk MUI_CONFIG_VALUE_OK "$LOG1")"
CFG_CLIENT="$(mk MUI_CONFIG_ON_CLIENT_THREAD "$LOG1")"
CFG_EDT="$(mk MUI_CONFIG_ON_EDT "$LOG1")"
TOGGLE_OK="$(mk MUI_TOGGLE_OK "$LOG1")"
TOGGLE_EDT="$(mk MUI_TOGGLE_ON_EDT "$LOG1")"
TOGGLE_TARGET="$(mk MUI_TOGGLE_TARGET "$LOG1")"
OVERLAY_GREW="$(mk MUI_OVERLAY_GREW "$LOG1")"
LOGGED_IN="$(mk MUI_LOGGED_IN "$LOG1")"
CHAT_OK="$(mk MUI_CHAT_OK "$LOG1")"
WRITTEN1="$(mk MUI_PERSIST_WRITTEN "$LOG1")"

# Typed config round-trip (verdict #7: native-shaped write -> ConfigManager serialization -> typed read-back
# through the exact proxy path the live plugin reads). The single biggest de-risk before native controls.
RT_COLOR="$(mk MUI_RT_COLOR_OK "$LOG1")"
RT_INT="$(mk MUI_RT_INT_OK "$LOG1")"
RT_DOUBLE="$(mk MUI_RT_DOUBLE_OK "$LOG1")"
RT_ENUM="$(mk MUI_RT_ENUM_OK "$LOG1")"
# Native-origin color leg: present ONLY on device (the ObjC shell writes it). Empty on desktop -> not gated.
RT_NATIVE="$(mk MUI_RT_NATIVE_COLOR_OK "$LOG1")"

# Bridge fixes: event/ack surface + getPluginConfig completeness + reset-reapplies-default. Each *_OK is
# designed to be true even when no representative item exists, so they're always-on hard gates.
ACK_OK="$(mk MUI_ACK_OK "$LOG1")"
EVT_SEQ="$(mk MUI_EVT_SEQ_ADVANCED "$LOG1")"
EVT_POLL="$(mk MUI_EVT_POLL_OK "$LOG1")"
CFG_HIDDEN="$(mk MUI_CFG_HIDDEN_OK "$LOG1")"
CFG_SECRET="$(mk MUI_CFG_SECRET_OK "$LOG1")"
CFG_SET="$(mk MUI_CFG_SET_OK "$LOG1")"
CFG_ALPHA="$(mk MUI_CFG_ALPHA_OK "$LOG1")"
CFG_WARN="$(mk MUI_CFG_WARNING_OK "$LOG1")"
RESET_OK="$(mk MUI_RESET_DEFAULT_OK "$LOG1")"

# Cross-launch persistence (only when a second log is supplied).
XLAUNCH="n/a"
if [ -n "$LOG2" ]; then
  PRELOAD2="$(mk MUI_PERSIST_PRELOAD "$LOG2")"
  if [ -n "$WRITTEN1" ] && [ "$PRELOAD2" = "$WRITTEN1" ]; then
    XLAUNCH="true"
  else
    XLAUNCH="false"
  fi
fi

echo
echo "================ MobileUiBridge STEP-0 SMOKE ================"
printf '  %-26s %s\n' "ea-live"                 "$EA"
printf '  %-26s %s\n' "listPlugins"             "$LIST_OK"
printf '  %-26s %s\n' "config fired"            "$CFG_FIRED"
printf '  %-26s %s\n' "config value match"      "$CFG_VAL_OK"
printf '  %-26s %s\n' "config on CLIENT thread" "$CFG_CLIENT"
printf '  %-26s %s\n' "config NOT on EDT"       "$([ "$CFG_EDT" = "false" ] && echo true || echo "$CFG_EDT")"
printf '  %-26s %s\n' "toggle ok (EDT)"         "$TOGGLE_OK  (target: ${TOGGLE_TARGET:-?})"
printf '  %-26s %s\n' "overlay grew (headless)" "$OVERLAY_GREW"
printf '  %-26s %s\n' "logged in"               "$LOGGED_IN"
printf '  %-26s %s\n' "chat bounds ok"          "$CHAT_OK"
printf '  %-26s %s\n' "persist x-launch"        "$XLAUNCH"
printf '  %-26s %s\n' "round-trip color"        "$RT_COLOR  (target: $(mk MUI_RT_COLOR_TARGET "$LOG1"))"
printf '  %-26s %s\n' "round-trip int"          "$RT_INT  (target: $(mk MUI_RT_INT_TARGET "$LOG1"))"
printf '  %-26s %s\n' "round-trip double"       "$RT_DOUBLE  (target: $(mk MUI_RT_DOUBLE_TARGET "$LOG1"))"
printf '  %-26s %s\n' "round-trip enum"         "$RT_ENUM  (target: $(mk MUI_RT_ENUM_TARGET "$LOG1"))"
printf '  %-26s %s\n' "round-trip native color" "${RT_NATIVE:-(desktop: n/a)}"
printf '  %-26s %s\n' "write ack (writeId)"     "$ACK_OK"
printf '  %-26s %s\n' "event seq advanced"      "$EVT_SEQ"
printf '  %-26s %s\n' "event poll delta"        "$EVT_POLL"
printf '  %-26s %s\n' "hidden masked"           "$CFG_HIDDEN  (present: $(mk MUI_CFG_HIDDEN_PRESENT "$LOG1"))"
printf '  %-26s %s\n' "secret masked"           "$CFG_SECRET  (present: $(mk MUI_CFG_SECRET_PRESENT "$LOG1"))"
printf '  %-26s %s\n' "set choices emitted"     "$CFG_SET  (present: $(mk MUI_CFG_SET_PRESENT "$LOG1"))"
printf '  %-26s %s\n' "alpha emitted"           "$CFG_ALPHA  (present: $(mk MUI_CFG_ALPHA_PRESENT "$LOG1"))"
printf '  %-26s %s\n' "warning emitted"         "$CFG_WARN  (present: $(mk MUI_CFG_WARNING_PRESENT "$LOG1"))"
printf '  %-26s %s\n' "reset reapplies default" "$RESET_OK  (present: $(mk MUI_RESET_DEFAULT_PRESENT "$LOG1"))"

# Core gates. config-must-NOT-be-on-EDT and toggle-MUST-be-on-EDT together prove the two lanes separate.
# overlay-grew / chat / x-launch are informational unless their inputs are present.
PASS=1
for v in "$EA" "$LIST_OK" "$CFG_FIRED" "$CFG_VAL_OK" "$CFG_CLIENT" "$TOGGLE_OK" "$TOGGLE_EDT" \
         "$RT_COLOR" "$RT_INT" "$RT_DOUBLE" "$RT_ENUM" \
         "$ACK_OK" "$EVT_SEQ" "$EVT_POLL" "$CFG_HIDDEN" "$CFG_SECRET" "$CFG_SET" "$CFG_ALPHA" "$CFG_WARN" "$RESET_OK"; do
  [ "$v" = "true" ] || PASS=0
done
[ "$CFG_EDT" = "false" ] || PASS=0
# Native-origin color leg is a hard gate only when present (device runs); absent on desktop = skipped.
if [ -n "$RT_NATIVE" ]; then
  [ "$RT_NATIVE" = "true" ] || PASS=0
fi
# If two logs were given, cross-launch persistence becomes a hard gate.
if [ -n "$LOG2" ]; then
  [ "$XLAUNCH" = "true" ] || PASS=0
fi

TUPLE="ea=$EA;list=$LIST_OK;cfgfired=$CFG_FIRED;cfgval=$CFG_VAL_OK;cfgclient=$CFG_CLIENT;cfgnotedt=$([ "$CFG_EDT" = false ] && echo 1 || echo 0);toggle=$TOGGLE_OK;toggleedt=$TOGGLE_EDT;rtcolor=$RT_COLOR;rtint=$RT_INT;rtdouble=$RT_DOUBLE;rtenum=$RT_ENUM;rtnative=${RT_NATIVE:-na};ack=$ACK_OK;evtseq=$EVT_SEQ;evtpoll=$EVT_POLL;hidden=$CFG_HIDDEN;secret=$CFG_SECRET;set=$CFG_SET;alpha=$CFG_ALPHA;warn=$CFG_WARN;reset=$RESET_OK;xlaunch=$XLAUNCH"
MD5="$(printf '%s' "$TUPLE" | md5of)"
echo "  tuple: $TUPLE"
echo "  md5:   $MD5"
if [ "$PASS" = "1" ]; then
  echo "  VERDICT: GREEN"
else
  echo "  VERDICT: RED"
fi
echo "============================================================"
[ "$PASS" = "1" ]
